import Foundation

/// 单台产品
struct ProductUnit: Decodable, Identifiable, Hashable {
    enum Status: String, Decodable {
        case inStock = "in_stock"
        case shipped

        var title: String {
            switch self {
            case .inStock: "在库"
            case .shipped: "已出库"
            }
        }
    }

    let id: UUID
    let modelId: UUID
    let serialNo: String
    let status: Status
    let lastInAt: Date?
    let lastOutAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, status
        case modelId = "model_id"
        case serialNo = "serial_no"
        case lastInAt = "last_in_at"
        case lastOutAt = "last_out_at"
    }
}
