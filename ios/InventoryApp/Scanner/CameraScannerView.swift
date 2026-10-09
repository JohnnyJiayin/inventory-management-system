import AVFoundation
import SwiftUI
import VisionKit

/// 摄像头取景 + 条码识别。优先使用 VisionKit DataScannerViewController（A12 及以上），
/// 设备不支持时（例如 iPad 第 6/7 代）自动改用 AVFoundation，功能相同。
/// resetToken 变化时重新开始识别（用于“取消重扫”）。
struct CameraScannerView: UIViewControllerRepresentable {
    var resetToken: Int
    var onCode: (String) -> Void

    static var isSupported: Bool {
        DataScannerViewController.isSupported || AVCaptureDevice.default(for: .video) != nil
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let host: ScannerHost
        if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
            host = DataScannerHost()
        } else {
            host = AVScannerHost()
        }
        host.onCode = { context.coordinator.onCode($0) }
        context.coordinator.lastToken = resetToken
        return host
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.onCode = onCode
        if context.coordinator.lastToken != resetToken {
            context.coordinator.lastToken = resetToken
            (controller as? ScannerHost)?.restart()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator {
        var onCode: (String) -> Void
        var lastToken = 0
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
    }
}

/// 两种实现的公共父类
class ScannerHost: UIViewController {
    var onCode: ((String) -> Void)?
    func restart() {}

    func emit(_ raw: String?) {
        guard let code = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else { return }
        onCode?(code)
    }
}

// MARK: - VisionKit

final class DataScannerHost: ScannerHost, DataScannerViewControllerDelegate {
    private let scanner = DataScannerViewController(
        recognizedDataTypes: [.barcode(symbologies: BarcodeTypes.visionKit)],
        qualityLevel: .accurate,
        recognizesMultipleItems: false,
        isHighFrameRateTrackingEnabled: false,
        isPinchToZoomEnabled: true,
        isGuidanceEnabled: false,
        isHighlightingEnabled: true
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(scanner)
        scanner.view.frame = view.bounds
        scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scanner.view)
        scanner.didMove(toParent: self)
        scanner.delegate = self
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scanner.regionOfInterest = ScanRegion.rect(in: scanner.view.bounds)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        try? scanner.startScanning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scanner.stopScanning()
    }

    override func restart() {
        scanner.stopScanning()
        try? scanner.startScanning()
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        for item in addedItems {
            if case let .barcode(barcode) = item { emit(barcode.payloadStringValue) }
        }
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
        if case let .barcode(barcode) = item { emit(barcode.payloadStringValue) }
    }
}

// MARK: - AVFoundation

final class AVScannerHost: ScannerHost, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureMetadataOutput()
    private let sessionQueue = DispatchQueue(label: "AVScannerHost.session")
    private var preview: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = BarcodeTypes.avFoundation.filter(output.availableMetadataObjectTypes.contains)

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let preview else { return }
        preview.frame = view.bounds
        if let connection = preview.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = Self.videoOrientation(for: view.window?.windowScene?.interfaceOrientation)
        }
        updateRegion()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
            DispatchQueue.main.async { self.updateRegion() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in session.stopRunning() }
    }

    private func updateRegion() {
        guard let preview, session.isRunning else { return }
        output.rectOfInterest = preview.metadataOutputRectConverted(fromLayerRect: ScanRegion.rect(in: preview.bounds))
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        for case let code as AVMetadataMachineReadableCodeObject in objects {
            emit(code.stringValue)
        }
    }

    private static func videoOrientation(for o: UIInterfaceOrientation?) -> AVCaptureVideoOrientation {
        switch o {
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        case .portraitUpsideDown: .portraitUpsideDown
        default: .portrait
        }
    }
}
