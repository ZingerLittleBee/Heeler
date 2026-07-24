import AVFoundation
import SwiftUI
import VisionKit

/// Scan to Pair (#62): the camera entry for Pairing Codes, with the
/// permission prompt, a usable denied path, and the parsed Host summary once
/// a code parses. The connect/enroll/verify ceremony lands with the follow-up
/// tickets of the pairing spec; until then the summary is the end of the road.
struct PairingScanView: View {
    @State private var store = PairingScanStore()
    @State private var cameraAccess: CameraAccess = .undetermined
    @Environment(\.dismiss) private var dismiss

    private enum CameraAccess {
        case undetermined
        case authorized
        case denied
    }

    var body: some View {
        NavigationStack {
            Group {
                if let code = store.pairingCode {
                    PairingCodeSummaryView(code: code) {
                        store.rescan()
                    }
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
                }
            }
        }
    }

    private var scannerViewport: some View {
        PairingCodeScanner { store.submit(scannedCode: $0) }
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

/// The parsed Pairing Code, presented as the Host it describes. Read-only for
/// now: creating the Host awaits the verified reconnect of the full ceremony.
struct PairingCodeSummaryView: View {
    let code: PairingCode
    var onRescan: () -> Void

    var body: some View {
        List {
            Section("Host") {
                LabeledContent("User", value: code.username)
                LabeledContent("Port", value: String(code.port))
            }

            Section {
                ForEach(code.addresses, id: \.self) { address in
                    Text(address)
                        .font(.callout.monospaced())
                }
            } header: {
                Text("Addresses")
            } footer: {
                Text("Tried in this order when connecting.")
            }

            Section {
                Text(code.hostKeyFingerprint.displayString)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            } header: {
                Text("Host Key")
            } footer: {
                Text("Pinned from the Pairing Code — no fingerprint prompt on first connect.")
            }

            if let bootstrap = code.bootstrap {
                Section("Bootstrap Key") {
                    LabeledContent(
                        "Expires",
                        value: bootstrap.expiresAt.formatted(date: .omitted, time: .standard))
                }
            }

            Section {
                Button("Scan Again", systemImage: "qrcode.viewfinder") {
                    onRescan()
                }
            }
        }
    }
}

/// The system scanner (VisionKit), narrowed to QR codes. Reports every newly
/// recognized payload string; filtering and parsing belong to the store.
private struct PairingCodeScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void

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
        private let onScan: (String) -> Void

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            for case .barcode(let barcode) in addedItems {
                if let payload = barcode.payloadStringValue {
                    onScan(payload)
                }
            }
        }
    }
}
