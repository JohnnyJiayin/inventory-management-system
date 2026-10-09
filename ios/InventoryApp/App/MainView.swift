import SwiftUI

/// 侧边栏导航（需求 16）。横屏时侧边栏常驻，竖屏时可收起。
struct MainView: View {
    enum Section: String, CaseIterable, Identifiable, Hashable {
        case home, products, stockIn, outbound, dealers, reports, settings
        var id: Self { self }

        var title: String {
            switch self {
            case .home: "首页"
            case .products: "产品管理"
            case .stockIn: "入库"
            case .outbound: "出库订单"
            case .dealers: "经销商"
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
            case .reports: "chart.bar"
            case .settings: "gearshape"
            }
        }
    }

    @State private var selection: Section? = .home
    @StateObject private var products = ProductStore()
    @StateObject private var stockIn = StockInViewModel()

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
                case .home: HomeView()
                case .products: ProductListView()
                case .stockIn: StockInView(vm: stockIn)
                case .outbound: OutboundPlaceholderView()
                case .dealers: DealersPlaceholderView()
                case .reports: ReportsPlaceholderView()
                case .settings: SettingsView()
                }
            }
            // 切换页面时重建导航栈，避免停留在上一个页面的详情页
            .id(selection)
        }
        .environmentObject(products)
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
