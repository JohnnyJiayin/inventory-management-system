import SwiftUI

/// 库存多条件查询（Issue #40，需求 14）：机身号、库存状态、经销商、入库时间、出库时间、保修状态。
/// 在副本上修改，点“完成”才生效。
struct InventoryFilterSheet: View {
    @Binding var filter: InventoryService.Filter

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var dealers: DealerStore
    @State private var draft = InventoryService.Filter()
    @State private var showScanner = false

    private static let defaultFrom = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("单台产品") {
                    HStack {
                        TextField("机身号（包含即可）", text: $draft.serialNo)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            showScanner = true
                        } label: {
                            Image(systemName: "barcode.viewfinder")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("扫描机身号")
                    }
                    Picker("库存状态", selection: $draft.unitStatus) {
                        Text("不限").tag(InventoryService.UnitStatusFilter?.none)
                        ForEach(InventoryService.UnitStatusFilter.allCases) { s in
                            Text(s.title).tag(InventoryService.UnitStatusFilter?.some(s))
                        }
                    }
                }

                Section("入库") {
                    dateRange("按入库日期筛选", from: $draft.inFrom, to: $draft.inTo)
                }

                Section {
                    Picker("经销商", selection: $draft.dealerID) {
                        Text("不限").tag(UUID?.none)
                        ForEach(dealers.dealers) { d in
                            Text(d.active ? d.companyName : "\(d.companyName)（已停用）").tag(UUID?.some(d.id))
                        }
                    }
                    dateRange("按出库日期筛选", from: $draft.outFrom, to: $draft.outTo)
                    Picker("保修状态", selection: $draft.warranty) {
                        Text("不限").tag(InventoryService.WarrantyFilter?.none)
                        ForEach(InventoryService.WarrantyFilter.allCases) { s in
                            Text(s.title).tag(InventoryService.WarrantyFilter?.some(s))
                        }
                    }
                } header: {
                    Text("出库与保修")
                } footer: {
                    Text("经销商、出库日期、保修状态针对同一次有效出库判断；保修状态按每台产品的当前保修计算。日期按北京时间。")
                }
            }
            .navigationTitle("筛选条件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("清除全部") { draft = InventoryService.Filter() }
                        .disabled(draft.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        filter = draft
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                SingleScanSheet(step: .serialNumber) { code in
                    draft.serialNo = code
                }
            }
            .onAppear { draft = filter }
            .task { if dealers.dealers.isEmpty { await dealers.reload() } }
        }
    }

    /// 开关打开时显示起止日期；关闭时清空
    @ViewBuilder
    private func dateRange(_ title: String, from: Binding<Date?>, to: Binding<Date?>) -> some View {
        Toggle(title, isOn: Binding(
            get: { from.wrappedValue != nil },
            set: { on in
                from.wrappedValue = on ? Self.defaultFrom : nil
                to.wrappedValue = on ? Date() : nil
            }))
        if let start = from.wrappedValue {
            DatePicker("从", selection: Binding(get: { start }, set: { from.wrappedValue = $0 }),
                       displayedComponents: .date)
            DatePicker("到", selection: Binding(get: { to.wrappedValue ?? start }, set: { to.wrappedValue = $0 }),
                       in: start..., displayedComponents: .date)
        }
    }
}
