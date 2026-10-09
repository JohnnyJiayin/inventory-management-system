import Foundation

/// 产品型号列表（各页面共享）。修改后调用 reload()，列表和库存数量立即更新。
@MainActor
final class ProductStore: ObservableObject {
    @Published private(set) var models: [ProductModel] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            models = try await ProductService.fetchModels()
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = AppError.message(error)
        }
    }

    func model(id: UUID) -> ProductModel? {
        models.first { $0.id == id }
    }

    /// 按名称、型号、条码搜索（本地过滤，型号数量有限）
    func filtered(_ query: String) -> [ProductModel] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return models }
        return models.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.model.localizedCaseInsensitiveContains(q)
                || $0.barcode.localizedCaseInsensitiveContains(q)
        }
    }
}
