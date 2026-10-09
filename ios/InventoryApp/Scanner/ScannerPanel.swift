import AVFoundation
import SwiftUI

/// 可复用的扫码组件（Issue #13）
///   * 取景框限定扫描区域；显示当前步骤提示
///   * 同一条码 2 秒内重复读到只算一次
///   * 显示识别结果，支持取消重扫
///   * 补光灯开关、手动输入入口
///   * 首次请求摄像头权限；被拒绝时显示前往设置的指引
/// 校验与成功 / 失败反馈由调用方根据业务结果决定（ScanFeedback）。
struct ScannerPanel: View {
    let step: ScanStep
    /// 为 true 时忽略识别结果（例如正在处理上一条、弹出确认框时）
    var isPaused: Bool = false
    var height: CGFloat = 320
    let onCode: (String) -> Void

    @StateObject private var permission = CameraPermission()
    @State private var debouncer = ScanDebouncer()
    @State private var lastCode: String?
    @State private var resetToken = 0
    @State private var torchOn = false
    @State private var showManual = false
    @State private var manualText = ""

    var body: some View {
        VStack(spacing: 0) {
            Label(step.prompt, systemImage: step == .productBarcode ? "barcode" : "number")
                .font(.title3.bold())
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(step == .productBarcode ? Color.blue : Color.orange)

            camera
                .frame(height: height)
                .clipped()

            HStack(spacing: 12) {
                if let lastCode {
                    Text("识别结果：").foregroundStyle(.secondary)
                    Text(lastCode).font(.body.monospaced().bold()).lineLimit(1)
                    Button("取消重扫", action: rescan).buttonStyle(.bordered)
                } else {
                    Text("将条码放入框内").foregroundStyle(.secondary)
                }
                Spacer()
                if Torch.isAvailable {
                    Button {
                        torchOn.toggle()
                        Torch.set(torchOn)
                    } label: {
                        Label("补光灯", systemImage: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(torchOn ? .yellow : nil)
                }
                Button {
                    manualText = ""
                    showManual = true
                } label: {
                    Label("手动输入", systemImage: "keyboard")
                }
                .buttonStyle(.bordered)
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.3)))
        .task { await permission.requestIfNeeded() }
        .onChange(of: step) { _ in rescan() }
        .onDisappear { if torchOn { Torch.set(false); torchOn = false } }
        .alert(step.manualTitle, isPresented: $showManual) {
            TextField(step == .productBarcode ? "产品条码" : "条码下方的数字", text: $manualText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("确定") {
                let code = manualText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !code.isEmpty else { return }
                lastCode = code
                debouncer.reset()
                onCode(code)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(step == .serialNumber ? "无法扫描时，输入机身号条码下方的数字" : "无法扫描时，输入产品条码下方的数字")
        }
    }

    @ViewBuilder
    private var camera: some View {
        switch permission.status {
        case .authorized:
            if CameraScannerView.isSupported {
                ZStack {
                    CameraScannerView(resetToken: resetToken) { code in
                        guard !isPaused, debouncer.accept(code) else { return }
                        lastCode = code
                        onCode(code)
                    }
                    ScanRegionOverlay(color: step == .productBarcode ? .blue : .orange)
                        .allowsHitTesting(false)
                }
            } else {
                notice(icon: "camera.badge.ellipsis", text: "此设备没有可用的摄像头，请使用手动输入")
            }
        case .notDetermined:
            ProgressView("正在请求摄像头权限…").frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            VStack(spacing: 12) {
                notice(icon: "camera.fill", text: "没有摄像头权限，无法扫码。\n请在“设置 → 库存管理”中允许使用相机，或使用手动输入。")
                Button("前往设置") { permission.openSettings() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func notice(icon: String, text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.largeTitle)
            Text(text).multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGray6))
    }

    private func rescan() {
        lastCode = nil
        debouncer.reset()
        resetToken += 1
    }
}

/// 取景框：框外变暗，框内为识别区域
struct ScanRegionOverlay: View {
    var color: Color

    var body: some View {
        GeometryReader { geo in
            let rect = ScanRegion.rect(in: CGRect(origin: .zero, size: geo.size))
            ZStack {
                Path { p in
                    p.addRect(CGRect(origin: .zero, size: geo.size))
                    p.addRoundedRect(in: rect, cornerSize: CGSize(width: 10, height: 10))
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
                RoundedRectangle(cornerRadius: 10)
                    .stroke(color, lineWidth: 3)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        }
    }
}

/// 单次扫码弹窗：扫到后显示结果，可以“使用”或“重新扫描”（用于产品表单中的条码输入）
struct SingleScanSheet: View {
    let step: ScanStep
    let onResult: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var result: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                ScannerPanel(step: step, isPaused: result != nil, height: 360) { code in
                    ScanFeedback.success()
                    result = code
                }
                if let result {
                    VStack(spacing: 12) {
                        Text(result).font(.title.monospaced().bold())
                        HStack {
                            Button("重新扫描") { self.result = nil }
                                .buttonStyle(.bordered)
                            Button("使用此结果") {
                                onResult(result)
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .controlSize(.large)
                    }
                }
                Spacer()
            }
            .padding()
            .navigationTitle(step == .productBarcode ? "扫描产品条码" : "扫描机身号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
    }
}
