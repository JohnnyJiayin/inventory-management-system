import SwiftUI

/// 产品基础详情（Issue #16）、删除与停用（Issue #18）。完整详情在 Sprint 3 完善。
struct ProductDetailView: View {
    let modelID: UUID

    @EnvironmentObject private var store: ProductStore
    @Environment(\.dismiss) private var dismiss
    @State private var showEdit = false
    @State private var confirmDelete = false
    @State private var confirmToggle = false
    @State private var working = false
    @State private var error: String?
    @State private var inStock: [ProductUnit] = []

    var body: some View {
        if let model = store.model(id: modelID) {
            content(model)
        } else {
            ProgressView().task { await store.reload() }
        }
    }

    private func content(_ model: ProductModel) -> some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 20) {
                    ProductPhotoView(path: model.photoPath, size: 160)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.name).font(.title.bold())
                        Text(model.model).font(.title3).foregroundStyle(.secondary)
                        StatusBadge(text: model.active ? "启用" : "已停用", color: model.active ? .green : .gray)
                    }
                }
                .padding(.vertical, 8)
            }

            Section("基本资料") {
                LabeledContent("产品条码") { Text(model.barcode).monospaced() }
                LabeledContent("产品说明", value: model.description ?? "—")
                LabeledContent("创建时间", value: model.createdAt.formatted(date: .numeric, time: .shortened))
                LabeledContent("更新时间", value: model.updatedAt.formatted(date: .numeric, time: .shortened))
            }

            Section("库存") {
                LabeledContent("当前库存") { Text("\(model.stockQty)").font(.title3.bold()) }
                LabeledContent("累计入库", value: "\(model.totalIn)")
                LabeledContent("累计出库", value: "\(model.totalOut)")
                LabeledContent("最近入库", value: model.lastInAt?.formatted(date: .numeric, time: .shortened) ?? "—")
                LabeledContent("最近出库", value: model.lastOutAt?.formatted(date: .numeric, time: .shortened) ?? "—")
            }

            if !inStock.isEmpty {
                Section("在库机身号（\(inStock.count)）") {
                    Text(inStock.map(\.serialNo).joined(separator: "、"))
                        .font(.body.monospaced())
                }
            }

            Section {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                if model.hasRecords {
                    Button(model.active ? "停用产品" : "重新启用", role: model.active ? .destructive : nil) {
                        confirmToggle = true
                    }
                    .requiresOnline()
                    Text("该型号已有出入库记录，不能删除，只能停用。停用后不能入库或出库，历史记录仍可查询。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Button("删除产品", role: .destructive) { confirmDelete = true }
                        .requiresOnline()
                    if !model.active {
                        Button("重新启用") { confirmToggle = true }.requiresOnline()
                    }
                }
            }
            .disabled(working)
        }
        .navigationTitle(model.displayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("编辑") { showEdit = true }.requiresOnline()
            }
        }
        .sheet(isPresented: $showEdit) {
            ProductFormView(mode: .edit(model)) { _ in
                Task { await store.reload() }
            }
        }
        .confirmationDialog("确定删除“\(model.displayName)”？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) { delete(model) }
        } message: {
            Text("删除后无法恢复。")
        }
        .confirmationDialog(model.active ? "确定停用“\(model.displayName)”？" : "确定重新启用“\(model.displayName)”？",
                            isPresented: $confirmToggle, titleVisibility: .visible) {
            Button(model.active ? "停用" : "启用", role: model.active ? .destructive : nil) { toggle(model) }
        }
        .task(id: model.stockQty) {
            inStock = (try? await ProductService.fetchUnits(modelID: model.id, status: .inStock)) ?? []
        }
        .refreshable { await store.reload() }
    }

    private func delete(_ model: ProductModel) {
        run {
            try await ProductService.deleteModel(model)
            await store.reload()
            dismiss()
        }
    }

    private func toggle(_ model: ProductModel) {
        run {
            try await ProductService.setActive(modelID: model.id, active: !model.active)
            await store.reload()
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do { try await action() } catch { self.error = AppError.message(error) }
        }
    }
}
