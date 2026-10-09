import Foundation
import Supabase

/// 出库扫码页状态（Issue #31 扫码、#32 运费、#33 单台改价、#34 确认出库）
///   扫产品条码 → 识别型号并显示默认单价 → 连续扫机身号加入清单；更换型号时扫新的产品条码。
///   订单内容保存在云端（每次扫码都直接写入编辑中的订单），关闭 App 或断网恢复后可以继续。
@MainActor
final class OrderEditorViewModel: ObservableObject {
    struct Message: Equatable {
        let text: String
        let isError: Bool
    }

    /// 单台订单已改价，再加入第 2 台前需要用户确认
    struct PendingAdd: Identifiable {
        let model: ProductModel
        let serialNo: String
        var id: String { "\(model.id)-\(serialNo)" }
    }

    let orderID: UUID

    @Published private(set) var order: OrderSummary?
    @Published private(set) var items: [OrderItem] = []
    @Published private(set) var addresses: [DealerAddress] = []
    @Published private(set) var model: ProductModel?
    /// 当前型号的经销商默认单价；nil 表示尚未设置
    @Published private(set) var modelPrice: Decimal?
    @Published var feeText = ""
    @Published var message: Message?
    @Published var pendingAdd: PendingAdd?
    @Published private(set) var busy = false
    @Published private(set) var submitting = false
    @Published private(set) var loadError: String?

    /// 点击确认时生成；网络失败重试时沿用同一个，订单内容变化后清空（防重复提交）
    private var requestID: UUID?
    /// 已保存到服务器的运费（与输入框比较，判断是否需要保存）
    private var savedFee: Decimal?
    /// 输入框失去焦点时开始的运费保存。点击“确认出库”也会让输入框失去焦点，确认前要等它完成
    private var feeSave: Task<Void, Never>?
    /// 订单已确认或已作废：之后不再保存运费（否则会对非编辑中的订单发起修改）
    private var closed = false

    init(orderID: UUID) {
        self.orderID = orderID
    }

    var step: ScanStep { model == nil ? .productBarcode : .serialNumber }
    /// 扫码处理或确认出库进行中：期间不能修改订单，避免异步结果写回到已变化的订单上
    var isWorking: Bool { busy || submitting }
    var fee: Decimal? { Money.parse(feeText) }
    var feeIsBlank: Bool { feeText.trimmingCharacters(in: .whitespaces).isEmpty }
    var productsAmount: Decimal { items.reduce(Decimal(0)) { $0 + $1.actualPrice } }
    var totalAmount: Decimal { productsAmount + (fee ?? 0) }
    /// 只有单台订单可以改实际单价（售后补发，可以为 0）
    var canEditPrice: Bool { items.count == 1 }

    var confirmBlocker: String? {
        if order?.addressId == nil { return "请选择收货地址" }
        if items.isEmpty { return "请扫描要出库的产品" }
        if feeIsBlank { return "请填写运费（没有运费填 0）" }
        if fee == nil { return "运费不能为负数，最多保留两位小数" }
        return nil
    }

    // MARK: - 加载

    func load() async {
        do {
            async let o = OrderService.fetchOrder(id: orderID)
            async let i = OrderService.fetchItems(orderID: orderID)
            let (fetched, fetchedItems) = try await (o, i)
            guard let fetched else {
                loadError = "订单不存在"
                return
            }
            order = fetched
            items = fetchedItems
            savedFee = fetched.shippingFee
            if feeIsBlank, let f = fetched.shippingFee { feeText = Money.plain(f) }
            addresses = (try await DealerService.fetchDealer(id: fetched.dealerId))?.activeAddresses ?? []
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = AppError.message(error)
        }
    }

    private func refresh() async {
        do {
            async let o = OrderService.fetchOrder(id: orderID)
            async let i = OrderService.fetchItems(orderID: orderID)
            let (fetched, fetchedItems) = try await (o, i)
            if let fetched { order = fetched }
            items = fetchedItems
        } catch {
            message = Message(text: "刷新订单失败：\(AppError.message(error))", isError: true)
        }
    }

    // MARK: - 扫码

    func handle(_ code: String) {
        guard !isWorking, pendingAdd == nil else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                if let model {
                    try await handleSerial(code, model: model)
                } else {
                    try await handleProductBarcode(code)
                }
            } catch {
                fail(AppError.message(error))
            }
        }
    }

    private func handleProductBarcode(_ code: String) async throws {
        guard let found = try await ProductService.fetchModel(barcode: code) else {
            return fail("未找到产品条码 \(code) 对应的型号，请先在“产品管理”中建档")
        }
        try await select(found)
    }

    private func select(_ found: ProductModel) async throws {
        guard found.active else {
            return fail("“\(found.displayName)”已停用，不能出库")
        }
        guard let order else { return }
        let price = try await DealerService.fetchPrice(dealerID: order.dealerId, modelID: found.id)
        model = found
        modelPrice = price
        if let price {
            ScanFeedback.success()
            message = Message(text: "已识别：\(found.displayName)，单价 \(Money.format(price))，请扫描机身号", isError: false)
        } else {
            fail("当前经销商尚未设置该型号的价格，请先填写单价")
        }
    }

    private func handleSerial(_ code: String, model: ProductModel) async throws {
        if code == model.barcode {
            return fail("这是产品条码，请扫描右侧机身号条码")
        }
        if items.contains(where: { $0.modelId == model.id && $0.serialNo == code }) {
            return fail("机身号 \(code) 已在本订单中")
        }
        guard modelPrice != nil else {
            return fail("当前经销商尚未设置该型号的价格，请先填写单价")
        }
        if items.count == 1, items[0].priceModified {
            ScanFeedback.warning()
            pendingAdd = PendingAdd(model: model, serialNo: code)
            return
        }
        try await add(model: model, serialNo: code, resetPrice: false)
    }

    /// 用户确认“多台订单不能改价，已改的价格将恢复为默认单价”后加入
    ///   弹窗出现时可能还有运费保存等操作在进行，等它完成后再加入，不能直接丢弃用户的确认
    func confirmPendingAdd(_ pending: PendingAdd) {
        pendingAdd = nil
        Task {
            await waitUntilIdle()
            busy = true
            defer { busy = false }
            do {
                try await add(model: pending.model, serialNo: pending.serialNo, resetPrice: true)
            } catch {
                fail(AppError.message(error))
            }
        }
    }

    private func add(model: ProductModel, serialNo: String, resetPrice: Bool) async throws {
        do {
            try await OrderService.addItem(orderID: orderID, modelID: model.id, serialNo: serialNo, resetPrice: resetPrice)
        } catch let error as PostgrestError {
            switch error.hint {
            case "UNIT_NOT_FOUND", "MODEL_MISMATCH":
                // 扫到的是另一个型号的产品条码：更换型号（需求 12.2：更换型号时重新扫描产品条码）
                if let other = try await ProductService.fetchModel(barcode: serialNo), other.id != model.id {
                    return try await select(other)
                }
                throw error
            case "PRICE_RESET_REQUIRED":
                ScanFeedback.warning()
                pendingAdd = PendingAdd(model: model, serialNo: serialNo)
                return
            default:
                throw error
            }
        }
        requestID = nil
        await refresh()
        ScanFeedback.success()
        message = Message(text: "已加入：\(model.displayName) 机身号 \(serialNo)", isError: false)
    }

    func changeModel() {
        guard !isWorking else { return }
        model = nil
        modelPrice = nil
        message = nil
    }

    /// 在扫码页直接设置单价后，重新读取当前型号的价格
    func reloadPrice() async {
        guard let model, let order else { return }
        do {
            modelPrice = try await DealerService.fetchPrice(dealerID: order.dealerId, modelID: model.id)
            if let modelPrice {
                message = Message(text: "已设置单价 \(Money.format(modelPrice))，请扫描机身号", isError: false)
            }
        } catch {
            fail(AppError.message(error))
        }
    }

    private func fail(_ text: String) {
        ScanFeedback.failure()
        message = Message(text: text, isError: true)
    }

    // MARK: - 清单、改价、地址、运费

    func remove(_ item: OrderItem) {
        mutate("已删除机身号 \(item.serialNo)，运费不变") {
            try await OrderService.removeItem(id: item.id)
        }
    }

    func setPrice(_ item: OrderItem, text: String) {
        guard let price = Money.parse(text) else {
            return fail("实际单价不能为负数，最多保留两位小数")
        }
        mutate("实际单价已改为 \(Money.format(price))（只影响本订单）") {
            try await OrderService.setItemPrice(itemID: item.id, price: price)
        }
    }

    func changeAddress(_ address: DealerAddress) {
        guard let order else { return }
        mutate("收货地址已改为 \(address.displayText)") {
            try await OrderService.updateOrder(id: order.id, addressID: address.id,
                                               shippingFee: self.savedFee, note: order.note)
        }
    }

    /// 输入框失去焦点时保存运费（留空保存为“未填写”）；格式不对时不保存，确认按钮不可点
    func saveFee() {
        guard !closed, !isWorking, feeNeedsSaving else { return }
        busy = true
        feeSave = Task {
            defer { busy = false }
            do {
                try await saveFeeIfNeeded()
            } catch {
                fail(AppError.message(error))
            }
        }
    }

    /// 离开页面时保存运费：有操作进行中时等它完成再保存；订单已确认或作废则不保存
    func saveFeeOnLeave() {
        guard !closed, feeNeedsSaving else { return }
        Task {
            await waitUntilIdle()
            guard !closed, feeNeedsSaving else { return }
            busy = true
            defer { busy = false }
            try? await saveFeeIfNeeded()
        }
    }

    /// 等待进行中的扫码、保存或确认完成（都在主线程上，返回后立即设置 busy 不会被其他操作抢先）
    private func waitUntilIdle() async {
        while isWorking {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private var feeNeedsSaving: Bool {
        guard order != nil else { return false }
        if feeIsBlank { return savedFee != nil }
        guard let fee else { return false }
        return fee != savedFee
    }

    private func saveFeeIfNeeded() async throws {
        guard feeNeedsSaving, let order else { return }
        let newFee = feeIsBlank ? nil : fee
        try await OrderService.updateOrder(id: order.id, addressID: order.addressId, shippingFee: newFee, note: order.note)
        savedFee = newFee
        requestID = nil
        await refresh()
    }

    private func mutate(_ success: String, _ action: @escaping () async throws -> Void) {
        guard !isWorking else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await action()
                requestID = nil
                await refresh()
                message = Message(text: success, isError: false)
            } catch {
                fail(AppError.message(error))
                await refresh()
            }
        }
    }

    // MARK: - 确认出库 / 作废

    /// 返回确认结果；订单已完成但没有拿到结果（例如超时后发现已完成）时返回 nil 并标记 completed
    func confirm(online: Bool) async -> (completed: Bool, result: ConfirmOrderResult?) {
        guard online else {
            fail("网络未连接，不能确认出库")
            return (false, nil)
        }
        await feeSave?.value
        guard confirmBlocker == nil, !isWorking else { return (false, nil) }
        submitting = true
        defer { submitting = false }
        do {
            try await saveFeeIfNeeded()
            let id = requestID ?? UUID()
            requestID = id
            let result = try await OrderService.confirm(orderID: orderID, requestID: id)
            closed = true
            ScanFeedback.success()
            return (true, result)
        } catch {
            if AppError.isBusiness(error) {
                // 业务错误（例如某台产品已出库）整张订单都没有出库，修改后用新的请求编号
                requestID = nil
                fail(AppError.message(error))
                await refresh()
                return (false, nil)
            }
            // 网络错误：无法确定服务器是否已执行。保留请求编号，重试不会重复扣库存
            if let latest = try? await OrderService.fetchOrder(id: orderID), latest.status == .completed {
                closed = true
                return (true, nil)
            }
            fail("\(AppError.message(error))。请检查网络后再次点击确认，重试不会重复出库")
            return (false, nil)
        }
    }

    /// 作废编辑中的订单（没有扣过库存）
    func discard(reason: String) async -> Bool {
        // 弹出作废窗口会让运费输入框失去焦点并开始保存，等保存完成再作废
        await waitUntilIdle()
        submitting = true
        defer { submitting = false }
        do {
            try await OrderService.cancel(orderID: orderID, reason: reason, requestID: UUID())
            closed = true
            return true
        } catch {
            fail(AppError.message(error))
            return false
        }
    }
}
