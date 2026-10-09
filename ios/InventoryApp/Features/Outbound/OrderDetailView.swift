import SwiftUI

/// 出库订单详情（Issue #35）：快照信息、明细、运费、金额；撤销出库（Issue #36）
struct OrderDetailView: View {
    let orderID: UUID
    /// 刚确认出库成功时显示结果
    var justConfirmed: ConfirmOrderResult?

    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var products: ProductStore
    @State private var order: OrderSummary?
    @State private var items: [OrderItem] = []
    @State private var error: String?
    @State private var showCancel = false
    @State private var cancelled = false

    var body: some View {
        Group {
            if let order {
                content(order)
            } else if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func content(_ order: OrderSummary) -> some View {
        Form {
            if let result = justConfirmed, order.status == .completed {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("出库成功").font(.title3.bold())
                            Text("\(result.orderNo)，共 \(result.itemCount) 台，订单总金额 \(Money.format(result.totalAmount))")
                        }
                    } icon: {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title)
                    }
                    .padding(.vertical, 4)
                }
            }
            if cancelled, order.status == .cancelled {
                Section {
                    Label("已撤销，订单中的产品已恢复在库", systemImage: "arrow.uturn.backward.circle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            }

            Section {
                HStack {
                    Text(order.orderNo).font(.title.bold().monospaced())
                    StatusBadge(text: order.status.title, color: order.status.color)
                }
                .padding(.vertical, 4)
                if let shippedAt = order.shippedAt {
                    LabeledContent("出库时间", value: shippedAt.formatted(date: .numeric, time: .shortened))
                }
                LabeledContent("创建时间", value: order.createdAt.formatted(date: .numeric, time: .shortened))
                if let note = order.note {
                    LabeledContent("备注", value: note)
                }
            }

            if order.status == .cancelled {
                Section("撤销") {
                    LabeledContent("撤销时间", value: order.cancelledAt?.formatted(date: .numeric, time: .shortened) ?? "—")
                    LabeledContent("撤销原因", value: order.cancelReason ?? "—")
                    Text(order.shippedAt == nil
                         ? "该订单在编辑中作废，没有出库。"
                         : "订单保留在历史中，金额和运费不计入统计，本次保修已失效。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("经销商", value: order.dealerName)
                LabeledContent("联系人", value: order.contactName)
                LabeledContent("电话号码", value: order.phone)
                LabeledContent("收货地址", value: order.addressText ?? "—")
            } header: {
                Text("经销商与收货地址")
            } footer: {
                if order.shippedAt != nil {
                    Text("确认出库时保存的快照，之后修改经销商资料或地址不会改变本订单。")
                }
            }

            Section("产品明细（\(items.count) 台）") {
                ForEach(items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.serialNo).font(.body.monospaced().bold())
                            Text(item.modelName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let end = item.warrantyEnd {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("保修至").font(.caption2).foregroundStyle(.secondary)
                                Text(end).font(.caption.monospacedDigit())
                            }
                            .padding(.trailing, 12)
                        }
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Money.format(item.actualPrice)).monospacedDigit()
                            if item.priceModified {
                                Text("默认 \(Money.format(item.defaultPrice))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("金额") {
                LabeledContent("产品金额合计", value: Money.format(order.productsAmount))
                LabeledContent("运费", value: order.shippingFee.map(Money.format) ?? "未填写")
                LabeledContent("订单总金额") {
                    Text(Money.format(order.totalAmount)).font(.title3.bold())
                        .strikethrough(order.status == .cancelled)
                }
            }

            if order.status == .completed {
                Section {
                    Button("撤销出库", role: .destructive) { showCancel = true }
                        .requiresOnline()
                } footer: {
                    Text("撤销后订单中的产品恢复在库，本次保修失效，订单保留在历史中。")
                }
            }
        }
        .navigationTitle(order.orderNo)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCancel) {
            CancelOrderSheet(order: order) {
                cancelled = true
                Task {
                    await load()
                    await products.reload()
                }
            }
        }
    }

    private func load() async {
        do {
            async let o = OrderService.fetchOrder(id: orderID)
            async let i = OrderService.fetchItems(orderID: orderID)
            let (fetched, fetchedItems) = try await (o, i)
            order = fetched
            items = fetchedItems
            error = fetched == nil ? "订单不存在" : nil
        } catch is CancellationError {
        } catch {
            self.error = AppError.message(error)
        }
    }
}

/// 撤销出库：必须填写原因，再二次确认（需求 12.5、20.3）
struct CancelOrderSheet: View {
    let order: OrderSummary
    var onCancelled: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var network: NetworkMonitor
    @State private var reason = ""
    @State private var confirming = false
    @State private var working = false
    @State private var error: String?
    /// 超时重试使用同一个请求编号，库存只恢复一次
    @State private var requestID = UUID()

    private var trimmedReason: String { reason.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red) }
                }
                Section {
                    LabeledContent("订单", value: order.orderNo)
                    LabeledContent("经销商", value: order.dealerName)
                    LabeledContent("产品数量", value: "\(order.itemCount) 台")
                    LabeledContent("订单总金额", value: Money.format(order.totalAmount))
                }
                Section {
                    TextField("撤销原因（必填）", text: $reason, axis: .vertical).lineLimit(2...5)
                } footer: {
                    Text("撤销后：订单改为已撤销，产品恢复在库，本次保修失效，金额和运费不计入统计。")
                }
            }
            .navigationTitle("撤销出库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(working) }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("撤销", role: .destructive) { confirming = true }
                            .disabled(trimmedReason.isEmpty)
                            .requiresOnline()
                    }
                }
            }
            .interactiveDismissDisabled(working)
            .confirmationDialog("确定撤销订单 \(order.orderNo)？", isPresented: $confirming, titleVisibility: .visible) {
                Button("确定撤销", role: .destructive, action: submit)
            } message: {
                Text("\(order.itemCount) 台产品将恢复在库。")
            }
        }
    }

    private func submit() {
        guard !trimmedReason.isEmpty, !working, network.isOnline else { return }
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                try await OrderService.cancel(orderID: order.id, reason: trimmedReason, requestID: requestID)
                onCancelled()
                dismiss()
            } catch {
                if AppError.isBusiness(error) { requestID = UUID() }
                self.error = AppError.message(error)
            }
        }
    }
}
