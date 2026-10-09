import SwiftUI

/// 侧边栏导航（需求 16）。横屏时侧边栏常驻，竖屏时可收起。
struct MainView: View {
    enum Section: String, CaseIterable, Identifiable, Hashable {
        case home, products, stockIn, outbound, dealers, warranty, reports, settings
        var id: Self { self }

        var title: String {
            switch self {
            case .home: "首页"
            case .products: "产品管理"
            case .stockIn: "入库"
            case .outbound: "出库订单"
            case .dealers: "经销商"
            case .warranty: "保修查询"
            case .reports: "报表"
            case .settings: "设置"
            }
        }

        var icon: String {
            switch self {
            case .home: "house"
            case .products: "shippingbox"
            case .stockIn: "tray.and.arrow.down"
            case .outbound: "tray.and.arrow.up"
            case .dealers: "person.2"
            case .warranty: "checkmark.shield"
            case .reports: "chart.bar"
            case .settings: "gearshape"
            }
        }
    }

    @State private var selection: Section? = .home
    /// 从首页“即将过保”进入保修查询时的初始筛选；离开保修查询后恢复默认
    @State private var warrantyPreset = WarrantyService.StatusFilter.all
    @StateObject private var products = ProductStore()
    @StateObject private var stockIn = StockInViewModel()
    @StateObject private var dealers = DealerStore()

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Section.allCases.filter { $0 != .settings }) { section in
                    NavigationLink(value: section) {
                        Label(section.title, systemImage: section.icon)
                    }
                }
                NavigationLink(value: Section.settings) {
                    Label(Section.settings.title, systemImage: Section.settings.icon)
                }
            }
            .navigationTitle("库存管理")
        } detail: {
            NavigationStack {
                switch selection ?? .home {
                case .home: HomeView(open: open)
                case .products: ProductListView()
                case .stockIn: StockInView(vm: stockIn)
                case .outbound: OrderListView()
                case .dealers: DealerListView()
                case .warranty: WarrantyView(initialStatus: warrantyPreset)
                case .reports: ReportsPlaceholderView()
                case .settings: SettingsView()
                }
            }
            // 切换页面时重建导航栈，避免停留在上一个页面的详情页
            .id(selection)
        }
        .onChange(of: selection) { newValue in
            if newValue != .warranty { warrantyPreset = .all }
        }
        .environmentObject(products)
        .environmentObject(dealers)
    }

    private func open(_ destination: HomeDestination) {
        switch destination {
        case .products: selection = .products
        case .orders: selection = .outbound
        case .expiringWarranty:
            warrantyPreset = .expiring
            selection = .warranty
        case .monthlyReport, .shippingReport: selection = .reports
        }
    }
}

/// 尚未实现的页面占位
struct PlaceholderView: View {
    let title: String
    let icon: String
    let note: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 48)).foregroundStyle(.secondary)
            Text(note).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(title)
    }
}
