import SwiftUI

/// 未知条码绑定型号（Issue #19，需求 5.2、8.2）
/// 扫到未建档的产品条码时：创建新型号（带入条码）或绑定已有型号；完成后回到原流程继续。
struct UnknownBarcodeSheet: View {
    let barcode: String
    let onResolved: (ProductModel) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: ProductStore
    @State private var showCreate = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("未找到对应产品型号，请创建产品或绑定已有型号。", systemImage: "questionmark.diamond.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        LabeledContent("扫描到的条码") { Text(barcode).font(.title3.monospaced().bold()) }
                    }
                    .padding(.vertical, 6)
                }
                Section {
                    Button {
                        showCreate = true
                    } label: {
                        Label("创建新型号", systemImage: "plus.square")
                    }
                    .requiresOnline()
                    NavigationLink {
                        BindModelList(barcode: barcode) { model in
                            finish(model)
                        }
                    } label: {
                        Label("绑定已有型号", systemImage: "link")
                    }
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            .navigationTitle("未建档的条码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .sheet(isPresented: $showCreate) {
                ProductFormView(mode: .create(barcode: barcode)) { id in
                    Task {
                        do {
                            if let model = try await ProductService.fetchModel(id: id) { finish(model) }
                        } catch {
                            self.error = AppError.message(error)
                        }
                    }
                }
            }
        }
    }

    private func finish(_ model: ProductModel) {
        Task { await store.reload() }
        onResolved(model)
        dismiss()
    }
}

/// 选择要绑定的已有型号
struct BindModelList: View {
    let barcode: String
    let onBound: (ProductModel) -> Void

    @EnvironmentObject private var store: ProductStore
    @State private var query = ""
    @State private var target: ProductModel?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            ForEach(store.filtered(query)) { model in
                Button {
                    target = model
                } label: {
                    ProductRow(model: model)
                }
                .foregroundStyle(.primary)
            }
        }
        .disabled(working)
        .searchable(text: $query, prompt: "搜索名称、型号或条码")
        .navigationTitle("绑定已有型号")
        .task { if store.models.isEmpty { await store.reload() } }
        .alert("绑定条码", isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }), presenting: target) { model in
            Button("绑定") { bind(model) }
            Button("取消", role: .cancel) {}
        } message: { model in
            Text("将条码 \(barcode) 绑定到“\(model.displayName)”。\n该型号原条码 \(model.barcode) 将被替换，扫描原条码将不再识别为该型号。")
        }
    }

    private func bind(_ model: ProductModel) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await ProductService.bindBarcode(modelID: model.id, barcode: barcode)
                if let updated = try await ProductService.fetchModel(id: model.id) {
                    ScanFeedback.success()
                    onBound(updated)
                }
            } catch {
                self.error = AppError.message(error)
                ScanFeedback.failure()
            }
        }
    }
}
