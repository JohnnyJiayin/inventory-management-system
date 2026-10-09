import Foundation

/// 入库记录（表 stock_in_records）：每台每次入库一条
struct StockInRecord: Decodable, Identifiable, Hashable {
    let id: UUID
    let recordNo: String
    let unitId: UUID
    let serialNo: String
    let inType: StockInType
    let inAt: Date
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id, note
        case recordNo = "record_no"
        case unitId = "unit_id"
        case serialNo = "serial_no"
        case inType = "in_type"
        case inAt = "in_at"
    }
}

/// 出库记录（视图 v_report_items）：每台每次出库一条，含已撤销订单
struct OutboundRecord: Decodable, Identifiable, Hashable {
    let itemId: UUID
    let orderId: UUID
    let orderNo: String
    let orderStatus: OrderStatus
    let dealerName: String
    let serialNo: String
    let actualPrice: Decimal
    let shippedAt: Date?

    var id: UUID { itemId }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case orderId = "order_id"
        case orderNo = "order_no"
        case orderStatus = "order_status"
        case dealerName = "dealer_name"
        case serialNo = "serial_no"
        case actualPrice = "actual_price"
        case shippedAt = "shipped_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        itemId = try c.decode(UUID.self, forKey: .itemId)
        orderId = try c.decode(UUID.self, forKey: .orderId)
        orderNo = try c.decode(String.self, forKey: .orderNo)
        orderStatus = try c.decode(OrderStatus.self, forKey: .orderStatus)
        dealerName = try c.decode(String.self, forKey: .dealerName)
        serialNo = try c.decode(String.self, forKey: .serialNo)
        actualPrice = try c.decodeMoney(forKey: .actualPrice)
        shippedAt = try c.decodeIfPresent(Date.self, forKey: .shippedAt)
    }
}
