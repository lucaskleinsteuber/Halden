import AVFoundation
import SwiftUI

/// The camera, looking for a QR code. Calls `found` with its text once.
struct QRScannerView: UIViewControllerRepresentable {
    let found: (String) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.found = found
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var found: ((String) -> Void)?
    private let session = AVCaptureSession()
    private var done = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let camera = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input)
        else {
            let label = UILabel()
            label.text = "No camera here. Paste the link instead."
            label.textColor = .white
            label.frame = view.bounds.insetBy(dx: 20, dy: 20)
            label.numberOfLines = 0
            label.textAlignment = .center
            view.addSubview(label)
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        let handle = SessionHandle(session: session)
        DispatchQueue.global(qos: .userInitiated).async { handle.session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let handle = SessionHandle(session: session)
        DispatchQueue.global(qos: .userInitiated).async { handle.session.stopRunning() }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection
    ) {
        let texts = objects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        MainActor.assumeIsolated {
            guard !done, let text = texts.first(where: { $0.hasPrefix("halden://") }) else { return }
            done = true
            found?(text)
        }
    }
}
