import SwiftUI

/// 出库订单状态
enum OrderStatus: String, Decodable, CaseIterable {
    case draft
    case completed
    case cancelled

    var title: String {
        switch self {
        case .draft: "编辑中"
        case .completed: "已完成"
        case .cancelled: "已撤销"
        }
    }

    var color: Color {
        switch self {
        case .draft: .orange
        case .completed: .green
        case .cancelled: .gray
        }
    }
}

/// 订单列表与详情（视图 v_order_summary）。
/// 编辑中的订单显示经销商当前资料和实时金额；已完成 / 已撤销的订单显示确认时保存的快照。
struct OrderSummary: Decodable, Identifiable, Hashable {
    let id: UUID
    let orderNo: String
    let dealerId: UUID
    let addressId: UUID?
    let status: OrderStatus
    let dealerName: String
    let contactName: String
    let phone: String
    let addressText: String?
    let addressLabel: String?
    let itemCount: Int
    let productsAmount: Decimal
    /// nil 表示尚未填写运费
    let shippingFee: Decimal?
    let totalAmount: Decimal
    /// 存在实际单价不等于默认单价的明细（单台订单改价）
    let priceModified: Bool
    let shippedAt: Date?
    let cancelledAt: Date?
    let cancelReason: String?
    let note: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, status, phone, note
        case orderNo = "order_no"
        case dealerId = "dealer_id"
        case addressId = "address_id"
        case dealerName = "dealer_name"
        case contactName = "contact_name"
        case addressText = "address_text"
        case addressLabel = "address_label"
        case itemCount = "item_count"
        case productsAmount = "products_amount"
        case shippingFee = "shipping_fee"
        case totalAmount = "total_amount"
        case priceModified = "price_modified"
        case shippedAt = "shipped_at"
        case cancelledAt = "cancelled_at"
        case cancelReason = "cancel_reason"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        orderNo = try c.decode(String.self, forKey: .orderNo)
        dealerId = try c.decode(UUID.self, forKey: .dealerId)
        addressId = try c.decodeIfPresent(UUID.self, forKey: .addressId)
        status = try c.decode(OrderStatus.self, forKey: .status)
        dealerName = try c.decode(String.self, forKey: .dealerName)
        contactName = try c.decode(String.self, forKey: .contactName)
        phone = try c.decode(String.self, forKey: .phone)
        addressText = try c.decodeIfPresent(String.self, forKey: .addressText)
        addressLabel = try c.decodeIfPresent(String.self, forKey: .addressLabel)
        itemCount = try c.decode(Int.self, forKey: .itemCount)
        productsAmount = try c.decodeMoney(forKey: .productsAmount)
        shippingFee = try c.decodeMoneyIfPresent(forKey: .shippingFee)
        totalAmount = try c.decodeMoney(forKey: .totalAmount)
        priceModified = try c.decode(Bool.self, forKey: .priceModified)
        shippedAt = try c.decodeIfPresent(Date.self, forKey: .shippedAt)
        cancelledAt = try c.decodeIfPresent(Date.self, forKey: .cancelledAt)
        cancelReason = try c.decodeIfPresent(String.self, forKey: .cancelReason)
        note = try c.decodeIfPresent(String.self, forKey: .note)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

/// 出库订单明细（兼作保修记录）；model 来自嵌入查询 product_models(name,model)
struct OrderItem: Decodable, Identifiable, Hashable {
    struct ModelInfo: Decodable, Hashable {
        let name: String
        let model: String
        var displayName: String { "\(name) \(model)" }
    }

    let id: UUID
    let orderId: UUID
    let unitId: UUID
    let modelId: UUID
    let barcode: String
    let serialNo: String
    let defaultPrice: Decimal
    let actualPrice: Decimal
    /// 出库日期加一年（北京时间），格式 yyyy-MM-dd；确认出库前为 nil
    let warrantyEnd: String?
    let createdAt: Date
    let model: ModelInfo?

    var priceModified: Bool { actualPrice != defaultPrice }
    var modelName: String { model?.displayName ?? barcode }

    enum CodingKeys: String, CodingKey {
        case id, barcode
        case orderId = "order_id"
        case unitId = "unit_id"
        case modelId = "model_id"
        case serialNo = "serial_no"
        case defaultPrice = "default_price"
        case actualPrice = "actual_price"
        case warrantyEnd = "warranty_end"
        case createdAt = "created_at"
        case model = "product_models"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        orderId = try c.decode(UUID.self, forKey: .orderId)
        unitId = try c.decode(UUID.self, forKey: .unitId)
        modelId = try c.decode(UUID.self, forKey: .modelId)
        barcode = try c.decode(String.self, forKey: .barcode)
        serialNo = try c.decode(String.self, forKey: .serialNo)
        defaultPrice = try c.decodeMoney(forKey: .defaultPrice)
        actualPrice = try c.decodeMoney(forKey: .actualPrice)
        warrantyEnd = try c.decodeIfPresent(String.self, forKey: .warrantyEnd)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        model = try c.decodeIfPresent(ModelInfo.self, forKey: .model)
    }
}

/// 业务函数 confirm_order 的返回结果
struct ConfirmOrderResult: Decodable, Hashable {
    let orderNo: String
    let itemCount: Int
    let totalAmount: Decimal
    /// 同一请求编号重复提交时为 true（数据库直接返回上次结果，库存没有再次扣减）
    let duplicate: Bool?

    enum CodingKeys: String, CodingKey {
        case duplicate
        case orderNo = "order_no"
        case itemCount = "item_count"
        case totalAmount = "total_amount"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orderNo = try c.decode(String.self, forKey: .orderNo)
        itemCount = try c.decode(Int.self, forKey: .itemCount)
        totalAmount = try c.decodeMoney(forKey: .totalAmount)
        duplicate = try c.decodeIfPresent(Bool.self, forKey: .duplicate)
    }
}
