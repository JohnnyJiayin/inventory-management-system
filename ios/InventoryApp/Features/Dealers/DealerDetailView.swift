import SwiftUI

/// 经销商详情：基本资料、多地址管理（Issue #25）、产品价格表（Issue #26）、历史订单（Issue #38）
struct DealerDetailView: View {
    let dealerID: UUID

    @EnvironmentObject private var store: DealerStore
    @State private var prices: [DealerPrice] = []
    @State private var orders: [OrderSummary] = []
    @State private var showEdit = false
    @State private var addressSheet: AddressSheet?
    @State private var priceSheet: PriceSheet?
    @State private var confirmToggle = false
    @State private var working = false
    @State private var error: String?
    @State private var reloaded = false

    enum AddressSheet: Identifiable {
        case create
        case edit(DealerAddress)
        var id: String {
            switch self {
            case .create: "create"
            case let .edit(a): a.id.uuidString
            }
        }
    }

    struct PriceSheet: Identifiable {
        let modelID: UUID?
        let current: Decimal?
        var id: String { modelID?.uuidString ?? "new" }
    }

    var body: some View {
        if let dealer = store.dealer(id: dealerID) {
            content(dealer)
        } else if reloaded, !store.isLoading {
            // 重新加载后仍找不到：网络错误或经销商不存在，显示原因并可重试
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
                Text(store.error ?? "找不到该经销商").foregroundStyle(.secondary)
                Button("重试") { Task { await store.reload() } }.buttonStyle(.bordered)
            }
            .padding()
        } else {
            ProgressView().task {
                await store.reload()
                reloaded = true
            }
        }
    }

    private func content(_ dealer: Dealer) -> some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(systemName: "building.2.crop.circle").font(.system(size: 56)).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(dealer.companyName).font(.title.bold())
                        StatusBadge(text: dealer.active ? "启用" : "已停用", color: dealer.active ? .green : .gray)
                    }
                }
                .padding(.vertical, 8)
                LabeledContent("联系人", value: dealer.contactName)
                LabeledContent("电话号码", value: dealer.phone)
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }

            addressSection(dealer)
            priceSection(dealer)
            orderSection

            Section {
                Button(dealer.active ? "停用经销商" : "重新启用", role: dealer.active ? .destructive : nil) {
                    confirmToggle = true
                }
                .requiresOnline()
            } footer: {
                Text("停用后不能用于新建出库订单，历史订单仍可查询。")
            }
        }
        .disabled(working)
        .navigationTitle(dealer.companyName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("编辑") { showEdit = true }.requiresOnline()
            }
        }
        .sheet(isPresented: $showEdit) {
            DealerFormView(dealer: dealer) { Task { await store.reload() } }
        }
        .sheet(item: $addressSheet) { sheet in
            switch sheet {
            case .create:
                AddressFormView(dealerID: dealer.id, address: nil) { Task { await store.reload() } }
            case let .edit(address):
                AddressFormView(dealerID: dealer.id, address: address) { Task { await store.reload() } }
            }
        }
        .sheet(item: $priceSheet) { sheet in
            PriceFormView(dealerID: dealer.id, dealerName: dealer.companyName,
                          modelID: sheet.modelID, current: sheet.current,
                          excludedModelIDs: Set(prices.map(\.modelId))) {
                Task { await loadPrices() }
            }
        }
        .confirmationDialog(dealer.active ? "确定停用“\(dealer.companyName)”？" : "确定重新启用“\(dealer.companyName)”？",
                            isPresented: $confirmToggle, titleVisibility: .visible) {
            Button(dealer.active ? "停用" : "启用", role: dealer.active ? .destructive : nil) {
                run { try await DealerService.setActive(dealerID: dealer.id, active: !dealer.active) }
            }
        }
        .task {
            async let p: Void = loadPrices()
            async let o: Void = loadOrders()
            _ = await (p, o)
        }
        .refreshable {
            await store.reload()
            await loadPrices()
            await loadOrders()
        }
    }

    // MARK: - 地址

    private func addressSection(_ dealer: Dealer) -> some View {
        Section {
            // 有效地址在前，默认地址最前
            ForEach(dealer.addresses.sorted { a, b in
                if a.active != b.active { return a.active }
                if a.isDefault != b.isDefault { return a.isDefault }
                return a.createdAt < b.createdAt
            }) { address in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(address.label?.isEmpty == false ? address.label! : "地址").font(.headline)
                            if address.isDefault { StatusBadge(text: "默认", color: .blue) }
                            if !address.active { StatusBadge(text: "已停用", color: .gray) }
                        }
                        Text(address.address).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if address.active, !address.isDefault {
                        Button("设为默认") {
                            run { try await DealerService.setDefaultAddress(id: address.id) }
                        }
                        .buttonStyle(.bordered)
                        .requiresOnline()
                    }
                    Button("编辑") { addressSheet = .edit(address) }
                        .buttonStyle(.bordered)
                        .requiresOnline()
                }
                .opacity(address.active ? 1 : 0.6)
                .padding(.vertical, 2)
            }
            Button {
                addressSheet = .create
            } label: {
                Label("添加地址", systemImage: "plus.circle")
            }
            .requiresOnline()
        } header: {
            Text("地址（\(dealer.activeAddresses.count) 个有效）")
        } footer: {
            Text("每个经销商最多一个默认地址；设新的默认地址后，原默认地址自动取消。修改地址不影响已完成的订单。")
        }
    }

    // MARK: - 价格表

    private func priceSection(_ dealer: Dealer) -> some View {
        Section {
            if prices.isEmpty {
                Text("还没有设置价格。出库扫描未设置价格的型号时会提示先填写单价。")
                    .foregroundStyle(.secondary)
            }
            ForEach(prices) { price in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(price.model?.displayName ?? "—").font(.headline)
                            if price.model?.active == false { StatusBadge(text: "型号已停用", color: .gray) }
                        }
                        Text("更新于 \(price.updatedAt.formatted(date: .numeric, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Money.format(price.price)).font(.title3.monospacedDigit())
                    Button("修改") { priceSheet = PriceSheet(modelID: price.modelId, current: price.price) }
                        .buttonStyle(.bordered)
                        .requiresOnline()
                }
                .swipeActions {
                    Button("停用", role: .destructive) {
                        run {
                            try await DealerService.deactivatePrice(id: price.id)
                            await loadPrices()
                        }
                    }
                }
            }
            Button {
                priceSheet = PriceSheet(modelID: nil, current: nil)
            } label: {
                Label("设置型号价格", systemImage: "plus.circle")
            }
            .requiresOnline()
        } header: {
            Text("产品价格表")
        } footer: {
            Text("出库扫描产品条码后自动填写这里的默认单价。修改价格只影响以后加入订单的产品，历史订单金额不变。向左滑动可停用价格。")
        }
    }

    // MARK: - 历史订单

    private var orderSection: some View {
        Section("历史订单（\(orders.count)）") {
            if orders.isEmpty {
                Text("还没有出库订单").foregroundStyle(.secondary)
            }
            ForEach(orders) { order in
                NavigationLink(value: OrderLink(id: order.id)) {
                    OrderRow(order: order, showDealer: false)
                }
            }
        }
    }

    // MARK: -

    private func loadPrices() async {
        do {
            prices = try await DealerService.fetchPrices(dealerID: dealerID)
        } catch is CancellationError {
        } catch {
            self.error = AppError.message(error)
        }
    }

    private func loadOrders() async {
        do {
            orders = try await OrderService.fetchOrders(.init(dealerID: dealerID))
        } catch is CancellationError {
        } catch {
            self.error = AppError.message(error)
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await action()
                await store.reload()
            } catch {
                self.error = AppError.message(error)
            }
        }
    }
}

/// 新增 / 编辑地址
struct AddressFormView: View {
    let dealerID: UUID
    /// nil 表示新增
    let address: DealerAddress?
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var text = ""
    @State private var isDefault = false
    @State private var active = true
    @State private var saving = false
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                Section {
                    TextField("地址名称（选填，例如公司、仓库、门店）", text: $label)
                    TextField("详细地址（必填）", text: $text, axis: .vertical).lineLimit(2...5)
                }
                Section {
                    if address == nil {
                        Toggle("设为默认地址", isOn: $isDefault)
                    } else {
                        Toggle("启用", isOn: $active)
                    }
                } footer: {
                    Text(address == nil ? "设为默认后，原默认地址自动取消。" : "停用的地址不能用于新订单；停用默认地址时同时取消默认。")
                }
            }
            .navigationTitle(address == nil ? "添加地址" : "编辑地址")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("保存", action: save)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .requiresOnline()
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let address {
                    label = address.label ?? ""
                    text = address.address
                    active = address.active
                }
            }
        }
    }

    private func save() {
        saving = true
        error = nil
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            defer { saving = false }
            do {
                if let address {
                    try await DealerService.updateAddress(id: address.id, label: label, address: text, active: active)
                } else {
                    try await DealerService.addAddress(dealerID: dealerID, label: label, address: text, isDefault: isDefault)
                }
                onSaved()
                dismiss()
            } catch {
                self.error = AppError.message(error)
            }
        }
    }
}

/// 设置“经销商 + 型号”的默认单价（Issue #26）：限两位小数、不为负
struct PriceFormView: View {
    let dealerID: UUID
    let dealerName: String
    /// nil 时由用户选择型号
    let modelID: UUID?
    let current: Decimal?
    /// 选择型号时不显示的型号（已有价格的型号请在列表中“修改”）
    var excludedModelIDs: Set<UUID> = []
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var products: ProductStore
    @State private var selectedModel: UUID?
    @State private var priceText = ""
    @State private var saving = false
    @State private var error: String?
    @State private var loaded = false

    private var price: Decimal? { Money.parse(priceText) }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                Section("经销商") { Text(dealerName) }
                Section("产品型号") {
                    if let modelID {
                        Text(products.model(id: modelID)?.displayName ?? "—")
                    } else {
                        Picker("产品型号", selection: $selectedModel) {
                            Text("请选择").tag(UUID?.none)
                            ForEach(products.models.filter { $0.active && !excludedModelIDs.contains($0.id) }) { m in
                                Text(m.displayName).tag(UUID?.some(m.id))
                            }
                        }
                    }
                }
                Section {
                    TextField("默认单价（元）", text: $priceText)
                        .keyboardType(.decimalPad)
                        .font(.title3.monospacedDigit())
                } header: {
                    Text("默认单价")
                } footer: {
                    if !priceText.isEmpty, price == nil {
                        Text("请输入不小于 0、最多两位小数的金额").foregroundStyle(.red)
                    } else {
                        Text("修改价格只影响以后加入订单的产品，历史订单金额不变。")
                    }
                }
            }
            .navigationTitle(current == nil ? "设置价格" : "修改价格")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("保存", action: save)
                            .disabled(price == nil || (modelID ?? selectedModel) == nil)
                            .requiresOnline()
                    }
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                if let current { priceText = Money.plain(current) }
            }
            .task { if products.models.isEmpty { await products.reload() } }
        }
    }

    private func save() {
        guard let price, let model = modelID ?? selectedModel else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await DealerService.setPrice(dealerID: dealerID, modelID: model, price: price)
                onSaved()
                dismiss()
            } catch {
                self.error = AppError.message(error)
            }
        }
    }
}
