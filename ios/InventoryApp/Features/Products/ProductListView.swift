import SwiftUI

/// 产品型号列表（Issue #16）
struct ProductListView: View {
    @EnvironmentObject private var store: ProductStore
    @State private var query = ""
    @State private var showCreate = false

    var body: some View {
        let rows = store.filtered(query)
        List {
            if let error = store.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            ForEach(rows) { model in
                NavigationLink(value: model.id) {
                    ProductRow(model: model)
                }
            }
        }
        .overlay {
            if rows.isEmpty, !store.isLoading {
                Text(query.isEmpty ? "还没有产品型号，点击右上角“添加产品”" : "没有匹配的产品")
                    .foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, prompt: "搜索名称、型号或条码")
        .navigationTitle("产品管理")
        .navigationDestination(for: UUID.self) { id in
            ProductDetailView(modelID: id)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showCreate = true
                } label: {
                    Label("添加产品", systemImage: "plus")
                }
                .requiresOnline()
            }
        }
        .sheet(isPresented: $showCreate) {
            ProductFormView(mode: .create(barcode: nil)) { _ in
                Task { await store.reload() }
            }
        }
        .refreshable { await store.reload() }
        .task { await store.reload() }
    }
}

struct ProductRow: View {
    let model: ProductModel

    var body: some View {
        HStack(spacing: 14) {
            ProductPhotoView(path: model.photoPath, size: 56)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.name).font(.headline)
                    Text(model.model).foregroundStyle(.secondary)
                    if !model.active { StatusBadge(text: "已停用", color: .gray) }
                }
                Label(model.barcode, systemImage: "barcode")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(model.stockQty)").font(.title2.bold().monospacedDigit())
                Text("当前库存").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .opacity(model.active ? 1 : 0.6)
    }
}

struct StatusBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
