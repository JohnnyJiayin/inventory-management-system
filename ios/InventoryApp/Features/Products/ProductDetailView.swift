import SwiftUI

/// 产品详情（Issue #16、#41）、删除与停用（Issue #18）
///   在库 / 已出库机身号、所有入库记录、所有出库记录、当前保修与历史保修记录。
struct ProductDetailView: View {
    let modelID: UUID

    @EnvironmentObject private var store: ProductStore
    @Environment(\.dismiss) private var dismiss
    @State private var showEdit = false
    @State private var confirmDelete = false
    @State private var confirmToggle = false
    @State private var working = false
    @State private var error: String?
    @State private var records = ProductRecords()
    @State private var tab = RecordTab.inStock
    @State private var serialQuery = ""
    @State private var currentWarrantyOnly = true
    @State private var recordsError: String?

    enum RecordTab: Hashable {
        case inStock, shipped, stockIns, outbound, warranty
    }

    /// 详情页的出入库与保修记录（一次加载）
    struct ProductRecords {
        var units: [ProductUnit] = []
        var stockIns: [StockInRecord] = []
        var outbound: [OutboundRecord] = []
        var warranties: [WarrantyRecord] = []
    }

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

            recordSection

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
        // 库存或出入库次数变化时重新加载记录
        .task(id: [model.stockQty, model.totalIn, model.totalOut]) { await loadRecords() }
        .refreshable {
            await store.reload()
            await loadRecords()
        }
    }

    // MARK: - 出入库与保修记录（Issue #41）

    private func matches(_ serial: String) -> Bool {
        let q = serialQuery.trimmingCharacters(in: .whitespaces)
        return q.isEmpty || serial.localizedCaseInsensitiveContains(q)
    }

    private var recordSection: some View {
        let inStock = records.units.filter { $0.status == .inStock && matches($0.serialNo) }
        let shipped = records.units.filter { $0.status == .shipped && matches($0.serialNo) }
        let stockIns = records.stockIns.filter { matches($0.serialNo) }
        let outbound = records.outbound.filter { matches($0.serialNo) }
        let warranties = records.warranties.filter { matches($0.serialNo) && (!currentWarrantyOnly || $0.isCurrent) }
        return Section {
            Picker("记录", selection: $tab) {
                Text("在库 \(inStock.count)").tag(RecordTab.inStock)
                Text("已出库 \(shipped.count)").tag(RecordTab.shipped)
                Text("入库记录 \(stockIns.count)").tag(RecordTab.stockIns)
                Text("出库记录 \(outbound.count)").tag(RecordTab.outbound)
                Text("保修").tag(RecordTab.warranty)
            }
            .pickerStyle(.segmented)
            TextField("按机身号筛选", text: $serialQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if let recordsError {
                Label(recordsError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            switch tab {
            case .inStock:
                unitList(inStock, empty: "没有在库产品")
            case .shipped:
                unitList(shipped, empty: "没有已出库产品")
            case .stockIns:
                if stockIns.isEmpty { emptyRow("没有入库记录") }
                ForEach(stockIns) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.serialNo).font(.body.monospaced())
                            Text([r.recordNo, r.note].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            StatusBadge(text: r.inType.title, color: r.inType == .first ? .blue : .purple)
                            Text(r.inAt.formatted(date: .numeric, time: .shortened))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            case .outbound:
                if outbound.isEmpty { emptyRow("没有出库记录") }
                ForEach(outbound) { r in
                    NavigationLink(value: OrderLink(id: r.orderId)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.serialNo).font(.body.monospaced())
                                Text("\(r.dealerName) · \(r.orderNo)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                HStack(spacing: 6) {
                                    if r.orderStatus != .completed {
                                        StatusBadge(text: r.orderStatus.title, color: r.orderStatus.color)
                                    }
                                    Text(Money.format(r.actualPrice)).monospacedDigit()
                                }
                                Text(r.shippedAt?.formatted(date: .numeric, time: .shortened) ?? "—")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        .opacity(r.orderStatus == .cancelled ? 0.6 : 1)
                    }
                }
            case .warranty:
                Toggle("只看当前保修（每台产品最近一次有效出库）", isOn: $currentWarrantyOnly)
                if warranties.isEmpty { emptyRow("没有保修记录") }
                ForEach(warranties) { record in
                    NavigationLink(value: OrderLink(id: record.orderId)) {
                        WarrantyRow(record: record)
                    }
                }
            }
        } header: {
            Text("出入库与保修记录")
        }
    }

    @ViewBuilder
    private func unitList(_ units: [ProductUnit], empty: String) -> some View {
        if units.isEmpty {
            emptyRow(empty)
        } else {
            Text(units.map(\.serialNo).joined(separator: "、"))
                .font(.body.monospaced())
                .textSelection(.enabled)
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary)
    }

    private func loadRecords() async {
        do {
            async let units = ProductService.fetchUnits(modelID: modelID)
            async let stockIns = InventoryService.fetchStockIns(modelID: modelID)
            async let outbound = InventoryService.fetchOutbound(modelID: modelID)
            async let warranties = WarrantyService.fetch(modelID: modelID)
            records = try await ProductRecords(units: units, stockIns: stockIns,
                                               outbound: outbound, warranties: warranties)
            recordsError = nil
        } catch is CancellationError {
        } catch {
            recordsError = AppError.message(error)
        }
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
