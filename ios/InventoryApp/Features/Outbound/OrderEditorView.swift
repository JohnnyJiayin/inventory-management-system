import SwiftUI

/// 出库扫码页（需求 12.2–12.4、16.4）
///   顶部固定：出库单号、经销商、联系人、电话、收货地址
///   中部：扫码区域、当前步骤、当前型号及默认单价、已扫产品清单
///   底部固定：产品总数、产品金额合计、运费、订单总金额、确认出库
struct OrderEditorView: View {
    var onConfirmed: (ConfirmOrderResult?) -> Void
    var onCancelled: () -> Void

    @StateObject private var vm: OrderEditorViewModel
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var products: ProductStore
    @FocusState private var feeFocused: Bool
    @State private var priceEditing: OrderItem?
    @State private var priceText = ""
    @State private var showPriceSetup = false
    @State private var showDiscard = false
    @State private var discardReason = ""

    init(orderID: UUID, onConfirmed: @escaping (ConfirmOrderResult?) -> Void, onCancelled: @escaping () -> Void) {
        _vm = StateObject(wrappedValue: OrderEditorViewModel(orderID: orderID))
        self.onConfirmed = onConfirmed
        self.onCancelled = onCancelled
    }

    var body: some View {
        VStack(spacing: 0) {
            if let order = vm.order {
                header(order)
                Divider()
                GeometryReader { geo in
                    // 弹出键盘时可用高度变小，可能在横竖布局间切换。用 AnyLayout 切换布局，
                    // 扫码组件不会被重建（否则“手动输入”弹窗刚弹出就被关闭）
                    // 竖屏且侧边栏展开时内容区较窄，仍用上下布局
                    let landscape = geo.size.width > geo.size.height && geo.size.width >= 700
                    let layout = landscape
                        ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                        : AnyLayout(VStackLayout(spacing: 20))
                    ScrollView {
                        layout {
                            scanColumn.frame(maxWidth: .infinity)
                            listColumn.frame(width: landscape ? min(440, geo.size.width * 0.44) : nil)
                        }
                        .padding()
                    }
                }
                Divider()
                footer
            } else if let error = vm.loadError {
                VStack(spacing: 12) {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("重试") { Task { await vm.load() } }.buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("出库扫码")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if vm.model != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("更换型号") { vm.changeModel() }.disabled(vm.isWorking)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("作废订单", role: .destructive) {
                        discardReason = ""
                        showDiscard = true
                    }
                    .requiresOnline()
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                }
                .disabled(vm.isWorking)
            }
        }
        .task { await vm.load() }
        .onChange(of: feeFocused) { focused in
            if !focused { vm.saveFee() }
        }
        .onDisappear { vm.saveFeeOnLeave() }
        .sheet(isPresented: $showPriceSetup) {
            if let order = vm.order, let model = vm.model {
                PriceFormView(dealerID: order.dealerId, dealerName: order.dealerName,
                              modelID: model.id, current: nil) {
                    Task { await vm.reloadPrice() }
                }
            }
        }
    }

    // MARK: - 顶部：订单与经销商

    private func header(_ order: OrderSummary) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("出库单号").font(.caption).foregroundStyle(.secondary)
                Text(order.orderNo).font(.title2.bold().monospaced())
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("经销商").font(.caption).foregroundStyle(.secondary)
                Text(order.dealerName).font(.title3.bold())
                Text("\(order.contactName)  \(order.phone)").font(.subheadline)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("收货地址").font(.caption).foregroundStyle(.secondary)
                Menu {
                    ForEach(vm.addresses) { address in
                        Button {
                            vm.changeAddress(address)
                        } label: {
                            if address.id == order.addressId {
                                Label(address.displayText, systemImage: "checkmark")
                            } else {
                                Text(address.displayText)
                            }
                        }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text([order.addressLabel, order.addressText].compactMap { $0 }.joined(separator: "："))
                            .multilineTextAlignment(.leading)
                        Image(systemName: "chevron.down").font(.caption)
                    }
                }
                .disabled(vm.isWorking || !network.isOnline)
                .accessibilityLabel("更换收货地址")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    // MARK: - 中部：扫码与型号

    private var scanColumn: some View {
        VStack(spacing: 16) {
            ScannerPanel(step: vm.step,
                         isPaused: vm.isWorking || vm.pendingAdd != nil || !network.isOnline,
                         height: 280) { code in
                vm.handle(code)
            }
            if let message = vm.message {
                Label(message.text, systemImage: message.isError ? "xmark.octagon.fill" : "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(message.isError ? .red : .green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background((message.isError ? Color.red : Color.green).opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if let model = vm.model {
                VStack(alignment: .leading, spacing: 10) {
                    ModelCard(model: model)
                    HStack {
                        if let price = vm.modelPrice {
                            Text("默认单价").foregroundStyle(.secondary)
                            Text(Money.format(price)).font(.title3.bold().monospacedDigit())
                        } else {
                            Label("当前经销商尚未设置该型号的价格", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Button("设置单价") { showPriceSetup = true }
                                .buttonStyle(.borderedProminent)
                                .requiresOnline()
                        }
                        Spacer()
                        Text("更换型号：直接扫描新的产品条码").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - 中部：已扫产品清单

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("已扫描产品（\(vm.items.count) 台）").font(.headline)
                Spacer()
                if vm.busy { ProgressView() }
            }
            .padding(.bottom, 8)
            if vm.items.isEmpty {
                Text(vm.model == nil ? "先扫描产品条码" : "扫描机身号后显示在这里")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 10) {
                        Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.serialNo).font(.body.monospaced().bold())
                            Text(item.modelName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Money.format(item.actualPrice)).monospacedDigit()
                            if item.priceModified {
                                Text(Money.format(item.defaultPrice))
                                    .font(.caption).strikethrough().foregroundStyle(.secondary)
                            }
                        }
                        if vm.canEditPrice {
                            Button("改价") {
                                priceText = Money.plain(item.actualPrice)
                                priceEditing = item
                            }
                            .buttonStyle(.bordered)
                            .disabled(vm.isWorking)
                            .requiresOnline()
                    .alert("修改实际单价", isPresented: Binding(
                        get: { priceEditing != nil }, set: { if !$0 { priceEditing = nil } }),
                        presenting: priceEditing) { item in
                        TextField("实际单价（元）", text: $priceText).keyboardType(.decimalPad)
                        Button("保存") { vm.setPrice(item, text: priceText) }
                        Button("取消", role: .cancel) {}
                    } message: { item in
                        Text("默认单价 \(Money.format(item.defaultPrice))。只影响本订单，不改经销商默认价格；售后补发可填 0。")
                    }
                        }
                        Button(role: .destructive) {
                            vm.remove(item)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .disabled(vm.isWorking)
                        .requiresOnline()
                        .accessibilityLabel("删除 \(item.serialNo)")
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
                if vm.items.count > 1 {
                    Text("多台订单按经销商默认单价出库，不能改价。")
                        .font(.footnote).foregroundStyle(.secondary).padding(.top, 8)
                }
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .alert("多台订单不能改价", isPresented: Binding(
            get: { vm.pendingAdd != nil }, set: { if !$0 { vm.pendingAdd = nil } }),
            presenting: vm.pendingAdd) { pending in
            Button("继续加入") { vm.confirmPendingAdd(pending) }
            Button("取消", role: .cancel) {}
        } message: { pending in
            Text("多台订单不能改价，已改的价格将恢复为默认单价。\n确认加入机身号 \(pending.serialNo)？")
        }
    }

    // MARK: - 底部：金额与确认

    private var footer: some View {
        VStack(spacing: 8) {
            // 宽度不够（竖屏小尺寸 iPad）时金额和确认按钮分两行
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 24) {
                    amounts
                    Spacer(minLength: 0)
                    confirmButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 24) { amounts }
                    confirmButton.frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            if let blocker = vm.confirmBlocker {
                Text(blocker).font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .alert("作废订单", isPresented: $showDiscard) {
            TextField("作废原因（必填）", text: $discardReason)
            Button("作废", role: .destructive) {
                let reason = discardReason.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !reason.isEmpty else { return }
                Task { if await vm.discard(reason: reason) { onCancelled() } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("编辑中的订单还没有出库，作废后不影响库存，订单保留在历史中。")
        }
    }

    @ViewBuilder
    private var amounts: some View {
        summary("产品总数", "\(vm.items.count) 台")
        summary("产品金额合计", Money.format(vm.productsAmount))
        VStack(alignment: .leading, spacing: 2) {
            Text("运费（必填，没有填 0）").font(.caption).foregroundStyle(.secondary)
            TextField("运费", text: $vm.feeText)
                .keyboardType(.decimalPad)
                .focused($feeFocused)
                .font(.title3.monospacedDigit())
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
                .disabled(vm.submitting || !network.isOnline)
                .onSubmit { vm.saveFee() }
        }
        summary("订单总金额", Money.format(vm.totalAmount), prominent: true)
    }

    private var confirmButton: some View {
        Button {
            feeFocused = false
            Task {
                let outcome = await vm.confirm(online: network.isOnline)
                if outcome.completed {
                    await products.reload()
                    onConfirmed(outcome.result)
                }
            }
        } label: {
            Group {
                if vm.submitting { ProgressView() } else { Text("确认出库（\(vm.items.count) 台）") }
            }
            .font(.title3.bold())
            .frame(minWidth: 180, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(vm.confirmBlocker != nil || vm.isWorking)
        .requiresOnline()
    }

    private func summary(_ title: String, _ value: String, prominent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(prominent ? .title2.bold().monospacedDigit() : .title3.monospacedDigit())
        }
    }
}
