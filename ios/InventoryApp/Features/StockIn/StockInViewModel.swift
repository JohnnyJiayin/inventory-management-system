import Foundation

/// 入库页面状态（Issue #20 首次入库、#21 重新入库）
@MainActor
final class StockInViewModel: ObservableObject {
    struct Item: Identifiable, Hashable {
        let serialNo: String
        let type: StockInType
        var id: String { serialNo }
    }

    struct Message: Equatable {
        let text: String
        let isError: Bool
    }

    struct PendingRestock: Identifiable {
        let unit: ProductUnit
        var id: UUID { unit.id }
    }

    @Published private(set) var model: ProductModel?
    @Published var plannedQty: Int = 1 { didSet { requestID = nil } }
    @Published private(set) var items: [Item] = [] { didSet { requestID = nil } }
    @Published var message: Message?
    @Published var unknownBarcode: String?
    @Published var pendingRestock: PendingRestock?
    @Published private(set) var busy = false
    @Published private(set) var submitting = false
    @Published private(set) var lastResult: StockInResult?

    /// 点击确认时生成；网络失败重试时沿用同一个，内容变化后清空（防重复提交）
    private var requestID: UUID?

    var step: ScanStep { model == nil ? .productBarcode : .serialNumber }
    var remaining: Int { max(plannedQty - items.count, 0) }

    var confirmBlocker: String? {
        if model == nil { return "请先扫描产品条码" }
        if plannedQty <= 0 { return "计划入库数量必须大于 0" }
        if items.isEmpty { return "请扫描机身号" }
        if items.count != plannedQty { return "已扫描 \(items.count) 台，与计划入库数量 \(plannedQty) 不一致" }
        return nil
    }

    // MARK: - 扫码

    func handle(_ code: String) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                if model == nil {
                    try await handleProductBarcode(code)
                } else {
                    try await handleSerial(code)
                }
            } catch {
                fail(AppError.message(error))
            }
        }
    }

    private func handleProductBarcode(_ code: String) async throws {
        guard let found = try await ProductService.fetchModel(barcode: code) else {
            ScanFeedback.warning()
            message = Message(text: "未找到对应产品型号，请创建产品或绑定已有型号。", isError: true)
            unknownBarcode = code
            return
        }
        select(found)
    }

    /// 选择型号（扫码识别，或未知条码创建 / 绑定后回到这里继续）
    func select(_ found: ProductModel) {
        guard found.active else {
            fail("“\(found.displayName)”已停用，不能入库")
            return
        }
        model = found
        items = []
        lastResult = nil
        ScanFeedback.success()
        message = Message(text: "已识别：\(found.displayName)，当前库存 \(found.stockQty)", isError: false)
    }

    private func handleSerial(_ code: String) async throws {
        guard let model else { return }
        if code == model.barcode {
            return fail("这是产品条码，请扫描右侧机身号条码")
        }
        if items.contains(where: { $0.serialNo == code }) {
            return fail("机身号 \(code) 已在清单中")
        }
        if items.count >= plannedQty {
            return fail("已达到计划入库数量 \(plannedQty)，如需多入库请先修改计划数量")
        }
        async let unitLookup = ProductService.fetchUnit(modelID: model.id, serialNo: code)
        async let barcodeLookup = ProductService.fetchModel(barcode: code)
        let (unit, otherModel) = try await (unitLookup, barcodeLookup)

        if unit == nil, let otherModel {
            return fail("这是“\(otherModel.displayName)”的产品条码，请扫描右侧机身号条码")
        }
        switch unit?.status {
        case nil:
            add(Item(serialNo: code, type: .first))
        case .inStock:
            fail("机身号 \(code) 已在库，不能重复入库")
        case .shipped:
            ScanFeedback.warning()
            pendingRestock = PendingRestock(unit: unit!)
        }
    }

    func confirmRestock(_ pending: PendingRestock) {
        pendingRestock = nil
        guard items.count < plannedQty else {
            return fail("已达到计划入库数量 \(plannedQty)")
        }
        add(Item(serialNo: pending.unit.serialNo, type: .restock))
    }

    private func add(_ item: Item) {
        items.append(item)
        ScanFeedback.success()
        message = Message(text: "已加入：\(item.serialNo)（\(item.type.title)）", isError: false)
    }

    private func fail(_ text: String) {
        ScanFeedback.failure()
        message = Message(text: text, isError: true)
    }

    // MARK: - 清单

    func remove(_ item: Item) {
        items.removeAll { $0 == item }
    }

    func changeModel() {
        model = nil
        items = []
        message = nil
        lastResult = nil
    }

    // MARK: - 确认入库

    func confirm(online: Bool) async {
        guard online else { return fail("网络未连接，不能入库") }
        guard confirmBlocker == nil, let model, !submitting else { return }
        submitting = true
        defer { submitting = false }
        let id = requestID ?? UUID()
        requestID = id
        do {
            let result = try await StockInService.stockIn(
                modelID: model.id,
                serialNos: items.map(\.serialNo),
                plannedQty: plannedQty,
                requestID: id
            )
            lastResult = result
            ScanFeedback.success()
            message = Message(
                text: "入库成功：\(result.recordNo)，共 \(result.count) 台（首次入库 \(result.firstCount)，重新入库 \(result.restockCount)）",
                isError: false)
            items = []
            requestID = nil
            if let refreshed = try? await ProductService.fetchModel(id: model.id) {
                self.model = refreshed
            }
        } catch {
            // 网络错误时保留请求编号，重试不会重复入库；业务错误（例如机身号已在库）整批都没有入库
            if !AppError.isNetwork(error) { requestID = nil }
            fail(AppError.message(error))
        }
    }
}
