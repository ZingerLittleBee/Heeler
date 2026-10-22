import CoreLocation
import Foundation
import Observation

enum BackgroundLocationAuthorization: Sendable, Equatable {
    case notDetermined, authorized, denied
}

@MainActor
protocol BackgroundLocationUpdating: AnyObject {
    var authorization: BackgroundLocationAuthorization { get }
    var isAvailable: Bool { get }
    var onChange: (@MainActor () -> Void)? { get set }
    func requestAuthorization()
    func prepareForForeground()
    func start()
    func stop()
}

/// Optional background execution through real, low-accuracy location updates.
/// Starts in the foreground only, while a Host connection needs it. Locations
/// are discarded by the adapter; they never enter a store, log, or transport.
@MainActor
@Observable
final class BackgroundConnectionKeeper {
    private static let defaultsKey = "background-connections-location"

    private(set) var isEnabled: Bool
    private(set) var isRunning = false
    private(set) var authorization: BackgroundLocationAuthorization
    private(set) var isAvailable: Bool

    @ObservationIgnored var onRunningChanged: (@MainActor (Bool) -> Void)?
    @ObservationIgnored private let location: any BackgroundLocationUpdating
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private var needsConnection = false

    init(
        defaults: UserDefaults = .standard,
        location: any BackgroundLocationUpdating = CoreLocationBackgroundUpdater()
    ) {
        self.defaults = defaults
        self.location = location
        isEnabled = defaults.bool(forKey: Self.defaultsKey)
        authorization = location.authorization
        isAvailable = location.isAvailable
        location.onChange = { [weak self] in self?.reconcile() }
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.defaultsKey)
        if enabled && isForeground && location.authorization == .notDetermined {
            location.requestAuthorization()
        }
        reconcile()
    }

    func setConnectionNeeded(_ needed: Bool) {
        needsConnection = needed
        reconcile()
    }

    func didBecomeActive() {
        isForeground = true
        location.prepareForForeground()
        // Never prompt on launch just because a saved preference is enabled.
        // An undetermined permission is requested only by the Settings toggle.
        reconcile()
    }

    func didEnterBackground() {
        isForeground = false
    }

    private func reconcile() {
        authorization = location.authorization
        isAvailable = location.isAvailable
        let shouldRun = isEnabled && needsConnection && isAvailable
            && authorization == .authorized
        if isRunning && !shouldRun {
            location.stop()
            isRunning = false
            onRunningChanged?(false)
        } else if !isRunning && shouldRun && isForeground {
            // When In Use background delivery must be started while visible.
            location.start()
            isRunning = true
            onRunningChanged?(true)
        }
    }
}

@MainActor
final class CoreLocationBackgroundUpdater: NSObject, BackgroundLocationUpdating, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var hasFailed = false
    var onChange: (@MainActor () -> Void)?

    var authorization: BackgroundLocationAuthorization {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    var isAvailable: Bool { !hasFailed && CLLocationManager.locationServicesEnabled() }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func prepareForForeground() {
        hasFailed = false
    }

    func start() {
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in self?.onChange?() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Intentionally discard coordinates. Only the execution opportunity
        // is used; SSH keepalive continues to be owned by EventsSession.
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // A temporary lack of a GPS fix is normal indoors. Core Location
        // continues trying; it does not mean authorization has been lost.
        guard (error as? CLError)?.code != .locationUnknown else { return }
        Task { @MainActor [weak self] in
            self?.hasFailed = true
            self?.onChange?()
        }
    }

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.hasFailed = true
            self?.onChange?()
        }
    }
}
