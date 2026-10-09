import AudioToolbox
import AVFoundation
import UIKit
import Vision
import VisionKit

/// 当前扫描步骤：决定读到的条码按产品条码还是机身号处理（架构设计 8）
enum ScanStep: Equatable {
    case productBarcode
    case serialNumber

    var prompt: String {
        switch self {
        case .productBarcode: "请扫描左侧产品条码"
        case .serialNumber: "请扫描右侧机身号条码"
        }
    }

    var manualTitle: String {
        switch self {
        case .productBarcode: "手动输入产品条码"
        case .serialNumber: "手动输入机身号"
        }
    }
}

/// 扫描区域（相对取景画面的比例）。窄而扁，避免标签左右两个条码同时进入识别区域。
enum ScanRegion {
    static let relative = CGRect(x: 0.25, y: 0.34, width: 0.5, height: 0.32)

    static func rect(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.minX + bounds.width * relative.minX,
               y: bounds.minY + bounds.height * relative.minY,
               width: bounds.width * relative.width,
               height: bounds.height * relative.height)
    }
}

/// 只识别一维条码
enum BarcodeTypes {
    @available(iOS 16.0, *)
    static let visionKit: [VNBarcodeSymbology] = [
        .ean8, .ean13, .upce, .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum,
        .code93, .code93i, .code128, .itf14, .i2of5, .i2of5Checksum, .codabar,
        .gs1DataBar, .gs1DataBarExpanded, .gs1DataBarLimited,
    ]

    static let avFoundation: [AVMetadataObject.ObjectType] = [
        .ean8, .ean13, .upce, .code39, .code39Mod43, .code93, .code128, .itf14, .interleaved2of5, .codabar,
        .gs1DataBar, .gs1DataBarExpanded, .gs1DataBarLimited,
    ]
}

/// 扫码反馈：成功提示音 + 触感；失败用不同的提示音
enum ScanFeedback {
    private static let notifier = UINotificationFeedbackGenerator()

    static func success() {
        AudioServicesPlaySystemSound(1057) // Tink
        notifier.notificationOccurred(.success)
    }

    static func failure() {
        AudioServicesPlaySystemSound(1053) // 低沉的否定音
        notifier.notificationOccurred(.error)
    }

    static func warning() {
        AudioServicesPlaySystemSound(1052)
        notifier.notificationOccurred(.warning)
    }
}

/// 同一条码 2 秒内重复读到只算一次
final class ScanDebouncer {
    private var last: (code: String, at: Date)?
    let interval: TimeInterval

    init(interval: TimeInterval = 2) { self.interval = interval }

    func accept(_ code: String, now: Date = Date()) -> Bool {
        if let last, last.code == code, now.timeIntervalSince(last.at) < interval {
            return false
        }
        last = (code, now)
        return true
    }

    func reset() { last = nil }
}

/// 补光灯
enum Torch {
    static var isAvailable: Bool {
        AVCaptureDevice.default(for: .video)?.hasTorch ?? false
    }

    static func set(_ on: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        } catch {}
    }
}

/// 摄像头权限
@MainActor
final class CameraPermission: ObservableObject {
    @Published private(set) var status = AVCaptureDevice.authorizationStatus(for: .video)

    func requestIfNeeded() async {
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
            status = AVCaptureDevice.authorizationStatus(for: .video)
        }
    }

    func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
