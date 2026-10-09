import SwiftUI

/// 出库订单列表（Issue #35）：单号、经销商、出库时间、产品数量、总金额、状态，支持筛选。
/// “编辑中”的订单保存在云端，关闭 App 或断网恢复后点开即可继续编辑。
struct OrderListView: View {
    @State private var filter = OrderService.Filter()
    @State private var orders: [OrderSummary] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showNew = false
    /// 新建订单后直接进入扫码页
    @State private var openedOrder: OrderLink?
    @State private var appeared = false

    var body: some View {
        List {
            Picker("状态", selection: $filter.status) {
                Text("全部").tag(OrderStatus?.none)
                ForEach(OrderStatus.allCases, id: \.self) { s in
                    Text(s.title).tag(OrderStatus?.some(s))
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())

            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            ForEach(orders) { order in
                NavigationLink(value: OrderLink(id: order.id)) {
                    OrderRow(order: order, showDealer: true)
                }
            }
        }
        .overlay {
            if orders.isEmpty, !loading {
                Text(filter == OrderService.Filter() ? "还没有出库订单，点击右上角“新建出库订单”" : "没有匹配的订单")
                    .foregroundStyle(.secondary)
            }
        }
        .searchable(text: $filter.query, prompt: "搜索单号或经销商")
        .navigationTitle("出库订单")
        .navigationDestination(for: OrderLink.self) { link in
            OrderView(orderID: link.id)
        }
        .navigationDestination(isPresented: Binding(
            get: { openedOrder != nil }, set: { if !$0 { openedOrder = nil } })) {
            if let openedOrder { OrderView(orderID: openedOrder.id) }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showNew = true
                } label: {
                    Label("新建出库订单", systemImage: "plus")
                }
                .requiresOnline()
            }
        }
        .sheet(isPresented: $showNew) {
            NewOrderView { id in
                openedOrder = OrderLink(id: id)
            }
        }
        .refreshable { await load() }
        .task(id: filter) {
            // 输入搜索词时稍等再查询，避免每输入一个字发一次请求（新的输入会取消上一次等待）
            if !filter.query.isEmpty {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
            }
            await load()
        }
        // 从详情返回时重新加载（状态、金额可能已变化）
        .onAppear {
            if appeared { Task { await load() } }
            appeared = true
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            orders = try await OrderService.fetchOrders(filter)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = AppError.message(error)
        }
    }
}

struct OrderRow: View {
    let order: OrderSummary
    var showDealer = true

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(order.orderNo).font(.headline.monospaced())
                    StatusBadge(text: order.status.title, color: order.status.color)
                }
                if showDealer {
                    Text(order.dealerName).font(.subheadline)
                }
                Text(order.shippedAt.map { "出库 \($0.formatted(date: .numeric, time: .shortened))" }
                     ?? "创建 \(order.createdAt.formatted(date: .numeric, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.format(order.totalAmount))
                    .font(.title3.bold().monospacedDigit())
                    .strikethrough(order.status == .cancelled)
                Text("\(order.itemCount) 台").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(order.status == .cancelled ? 0.6 : 1)
    }
}

/// 打开订单：编辑中的订单进入扫码页继续编辑，其他状态显示详情。
/// 确认出库成功后自动切换为详情并显示结果。
struct OrderView: View {
    let orderID: UUID

    @State private var order: OrderSummary?
    @State private var error: String?
    @State private var confirmed: ConfirmOrderResult?

    var body: some View {
        Group {
            if let order {
                if order.status == .draft {
                    OrderEditorView(orderID: orderID) { result in
                        confirmed = result
                        Task { await load() }
                    } onCancelled: {
                        Task { await load() }
                    }
                } else {
                    OrderDetailView(orderID: orderID, justConfirmed: confirmed)
                }
            } else if let error {
                VStack(spacing: 12) {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("重试") { Task { await load() } }.buttonStyle(.bordered)
                }
            } else {
                ProgressView()
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            if let found = try await OrderService.fetchOrder(id: orderID) {
                order = found
                error = nil
            } else {
                error = "订单不存在"
            }
        } catch is CancellationError {
        } catch {
            self.error = AppError.message(error)
        }
    }
}

/// 新建出库订单（Issue #30）
///   * 经销商：按公司名称搜索、自动补全；默认显示最近一次选择的经销商；停用的经销商不出现
///   * 自动选择默认地址，可切换为其他有效地址
///   * 创建后进入出库扫码页
struct NewOrderView: View {
    var onCreated: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var dealers: DealerStore
    @EnvironmentObject private var network: NetworkMonitor
    @State private var query = ""
    @State private var dealerID: UUID?
    @State private var addressID: UUID?
    @State private var creating = false
    @State private var error: String?
    /// 连点“创建”只生成一张订单；更换经销商或地址后换新的请求编号
    @State private var requestID = UUID()
    /// 已选过经销商（自动或手动）：之后列表加载完成不再自动选择，避免覆盖用户的选择
    @State private var didSelect = false

    private var dealer: Dealer? { dealerID.flatMap(dealers.dealer(id:)) }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }

                Section("经销商") {
                    if let dealer {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dealer.companyName).font(.headline)
                                Text("\(dealer.contactName)  \(dealer.phone)").font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("更换") { select(nil) }.buttonStyle(.bordered)
                        }
                    } else {
                        TextField("输入公司名称搜索", text: $query)
                            .autocorrectionDisabled()
                        let matches = dealers.filtered(query, activeOnly: true)
                        if matches.isEmpty {
                            Text(dealers.dealers.isEmpty ? "还没有经销商，请先在“经销商”中添加" : "没有匹配的启用经销商")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(matches.prefix(8)) { d in
                            Button {
                                select(d)
                            } label: {
                                HStack {
                                    Text(d.companyName).foregroundStyle(.primary)
                                    Spacer()
                                    Text(d.contactName).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                if let dealer {
                    Section("收货地址") {
                        if dealer.activeAddresses.isEmpty {
                            Text("该经销商没有有效地址，请先在经销商详情中添加").foregroundStyle(.red)
                        }
                        ForEach(dealer.activeAddresses) { address in
                            Button {
                                addressID = address.id
                                requestID = UUID()
                            } label: {
                                HStack {
                                    Image(systemName: addressID == address.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(.tint)
                                    Text(address.displayText).foregroundStyle(.primary)
                                    Spacer()
                                    if address.isDefault { StatusBadge(text: "默认", color: .blue) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("新建出库订单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(creating) }
                ToolbarItem(placement: .confirmationAction) {
                    if creating {
                        ProgressView()
                    } else {
                        Button("创建订单", action: create)
                            .disabled(dealer == nil || addressID == nil)
                            .requiresOnline()
                    }
                }
            }
            .interactiveDismissDisabled(creating)
            .task {
                await dealers.reload()
                if !didSelect, let last = dealers.lastSelectedID,
                   let d = dealers.dealer(id: last), d.active {
                    select(d)
                }
            }
        }
    }

    private func select(_ d: Dealer?) {
        didSelect = true
        dealerID = d?.id
        addressID = d?.defaultAddress?.id
        requestID = UUID()
        if d == nil { query = "" }
    }

    private func create() {
        guard let dealer, let addressID, !creating, network.isOnline else { return }
        creating = true
        error = nil
        Task {
            defer { creating = false }
            do {
                let created = try await OrderService.createOrder(dealerID: dealer.id, addressID: addressID, requestID: requestID)
                dealers.lastSelectedID = dealer.id
                dismiss()
                onCreated(created.orderId)
            } catch {
                if AppError.isBusiness(error) { requestID = UUID() }
                self.error = AppError.message(error)
            }
        }
    }
}
