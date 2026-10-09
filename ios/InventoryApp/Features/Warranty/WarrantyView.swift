import SwiftUI

/// 保修查询（Issue #37，需求 13）
///   按名称、型号、条码、机身号、经销商搜索；按出库日期、保修状态筛选；扫机身号直接查询。
///   默认只看每台产品的当前保修（最近一次有效出库），可以切换为包含历次记录。
struct WarrantyView: View {
    @State private var filter = WarrantyService.Filter()
    @State private var records: [WarrantyRecord] = []
    @State private var loading = false
    @State private var error: String?
    @State private var showScanner = false
    @State private var useDates = false
    @State private var from = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var to = Date()

    init(initialStatus: WarrantyService.StatusFilter = .all) {
        _filter = State(initialValue: WarrantyService.Filter(status: initialStatus))
    }

    private var effectiveFilter: WarrantyService.Filter {
        var f = filter
        f.shippedFrom = useDates ? from : nil
        f.shippedTo = useDates ? to : nil
        return f
    }

    var body: some View {
        List {
            Section {
                Picker("保修状态", selection: $filter.status) {
                    ForEach(WarrantyService.StatusFilter.allCases) { s in
                        Text(s.title).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("只看当前保修（每台产品最近一次有效出库）", isOn: $filter.currentOnly)
                Toggle("按出库日期筛选", isOn: $useDates)
                if useDates {
                    DatePicker("从", selection: $from, displayedComponents: .date)
                    DatePicker("到", selection: $to, in: from..., displayedComponents: .date)
                }
            } footer: {
                Text("保修期为出库日起一年，按北京时间计算；截止日当天仍在保修中。即将过保 = 30 天内到期。")
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }

            Section(records.isEmpty ? "" : "共 \(records.count) 条") {
                ForEach(records) { record in
                    NavigationLink(value: OrderLink(id: record.orderId)) {
                        WarrantyRow(record: record)
                    }
                }
            }
        }
        .overlay {
            if records.isEmpty, !loading, error == nil {
                Text("没有符合条件的保修记录").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $filter.query, prompt: "搜索名称、型号、条码、机身号、经销商或单号")
        .navigationTitle("保修查询")
        .navigationDestination(for: OrderLink.self) { link in
            OrderView(orderID: link.id)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showScanner = true
                } label: {
                    Label("扫描机身号", systemImage: "barcode.viewfinder")
                }
            }
        }
        .sheet(isPresented: $showScanner) {
            SingleScanSheet(step: .serialNumber) { code in
                // 扫机身号直接查询：显示该机身号的历次保修记录
                filter = WarrantyService.Filter(query: code, status: .all, currentOnly: false)
                useDates = false
            }
        }
        .task(id: effectiveFilter) {
            // 输入搜索词时稍等再查询，避免每输入一个字发一次请求（新的输入会取消上一次等待）
            if !effectiveFilter.query.isEmpty {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
            }
            await load()
        }
        .refreshable { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            records = try await WarrantyService.search(effectiveFilter)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = AppError.message(error)
        }
    }
}

struct WarrantyRow: View {
    let record: WarrantyRecord

    private var statusText: String {
        if record.expiringSoon, let days = record.daysLeft {
            return days == 0 ? "今天到期" : "即将过保（\(days) 天）"
        }
        return record.warrantyStatus.title
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(record.serialNo).font(.headline.monospaced())
                    Text(record.displayName).foregroundStyle(.secondary)
                    if record.isCurrent { StatusBadge(text: "当前", color: .blue) }
                }
                Text([record.dealerName, record.orderNo].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                Text("出库 \(record.shippedAt?.formatted(date: .numeric, time: .omitted) ?? "—") · 条码 \(record.barcode)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                StatusBadge(text: statusText, color: record.expiringSoon ? .orange : record.warrantyStatus.color)
                Text("保修至 \(record.warrantyEnd)").font(.subheadline.monospacedDigit())
            }
        }
        .padding(.vertical, 4)
        .opacity(record.warrantyStatus == .void ? 0.6 : 1)
    }
}
