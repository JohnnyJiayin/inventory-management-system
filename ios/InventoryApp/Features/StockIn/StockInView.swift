import SwiftUI

/// 入库页面（需求 9、16.3）
///   扫产品条码 → 显示型号信息 → 输入计划数量 → 连续扫机身号 → 核对清单 → 确认入库
struct StockInView: View {
    /// 由 MainView 持有：切换到其他页面再回来，已扫描的清单不会丢失
    @ObservedObject var vm: StockInViewModel
    @EnvironmentObject private var network: NetworkMonitor
    @EnvironmentObject private var store: ProductStore

    var body: some View {
        GeometryReader { geo in
            // 弹出键盘时可用高度变小（例如 iPad mini 竖屏），可能在横竖布局间切换。用 AnyLayout 切换布局，
            // 扫码组件不会被重建（否则“手动输入”弹窗刚弹出就被关闭）
            let landscape = geo.size.width > geo.size.height
            let layout = landscape
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                : AnyLayout(VStackLayout(spacing: 20))
            ScrollView {
                layout {
                    scanColumn.frame(maxWidth: .infinity)
                    listColumn.frame(width: landscape ? min(420, geo.size.width * 0.42) : nil)
                }
                .padding()
            }
        }
        .navigationTitle("入库")
        .toolbar {
            if vm.model != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("更换型号") { vm.changeModel() }
                        .disabled(vm.isWorking)
                }
            }
        }
        .sheet(item: Binding(get: { vm.unknownBarcode.map(IdentifiedString.init) },
                             set: { vm.unknownBarcode = $0?.value })) { code in
            UnknownBarcodeSheet(barcode: code.value) { model in
                vm.select(model)
            }
        }
        .alert("该产品曾经出库，是否重新入库", isPresented: Binding(
            get: { vm.pendingRestock != nil }, set: { if !$0 { vm.pendingRestock = nil } }),
            presenting: vm.pendingRestock) { pending in
            Button("重新入库") { vm.confirmRestock(pending) }
            Button("取消", role: .cancel) {}
        } message: { pending in
            Text("机身号 \(pending.unit.serialNo)" +
                 (pending.unit.lastOutAt.map { "\n最近出库：\($0.formatted(date: .numeric, time: .shortened))" } ?? "") +
                 "\n重新入库后，原出库订单和保修记录仍会保留。")
        }
        .onChange(of: vm.lastResult) { _ in Task { await store.reload() } }
    }

    // MARK: - 左侧：扫码与型号

    private var scanColumn: some View {
        VStack(spacing: 16) {
            ScannerPanel(step: vm.step,
                         isPaused: vm.isWorking || vm.pendingRestock != nil || vm.unknownBarcode != nil,
                         height: 300) { code in
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
                ModelCard(model: model)
            }
        }
    }

    // MARK: - 右侧：数量、清单、确认

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("计划入库数量").font(.headline)
                Spacer()
                TextField("数量", value: $vm.plannedQty, format: .number)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.title3.monospacedDigit())
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                Stepper("", value: $vm.plannedQty, in: 1...9999).labelsHidden()
            }
            .disabled(vm.model == nil || vm.isWorking)

            CountersView(planned: vm.plannedQty, scanned: vm.items.count)

            VStack(alignment: .leading, spacing: 0) {
                Text("入库清单").font(.headline).padding(.bottom, 8)
                if vm.items.isEmpty {
                    Text(vm.model == nil ? "先扫描产品条码" : "扫描机身号后显示在这里")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ForEach(Array(vm.items.enumerated()), id: \.element.id) { index, item in
                        HStack {
                            Text("\(index + 1).").foregroundStyle(.secondary).monospacedDigit()
                            Text(item.serialNo).font(.body.monospaced())
                            if item.type == .restock { StatusBadge(text: "重新入库", color: .orange) }
                            Spacer()
                            Button(role: .destructive) {
                                vm.remove(item)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(vm.isWorking)
                            .accessibilityLabel("删除 \(item.serialNo)")
                        }
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
            }
            .padding()
            .background(Color(uiColor: .secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if let blocker = vm.confirmBlocker, vm.model != nil {
                Text(blocker).font(.footnote).foregroundStyle(.secondary)
            }

            Button {
                Task { await vm.confirm(online: network.isOnline) }
            } label: {
                Group {
                    if vm.submitting { ProgressView() } else { Text("确认入库（\(vm.items.count) 台）") }
                }
                .font(.title3.bold())
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(vm.confirmBlocker != nil || vm.submitting)
            .requiresOnline()
        }
    }
}

/// 当前识别出的型号
struct ModelCard: View {
    let model: ProductModel

    var body: some View {
        HStack(spacing: 16) {
            ProductPhotoView(path: model.photoPath, size: 88)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.name).font(.title2.bold())
                Text(model.model).font(.title3).foregroundStyle(.secondary)
                Label(model.barcode, systemImage: "barcode").font(.subheadline.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            VStack {
                Text("\(model.stockQty)").font(.largeTitle.bold().monospacedDigit())
                Text("当前库存").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct IdentifiedString: Identifiable {
    let value: String
    var id: String { value }
}
