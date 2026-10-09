import Foundation

/// 产品型号（来自视图 v_model_stock，含实时库存统计）
struct ProductModel: Decodable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var model: String
    var barcode: String
    var photoPath: String?
    var description: String?
    var active: Bool
    let createdAt: Date
    let updatedAt: Date
    /// 当前库存 = 在库单台产品数量（不能直接修改）
    let stockQty: Int
    let totalIn: Int
    let totalOut: Int
    let lastInAt: Date?
    let lastOutAt: Date?
    /// 已有出入库记录：只能停用，不能删除
    let hasRecords: Bool

    var displayName: String { "\(name) \(model)" }

    enum CodingKeys: String, CodingKey {
        case id, name, model, barcode, description, active
        case photoPath = "photo_path"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case stockQty = "stock_qty"
        case totalIn = "total_in"
        case totalOut = "total_out"
        case lastInAt = "last_in_at"
        case lastOutAt = "last_out_at"
        case hasRecords = "has_records"
    }
}
