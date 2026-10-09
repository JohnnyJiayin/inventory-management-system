import SwiftUI

/// 保修状态（数据库按北京时间的“今天”计算，截止日当天仍算保修中）
enum WarrantyStatus: String, Decodable {
    case inWarranty = "in_warranty"
    case expired
    /// 订单已撤销，本次保修失效
    case void

    var title: String {
        switch self {
        case .inWarranty: "保修中"
        case .expired: "已过保"
        case .void: "已失效"
        }
    }

    var color: Color {
        switch self {
        case .inWarranty: .green
        case .expired: .red
        case .void: .gray
        }
    }
}

/// 保修记录（视图 v_warranty）：每次出库一条，历次记录都保留
struct WarrantyRecord: Decodable, Identifiable, Hashable {
    let itemId: UUID
    let unitId: UUID
    let modelName: String
    let model: String
    let barcode: String
    let serialNo: String
    let orderId: UUID
    let orderNo: String
    let dealerName: String?
    let shippedAt: Date?
    /// yyyy-MM-dd（北京时间）
    let warrantyEnd: String
    let warrantyStatus: WarrantyStatus
    let expiringSoon: Bool
    let daysLeft: Int?
    /// 当前保修 = 该产品最近一次未撤销的出库
    let isCurrent: Bool

    var id: UUID { itemId }
    var displayName: String { "\(modelName) \(model)" }

    enum CodingKeys: String, CodingKey {
        case model, barcode
        case itemId = "item_id"
        case unitId = "unit_id"
        case modelName = "model_name"
        case serialNo = "serial_no"
        case orderId = "order_id"
        case orderNo = "order_no"
        case dealerName = "dealer_name"
        case shippedAt = "shipped_at"
        case warrantyEnd = "warranty_end"
        case warrantyStatus = "warranty_status"
        case expiringSoon = "expiring_soon"
        case daysLeft = "days_left"
        case isCurrent = "is_current"
    }
}
