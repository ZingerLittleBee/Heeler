import AVFoundation
import CoreImage
import SwiftUI
import VisionKit

/// Scan to Pair (#62, #66): the camera entry for Pairing Codes, with the
/// permission prompt and a usable denied path. Once a code parses, the
/// pairing ceremony runs immediately — one scan, no confirmation step — and
/// on success the persisted Host is handed to `onPaired`, entering the same
/// preflight a manually added Host does.
struct PairingScanView: View {
    let onPaired: (Host) -> Void
    let onAddManually: () -> Void
    @State private var store: PairingScanStore
    @State private var cameraAccess: CameraAccess = .undetermined
    @Environment(\.dismiss) private var dismiss

    init(
        catalog: HostStore,
        onPaired: @escaping (Host) -> Void = { _ in },
        onAddManually: @escaping () -> Void = {}
    ) {
        self.onPaired = onPaired
        self.onAddManually = onAddManually
        _store = State(initialValue: PairingScanStore(catalog: catalog))
    }

    private enum CameraAccess {
        case undetermined
        case authorized
        case denied
    }

    var body: some View {
        NavigationStack {
            Group {
                if let code = store.pairingCode {
                    PairingCeremonyView(code: code, store: store)
                } else {
                    scanner
                }
            }
            .navigationTitle("Scan to Pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task { await resolveCameraAccess() }
            .onChange(of: store.pairedHost) { _, paired in
                guard let paired else { return }
                dismiss()
                onPaired(paired)
            }
        }
    }

    @ViewBuilder
    private var scanner: some View {
        switch cameraAccess {
        case .undetermined:
            // The system permission prompt is up (or about to be).
            ProgressView()
        case .denied:
            ContentUnavailableView {
                Label("Camera Access Needed", systemImage: "camera")
            } description: {
                Text(
                    "Scanning a Pairing Code uses the camera. Allow camera access "
                        + "in Settings, or add the Host manually instead.")
            } actions: {
                Button("Open Settings") { openSettings() }
                    .buttonStyle(.borderedProminent)
                Button("Add Manually") { addManually() }
            }
        case .authorized:
            if DataScannerViewController.isSupported {
                scannerViewport
            } else {
                ContentUnavailableView {
                    Label("Scanning Unavailable", systemImage: "camera")
                } description: {
                    Text(
                        "This device cannot scan QR codes. "
                            + "Add the Host manually instead.")
                } actions: {
                    Button("Add Manually") { addManually() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    /// The manual fallback: hand off to the presenter (which owns the manual
    /// Host form) and close this sheet, mirroring the `onPaired` hand-off.
    private func addManually() {
        onAddManually()
        dismiss()
    }

    private var scannerViewport: some View {
        PairingCodeScanner { store.submit(scanned: $0) }
            .ignoresSafeArea(edges: .bottom)
            .overlay(alignment: .bottom) {
                Text(store.scanFailureMessage ?? "Point the camera at the Pairing Code shown by herdr.")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
                    .padding()
            }
    }

    private func resolveCameraAccess() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraAccess = .authorized
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            cameraAccess = granted ? .authorized : .denied
        default:
            cameraAccess = .denied
        }
    }

    private func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// The ceremony in flight (#66): the scanned Host, per-step progress, and on
/// failure that step's copy with its recovery actions. The ceremony starts on
/// arrival; Try Again reruns it with the same code while its TTL holds, so a
/// network blip never forces a rescan.
private struct PairingCeremonyView: View {
    let code: PairingCode
    let store: PairingScanStore
    @State private var attempt = 0

    private enum StepStatus {
        case pending
        case active
        case done
        case failed
    }

    var body: some View {
        List {
            Section("Host") {
                LabeledContent("User", value: code.username)
                LabeledContent(
                    "Address",
                    value: code.addresses.count == 1
                        ? code.addresses[0] : "\(code.addresses.count) candidates")
                if code.port != 22 {
                    LabeledContent("Port", value: String(code.port))
                }
            }

            Section {
                ForEach(ceremonySteps, id: \.self) { step in
                    stepRow(step)
                }
            } header: {
                Text("Pairing")
            } footer: {
                if store.failure == nil {
                    Text("Host key pinned from the Pairing Code — no fingerprint prompt.")
                }
            }

            if let failure = store.failure {
                Section {
                    Text(failure.message)
                    if failure.canRetry {
                        Button("Try Again", systemImage: "arrow.clockwise") {
                            attempt += 1
                        }
                    }
                    Button("Scan Again", systemImage: "qrcode.viewfinder") {
                        store.rescan()
                    }
                }
            }
        }
        .task(id: attempt) { await store.pair() }
    }

    /// The steps this code's ceremony performs. A config-only code carries no
    /// Bootstrap Key: the Device Key reconnect is the whole ceremony.
    private var ceremonySteps: [PairingStep] {
        code.bootstrap == nil
            ? [.reach, .verify]
            : [.reach, .authenticate, .enroll, .verify]
    }

    private func stepRow(_ step: PairingStep) -> some View {
        HStack {
            Text(title(for: step))
            Spacer()
            switch status(for: step) {
            case .pending:
                Image(systemName: "circle")
                    .foregroundStyle(.tertiary)
            case .active:
                ProgressView()
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func title(for step: PairingStep) -> String {
        switch step {
        case .parse: "Read the code"
        case .reach: "Reach the Host"
        case .authenticate: "Authenticate with the Pairing Code"
        case .enroll: "Enroll this device"
        case .verify: "Verify the new key"
        }
    }

    private func status(for step: PairingStep) -> StepStatus {
        if store.pairedHost != nil {
            return .done
        }
        if let failure = store.failure {
            // `.parse` failures precede the ceremony: every row stays pending.
            if step == failure.step { return .failed }
            return rank(step) < rank(failure.step) ? .done : .pending
        }
        guard let current = store.step else {
            return store.isPairing && step == ceremonySteps.first ? .active : .pending
        }
        // The connector reports a step as it begins; earlier ones finished.
        if step == current { return .active }
        return rank(step) < rank(current) ? .done : .pending
    }

    private func rank(_ step: PairingStep) -> Int {
        PairingStep.allCases.firstIndex(of: step) ?? 0
    }
}

/// The system scanner (VisionKit), narrowed to QR codes. Reports every newly
/// recognized code — the decoded string plus the exact bytes recovered from
/// the symbol descriptor; filtering and parsing belong to the store.
private struct PairingCodeScanner: UIViewControllerRepresentable {
    let onScan: (ScannedQRCode) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .fast,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning else { return }
        // Fails only when capture is unavailable (already gated on
        // authorization and isSupported); the denied path covers the rest.
        try? scanner.startScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (ScannedQRCode) -> Void

        init(onScan: @escaping (ScannedQRCode) -> Void) {
            self.onScan = onScan
        }

        // What a byte-mode QR actually delivers here, measured against Vision
        // on this OS generation (macOS 26.5 probe; Vision is shared code with
        // iOS): `payloadStringValue` is nil when the payload is not valid
        // UTF-8 and truncated at the first NUL when it is — there is no
        // Latin-1 byte-per-scalar fallback, so a binary v2 envelope cannot
        // ride the string. `observation.payloadData` is byte-identical to
        // `CIQRCodeDescriptor.errorCorrectedPayload`: the raw codeword stream
        // including segment headers and padding, not the payload itself.
        // Recovering the exact bytes therefore goes through the descriptor
        // plus `QRCodeContent.segmentBytes`. Both surfaces are reported; the
        // store's dispatch decides which to trust.
        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for case .barcode(let barcode) in addedItems {
                let descriptor = barcode.observation.barcodeDescriptor as? CIQRCodeDescriptor
                let bytes = descriptor.flatMap {
                    QRCodeContent.segmentBytes(
                        errorCorrectedPayload: $0.errorCorrectedPayload,
                        symbolVersion: $0.symbolVersion)
                }
                let scanned = ScannedQRCode(string: barcode.payloadStringValue, bytes: bytes)
                guard scanned.string != nil || scanned.bytes != nil else { continue }
                onScan(scanned)
            }
        }
    }
}
