import SwiftUI

/// 经销商列表（Issue #24）：公司名称、联系人、电话、状态，支持搜索
struct DealerListView: View {
    @EnvironmentObject private var store: DealerStore
    @State private var query = ""
    @State private var showCreate = false

    var body: some View {
        let rows = store.filtered(query)
        List {
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            ForEach(rows) { dealer in
                NavigationLink(value: DealerLink(id: dealer.id)) {
                    DealerRow(dealer: dealer)
                }
            }
        }
        .overlay {
            if rows.isEmpty, !store.isLoading {
                Text(query.isEmpty ? "还没有经销商，点击右上角“添加经销商”" : "没有匹配的经销商")
                    .foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, prompt: "搜索公司名称、联系人或电话")
        .navigationTitle("经销商")
        .navigationDestination(for: DealerLink.self) { link in
            DealerDetailView(dealerID: link.id)
        }
        .navigationDestination(for: OrderLink.self) { link in
            OrderView(orderID: link.id)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreate = true
                } label: {
                    Label("添加经销商", systemImage: "plus")
                }
                .requiresOnline()
            }
        }
        .sheet(isPresented: $showCreate) {
            DealerFormView(dealer: nil) {
                Task { await store.reload() }
            }
        }
        .refreshable { await store.reload() }
        .task { await store.reload() }
    }
}

struct DealerRow: View {
    let dealer: Dealer

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "building.2.crop.circle")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(dealer.companyName).font(.headline)
                    if !dealer.active { StatusBadge(text: "已停用", color: .gray) }
                }
                Text("\(dealer.contactName)  \(dealer.phone)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let address = dealer.defaultAddress {
                    Text(address.displayText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .opacity(dealer.active ? 1 : 0.6)
    }
}
