import SwiftUI

/// 首页（Issue #42，需求 16.1）
///   当前库存总数、型号数量、当月入库 / 出库 / 订单数 / 销售金额 / 运费、即将过保数量。
///   “当月”按北京时间自然月；数字来自 dashboard_summary，与报表页一致。点击数字跳转到对应页面。
struct HomeView: View {
    /// 跳转到侧边栏中的其他页面
    var open: (HomeDestination) -> Void

    @State private var summary: DashboardSummary?
    @State private var error: String?
    @State private var appeared = false

    private let columns = [GridItem(.adaptive(minimum: 220), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
                if let s = summary {
                    group("库存") {
                        tile("当前库存总数", "\(s.stockQty)", "shippingbox", .blue) { open(.products) }
                        tile("型号数量", "\(s.modelCount)", "square.grid.2x2", .indigo) { open(.products) }
                        tile("即将过保", "\(s.expiringQty)", "exclamationmark.shield", .orange) { open(.expiringWarranty) }
                    }
                    group("\(s.monthTitle)（北京时间）") {
                        tile("当月入库", "\(s.monthInQty)", "tray.and.arrow.down", .teal) { open(.monthlyReport) }
                        tile("当月出库", "\(s.monthOutQty)", "tray.and.arrow.up", .green) { open(.orders) }
                        tile("当月订单数", "\(s.monthOrderCount)", "doc.text", .mint) { open(.orders) }
                        tile("当月销售金额", Money.format(s.monthSales), "yensign.circle", .pink) { open(.monthlyReport) }
                        tile("当月运费", Money.format(s.monthShipping), "truck.box", .brown) { open(.shippingReport) }
                    }
                } else if error == nil {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(20)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("首页")
        .refreshable { await load() }
        .task { await load() }
        // 从其他页面返回时刷新
        .onAppear {
            if appeared { Task { await load() } }
            appeared = true
        }
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            LazyVGrid(columns: columns, spacing: 16, content: content)
        }
    }

    private func tile(_ title: String, _ value: String, _ icon: String, _ color: Color,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon).foregroundStyle(color)
                    Text(title).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                Text(value)
                    .font(.system(size: 34, weight: .bold).monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        do {
            summary = try await ReportService.dashboard()
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = AppError.message(error)
        }
    }
}

/// 首页数字点击后跳转的位置
enum HomeDestination {
    case products, orders, expiringWarranty, monthlyReport, shippingReport
}
