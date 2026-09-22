import SwiftUI
import Vision
import VisionKit

/// Scanning an enrolment code off a screen.
///
/// The camera is the point of a QR code: the code is long, and copying it by hand is how
/// it gets mistyped. What this decodes goes exactly where a pasted one goes — there is one
/// way to spend an enrolment code and it is `DeviceAuth.enroll` — so nothing here reads the
/// text, and `EnrollmentCode` decides what it is.
///
/// VisionKit's scanner rather than a capture session of our own: it is the system's camera
/// UI, it already knows how to hold a code steady, and a second camera interface inside
/// this app would be a second thing to keep working.
struct EnrollmentScanner: View {
    /// Called with the text the code carried, exactly as printed.
    var onCode: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
                    ScannerSurface(onCode: onCode)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    // No camera, or one this app may not use. The field beside this button
                    // is the way in, and saying so beats a surface that would never see
                    // anything.
                    ContentUnavailableView(
                        "Camera unavailable",
                        systemImage: "qrcode.viewfinder",
                        description: Text("Enter the code by hand instead."))
                }
            }
            .navigationTitle("Scan the code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// The scanning surface itself, as VisionKit provides it.
private struct ScannerSurface: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        // Restarting on every update would restart the camera whenever anything redraws;
        // VisionKit is happy to be told once.
        guard !scanner.isScanning else { return }
        try? scanner.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onCode: (String) -> Void

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        /// The first code that reads cleanly is the answer, and scanning stops with it:
        /// anything after that is the same code again, on a screen that is closing.
        func dataScanner(_ scanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for case let .barcode(barcode) in addedItems {
                let value = (barcode.payloadStringValue ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                scanner.stopScanning()
                onCode(value)
                return
            }
        }
    }
}
