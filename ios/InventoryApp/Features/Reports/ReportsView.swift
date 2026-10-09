import SwiftUI

/// 统计报表（Issue #44–#52，需求 15）
///   顶部切换五类报表；统一筛选栏（月份 / 自定义日期、经销商、型号、机身号、订单状态、保修状态），
///   切换报表时保留筛选条件。导出 Excel / CSV / PDF 与屏幕内容一致。
struct ReportsView: View {
    @State private var kind: ReportService.Kind
    @State private var filter = ReportService.Filter()
    @State private var document: ReportDocument?
    @State private var loading = false
    @State private var error: String?
    @State private var exportURL: ExportFile?
    @State private var exportError: String?

    @EnvironmentObject private var dealers: DealerStore
    @EnvironmentObject private var products: ProductStore

    struct ExportFile: Identifiable {
        let url: URL
        var id: URL { url }
    }

    init(initialKind: ReportService.Kind = .monthly) {
        _kind = State(initialValue: initialKind)
    }

    private struct LoadKey: Equatable {
        let kind: ReportService.Kind
        let filter: ReportService.Filter
    }

    private var dealerName: String? {
        filter.dealerID.flatMap { id in dealers.dealers.first { $0.id == id }?.companyName }
    }

    private var modelName: String? {
        filter.modelID.flatMap { id in products.model(id: id)?.displayName }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("报表", selection: $kind) {
                    ForEach(ReportService.Kind.allCases) { k in
                        Text(k.shortTitle).tag(k)
                    }
                }
                .pickerStyle(.segmented)

                ReportFilterBar(filter: $filter)

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                if let document {
                    ForEach(document.tables) { table in
                        ReportTableView(table: table)
                    }
                    if let note = document.note {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                } else if error == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .padding(20)
            .opacity(loading && document != nil ? 0.5 : 1)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(kind.title)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(ReportExporter.Format.allCases) { format in
                        Button(format.title) { export(format) }
                    }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .disabled(document == nil || loading)
            }
        }
        .sheet(item: $exportURL) { file in
            ShareSheet(items: [file.url])
        }
        .alert("导出失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("好", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .task(id: LoadKey(kind: kind, filter: filter)) {
            // 输入机身号时稍等再查询（新的输入会取消上一次等待）
            if !filter.serialNo.isEmpty {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
            }
            await load()
        }
        .refreshable { await load() }
        .task {
            if dealers.dealers.isEmpty { await dealers.reload() }
            if products.models.isEmpty { await products.reload() }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            document = try await ReportService.load(kind, filter: filter, dealerName: dealerName, modelName: modelName)
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = AppError.message(error)
        }
    }

    private func export(_ format: ReportExporter.Format) {
        guard let document else { return }
        do {
            exportURL = ExportFile(url: try ReportExporter.export(document, as: format))
        } catch {
            exportError = AppError.message(error)
        }
    }
}

// MARK: - 筛选栏（Issue #49）

struct ReportFilterBar: View {
    @Binding var filter: ReportService.Filter

    @EnvironmentObject private var dealers: DealerStore
    @EnvironmentObject private var products: ProductStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 宽度不够（竖屏且侧边栏展开）时，时间选择和日期分两行显示
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    periodPicker
                    periodDetail
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    periodPicker
                    HStack(spacing: 12) { periodDetail }
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { pickers }
                VStack(alignment: .leading, spacing: 8) { pickers }
            }

            HStack(spacing: 12) {
                TextField("机身号（精确匹配）", text: $filter.serialNo)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                Spacer()
                if filter != ReportService.Filter(period: filter.period, month: filter.month,
                                                  from: filter.from, to: filter.to) {
                    Button("清除筛选") {
                        filter = ReportService.Filter(period: filter.period, month: filter.month,
                                                      from: filter.from, to: filter.to)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var periodPicker: some View {
        Picker("时间", selection: $filter.period) {
            ForEach(ReportService.Period.allCases) { p in
                Text(p.title).tag(p)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 300)
    }

    @ViewBuilder
    private var periodDetail: some View {
        switch filter.period {
        case .month:
            monthStepper
        case .custom:
            DatePicker("从", selection: $filter.from, displayedComponents: .date).labelsHidden()
            Text("至")
            DatePicker("到", selection: $filter.to, in: filter.from..., displayedComponents: .date).labelsHidden()
        case .all:
            EmptyView()
        }
    }

    private var monthStepper: some View {
        HStack(spacing: 4) {
            Button {
                shiftMonth(-1)
            } label: {
                Image(systemName: "chevron.left").frame(width: 36, height: 36)
            }
            .accessibilityLabel("上个月")
            Text(BeijingDate.monthTitle(filter.month))
                .font(.headline.monospacedDigit())
                .frame(minWidth: 110)
            Button {
                shiftMonth(1)
            } label: {
                Image(systemName: "chevron.right").frame(width: 36, height: 36)
            }
            .accessibilityLabel("下个月")
            .disabled(BeijingDate.monthStart(filter.month) >= BeijingDate.monthStart(Date()))
        }
        .buttonStyle(.bordered)
    }

    private func shiftMonth(_ delta: Int) {
        filter.month = BeijingDate.calendar.date(byAdding: .month, value: delta,
                                                 to: BeijingDate.monthStart(filter.month)) ?? filter.month
    }

    @ViewBuilder
    private var pickers: some View {
        Picker("经销商", selection: $filter.dealerID) {
            Text("全部经销商").tag(UUID?.none)
            ForEach(dealers.dealers) { d in
                Text(d.companyName).tag(UUID?.some(d.id))
            }
        }
        Picker("型号", selection: $filter.modelID) {
            Text("全部型号").tag(UUID?.none)
            ForEach(products.models) { m in
                Text(m.displayName).tag(UUID?.some(m.id))
            }
        }
        Picker("订单状态", selection: $filter.orderStatus) {
            ForEach(ReportService.OrderStatusFilter.allCases) { s in
                Text(s.title).tag(s)
            }
        }
        Picker("保修状态", selection: $filter.warranty) {
            Text("全部保修状态").tag(ReportService.WarrantyFilter?.none)
            ForEach(ReportService.WarrantyFilter.allCases) { w in
                Text(w.title).tag(ReportService.WarrantyFilter?.some(w))
            }
        }
    }
}

// MARK: - 表格

struct ReportTableView: View {
    let table: ReportTable

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(table.title).font(.headline)
                Spacer()
                Text("\(table.rows.count) 行").font(.caption).foregroundStyle(.secondary)
            }
            if table.rows.isEmpty {
                Text("没有符合条件的数据").foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        GridRow {
                            ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                                Text(column.title)
                                    .font(.subheadline.bold())
                                    .foregroundStyle(.secondary)
                                    .gridColumnAlignment(column.numeric ? .trailing : .leading)
                            }
                        }
                        Divider()
                        ForEach(Array(table.rows.enumerated()), id: \.offset) { _, values in
                            row(values, bold: false)
                        }
                        if let total = table.total {
                            Divider()
                            row(total, bold: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ values: [ReportValue], bold: Bool) -> some View {
        GridRow {
            ForEach(table.columns.indices, id: \.self) { i in
                let value = values.indices.contains(i) ? values[i] : .none
                Text(value.display)
                    .font(bold ? .body.bold().monospacedDigit() : .body.monospacedDigit())
                    .lineLimit(2)
                    .frame(maxWidth: 320, alignment: table.columns[i].numeric ? .trailing : .leading)
            }
        }
    }
}

// MARK: - 系统分享面板

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
