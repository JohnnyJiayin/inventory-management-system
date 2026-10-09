import SwiftUI

/// 产品型号列表（Issue #16）与库存多条件查询（Issue #40）
///   只按名称 / 型号 / 条码搜索时在本地过滤；设置了其他条件时由数据库查询（search_models）。
struct ProductListView: View {
    @EnvironmentObject private var store: ProductStore
    @State private var query = ""
    @State private var filter = InventoryService.Filter()
    @State private var results: [ProductModel] = []
    @State private var searching = false
    @State private var searchError: String?
    @State private var showFilter = false
    @State private var showCreate = false

    private struct SearchKey: Equatable {
        let query: String
        let filter: InventoryService.Filter
        let models: [ProductModel]
    }

    var body: some View {
        let rows = filter.isEmpty ? store.filtered(query) : results
        let loading = filter.isEmpty ? store.isLoading : searching
        List {
            if let error = filter.isEmpty ? store.error : searchError {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if !filter.isEmpty {
                HStack {
                    Label("已设置 \(filter.activeCount) 个筛选条件，共 \(rows.count) 个型号", systemImage: "line.3.horizontal.decrease.circle")
                    Spacer()
                    Button("清除") { filter = InventoryService.Filter() }
                        .buttonStyle(.borderless)
                }
                .font(.subheadline)
            }
            ForEach(rows) { model in
                NavigationLink(value: model.id) {
                    ProductRow(model: model, showStats: true)
                }
            }
        }
        .overlay {
            if rows.isEmpty, !loading {
                Text(query.isEmpty && filter.isEmpty ? "还没有产品型号，点击右上角“添加产品”" : "没有匹配的产品")
                    .foregroundStyle(.secondary)
            }
        }
        // 型号列表刷新后（例如入库、出库后）也重新查询
        .task(id: SearchKey(query: query, filter: filter, models: store.models)) {
            guard !filter.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            searching = true
            defer { searching = false }
            do {
                results = try await InventoryService.search(query: query, filter: filter)
                searchError = nil
            } catch is CancellationError {
            } catch {
                searchError = AppError.message(error)
            }
        }
        .sheet(isPresented: $showFilter) {
            InventoryFilterSheet(filter: $filter)
        }
        .searchable(text: $query, prompt: "搜索名称、型号或条码")
        .navigationTitle("产品管理")
        .navigationDestination(for: UUID.self) { id in
            ProductDetailView(modelID: id)
        }
        .navigationDestination(for: OrderLink.self) { link in
            OrderView(orderID: link.id)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showFilter = true
                } label: {
                    Label(filter.isEmpty ? "筛选" : "筛选（\(filter.activeCount)）",
                          systemImage: filter.isEmpty ? "line.3.horizontal.decrease.circle"
                                                      : "line.3.horizontal.decrease.circle.fill")
                }
            }
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
    /// 库存列表显示累计入库 / 出库和最近入库 / 出库时间（需求 14）
    var showStats = false

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
                if showStats {
                    Text("累计入库 \(model.totalIn) · 累计出库 \(model.totalOut)"
                         + " · 最近入库 \(Self.day(model.lastInAt)) · 最近出库 \(Self.day(model.lastOutAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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

    private static func day(_ date: Date?) -> String {
        date?.formatted(date: .numeric, time: .omitted) ?? "—"
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
