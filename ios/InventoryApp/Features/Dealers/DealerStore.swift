import Foundation

/// 经销商列表（经销商页面和新建出库订单共享）。修改后调用 reload()。
@MainActor
final class DealerStore: ObservableObject {
    @Published private(set) var dealers: [Dealer] = []
    @Published private(set) var isLoading = false
    @Published var error: String?

    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            dealers = try await DealerService.fetchDealers()
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = AppError.message(error)
        }
    }

    func dealer(id: UUID) -> Dealer? {
        dealers.first { $0.id == id }
    }

    /// 按公司名称、联系人、电话搜索（本地过滤）
    func filtered(_ query: String, activeOnly: Bool = false) -> [Dealer] {
        let q = query.trimmingCharacters(in: .whitespaces)
        return dealers.filter { d in
            (!activeOnly || d.active) && (q.isEmpty
                || d.companyName.localizedCaseInsensitiveContains(q)
                || d.contactName.localizedCaseInsensitiveContains(q)
                || d.phone.contains(q))
        }
    }

    // MARK: - 最近一次选择的经销商（新建出库订单时默认显示）

    private static let lastDealerKey = "lastDealerID"

    var lastSelectedID: UUID? {
        get { UserDefaults.standard.string(forKey: Self.lastDealerKey).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Self.lastDealerKey) }
    }
}
