import PhotosUI
import SwiftUI

/// 添加与编辑产品型号（Issue #17）
///   * 名称、型号、条码（扫描或手动）、照片（拍照或相册，上传前压缩到约 300KB）、说明
///   * 新建时可填初始数量；大于 0 时必须连续扫描相同数量的机身号
///   * 修改产品条码时弹出确认；库存数量不可编辑
struct ProductFormView: View {
    enum Mode {
        case create(barcode: String?)
        case edit(ProductModel)
    }

    let mode: Mode
    /// 保存成功后回调型号 ID
    var onSaved: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var network: NetworkMonitor

    @State private var name = ""
    @State private var model = ""
    @State private var barcode = ""
    @State private var description = ""
    @State private var active = true
    @State private var initialQty = 0
    @State private var serials: [String] = []

    @State private var photoItem: PhotosPickerItem?
    @State private var newImage: UIImage?
    @State private var removePhoto = false
    @State private var uploadedPath: String?
    @State private var showCamera = false

    @State private var showBarcodeScanner = false
    @State private var showSerialScanner = false
    @State private var confirmBarcodeChange = false
    @State private var saving = false
    @State private var error: String?
    @State private var requestID = UUID()
    @State private var loaded = false

    private var editing: ProductModel? {
        if case let .edit(m) = mode { return m }
        return nil
    }

    private var trimmedBarcode: String { barcode.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "请填写产品名称" }
        if model.trimmingCharacters(in: .whitespaces).isEmpty { return "请填写产品型号" }
        if trimmedBarcode.isEmpty { return "请扫描或填写产品条码" }
        if editing == nil, serials.count != initialQty {
            return "初始数量为 \(initialQty)，已录入 \(serials.count) 个机身号，两者必须一致"
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                // 错误显示在最上方，避免被键盘挡住
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }

                Section("基本资料") {
                    TextField("产品名称（必填）", text: $name)
                    TextField("产品型号（必填）", text: $model)
                    HStack {
                        TextField("产品条码（必填，扫描或手动输入）", text: $barcode)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            showBarcodeScanner = true
                        } label: {
                            Label("扫描", systemImage: "barcode.viewfinder")
                        }
                        .buttonStyle(.bordered)
                    }
                    TextField("产品说明（选填）", text: $description, axis: .vertical)
                        .lineLimit(2...6)
                }

                photoSection

                if let editing {
                    Section {
                        Toggle("启用", isOn: $active)
                        LabeledContent("当前库存", value: "\(editing.stockQty)")
                    } footer: {
                        Text("库存数量不能直接修改，只能通过入库、出库或重新入库变化。")
                    }
                } else {
                    initialStockSection
                }

            }
            .navigationTitle(editing == nil ? "添加产品" : "编辑产品")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("保存", action: trySave)
                            .disabled(validationMessage != nil)
                            .requiresOnline()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let validationMessage, !saving {
                    Text(validationMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .background(.bar)
                }
            }
            .interactiveDismissDisabled(saving)
            .sheet(isPresented: $showBarcodeScanner) {
                SingleScanSheet(step: .productBarcode) { barcode = $0 }
            }
            .sheet(isPresented: $showSerialScanner) {
                SerialBatchScanSheet(planned: initialQty, productBarcode: trimmedBarcode, serials: $serials)
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    if let image { setImage(image) }
                }
                .ignoresSafeArea()
            }
            .alert("修改产品条码？", isPresented: $confirmBarcodeChange) {
                Button("确定修改", role: .destructive) { save() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("产品条码用于自动识别型号。修改后，扫描原条码 \(editing?.barcode ?? "") 将不再识别为该型号。")
            }
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        setImage(image)
                    }
                }
            }
            .onAppear(perform: load)
        }
    }

    // MARK: - Sections

    private var photoSection: some View {
        Section("产品照片（选填）") {
            HStack(spacing: 16) {
                Group {
                    if let newImage {
                        Image(uiImage: newImage).resizable().scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else {
                        ProductPhotoView(path: removePhoto ? nil : editing?.photoPath, size: 96)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button {
                            showCamera = true
                        } label: {
                            Label("拍照", systemImage: "camera")
                        }
                    }
                    PhotosPicker(selection: $photoItem, matching: .images) {
                        Label("从相册选择", systemImage: "photo.on.rectangle")
                    }
                    if hasPhoto {
                        Button(role: .destructive) {
                            newImage = nil
                            uploadedPath = nil
                            photoItem = nil
                            removePhoto = true
                        } label: {
                            Label("移除照片", systemImage: "trash")
                        }
                    }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var initialStockSection: some View {
        Section {
            Stepper(value: $initialQty, in: 0...9999) {
                HStack {
                    Text("初始数量")
                    TextField("0", value: $initialQty, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 100)
                }
            }
            if initialQty > 0 {
                HStack {
                    Text("已扫 \(serials.count) / 剩余 \(max(initialQty - serials.count, 0))")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(serials.count == initialQty ? .green : .primary)
                    Spacer()
                    Button {
                        showSerialScanner = true
                    } label: {
                        Label("扫描机身号", systemImage: "barcode.viewfinder")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedBarcode.isEmpty)
                }
                if serials.count > initialQty {
                    Text("已录入的机身号多于初始数量，请删除多余的机身号").foregroundStyle(.red)
                }
                ForEach(Array(serials.enumerated()), id: \.element) { index, serial in
                    HStack {
                        Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                        Text(serial).monospaced()
                    }
                }
                .onDelete { serials.remove(atOffsets: $0) }
            }
        } header: {
            Text("初始库存")
        } footer: {
            Text("初始数量大于 0 时，必须扫描相同数量的机身号才能完成建档。")
        }
    }

    // MARK: - Actions

    private var hasPhoto: Bool {
        newImage != nil || (!removePhoto && editing?.photoPath != nil)
    }

    private func setImage(_ image: UIImage) {
        newImage = image
        uploadedPath = nil
        removePhoto = false
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch mode {
        case let .create(prefill):
            barcode = prefill ?? ""
        case let .edit(m):
            name = m.name
            model = m.model
            barcode = m.barcode
            description = m.description ?? ""
            active = m.active
        }
    }

    private func trySave() {
        guard validationMessage == nil else { return }
        if let editing, editing.barcode != trimmedBarcode {
            confirmBarcodeChange = true
        } else {
            save()
        }
    }

    private func save() {
        guard network.isOnline, !saving else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                if let newImage, uploadedPath == nil {
                    uploadedPath = try await PhotoService.upload(newImage)
                }
                let id: UUID
                if let editing {
                    let photoPath = uploadedPath ?? (removePhoto ? nil : editing.photoPath)
                    try await ProductService.updateModel(.init(
                        id: editing.id, name: name, model: model, barcode: trimmedBarcode,
                        description: description, photoPath: photoPath, active: active))
                    if let old = editing.photoPath, old != photoPath {
                        await PhotoService.remove(path: old)
                    }
                    id = editing.id
                } else {
                    let result = try await ProductService.createModel(.init(
                        name: name, model: model, barcode: trimmedBarcode,
                        description: description, photoPath: uploadedPath,
                        serialNos: serials, requestID: requestID))
                    id = result.modelId
                }
                ScanFeedback.success()
                onSaved(id)
                dismiss()
            } catch {
                self.error = AppError.message(error)
                ScanFeedback.failure()
            }
        }
    }
}

/// 连续扫描机身号（新建型号的初始库存）。新型号没有历史记录，只需检查清单内不重复。
struct SerialBatchScanSheet: View {
    let planned: Int
    let productBarcode: String
    @Binding var serials: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var message: (text: String, isError: Bool)?

    var body: some View {
        NavigationStack {
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 12) {
                    ScannerPanel(step: .serialNumber, isPaused: serials.count >= planned, height: 380, onCode: handle)
                    if let message {
                        Label(message.text, systemImage: message.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                            .foregroundStyle(message.isError ? .red : .green)
                            .font(.headline)
                    }
                    Spacer()
                }
                VStack(alignment: .leading) {
                    CountersView(planned: planned, scanned: serials.count)
                    List {
                        ForEach(Array(serials.enumerated().reversed()), id: \.element) { index, serial in
                            HStack {
                                Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                                Text(serial).monospaced()
                            }
                        }
                        .onDelete { offsets in
                            let indices = offsets.map { serials.count - 1 - $0 }
                            serials.remove(atOffsets: IndexSet(indices))
                        }
                    }
                    .listStyle(.plain)
                }
                .frame(maxWidth: 320)
            }
            .padding()
            .navigationTitle("扫描机身号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private func handle(_ code: String) {
        if code == productBarcode {
            message = ("这是产品条码，请扫描右侧机身号条码", true)
            ScanFeedback.failure()
        } else if serials.contains(code) {
            message = ("机身号 \(code) 已在清单中", true)
            ScanFeedback.failure()
        } else if serials.count >= planned {
            message = ("已达到初始数量 \(planned)", true)
            ScanFeedback.failure()
        } else {
            serials.append(code)
            message = ("已添加 \(code)", false)
            ScanFeedback.success()
        }
    }
}

/// 计划 / 已扫 / 剩余
struct CountersView: View {
    let planned: Int
    let scanned: Int

    var body: some View {
        HStack(spacing: 0) {
            counter("计划", planned, .primary)
            Divider().frame(height: 44)
            counter("已扫", scanned, .blue)
            Divider().frame(height: 44)
            counter("剩余", max(planned - scanned, 0), planned == scanned ? .green : .orange)
        }
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func counter(_ title: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.title.bold().monospacedDigit()).foregroundStyle(color)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 拍照
struct CameraPicker: UIViewControllerRepresentable {
    let onFinish: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.onFinish(info[.originalImage] as? UIImage)
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onFinish(nil)
            parent.dismiss()
        }
    }
}
