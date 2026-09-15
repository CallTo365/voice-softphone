import AVFoundation
import SwiftUI
import UIKit

/// Camera preview that reports the first QR payload it sees, then stops. AVFoundation directly (works on every
/// device that has a camera; VisionKit's DataScanner needs a Neural Engine). On the simulator there is no camera:
/// `available` is false and the enroll screen keeps the manual field.
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: @MainActor (String) -> Void

    static var available: Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil
    }

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.capture.onCode = onCode
        return vc
    }

    func updateUIViewController(_ vc: ScannerController, context: Context) {
        vc.capture.onCode = onCode
    }
}

/// Owns the capture session off the main actor; the delegate is called on the main queue and hops back into
/// main-actor code explicitly (Swift 6 strict concurrency).
final class QRCapture: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.callto365.softphone.qr")
    private var delivered = false // main queue only
    var onCode: (@MainActor (String) -> Void)?

    func start() {
        queue.async { [self] in
            guard session.inputs.isEmpty else { if !session.isRunning { session.startRunning() }; return }
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            if session.canAddInput(input) { session.addInput(input) }
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
            }
            session.commitConfiguration()
            session.startRunning()
        }
    }

    func stop() {
        queue.async { [session] in if session.isRunning { session.stopRunning() } }
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        let value = objects.compactMap { $0 as? AVMetadataMachineReadableCodeObject }.first { $0.type == .qr }?.stringValue
        guard let value, !value.isEmpty else { return }
        MainActor.assumeIsolated {
            guard !delivered else { return }
            delivered = true
            stop()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCode?(value)
        }
    }
}

final class ScannerController: UIViewController {
    let capture = QRCapture()
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let layer = AVCaptureVideoPreviewLayer(session: capture.session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
        preview = layer
        let capture = self.capture
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if granted { capture.start() }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        capture.stop()
    }
}
