import Foundation

/// 入库类型
enum StockInType: String, Codable {
    case first
    case restock

    var title: String {
        switch self {
        case .first: "首次入库"
        case .restock: "重新入库"
        }
    }
}

/// 业务函数 stock_in 的返回结果
struct StockInResult: Decodable, Hashable {
    struct Item: Decodable, Hashable {
        let unitId: UUID
        let serialNo: String
        let inType: StockInType

        enum CodingKeys: String, CodingKey {
            case unitId = "unit_id"
            case serialNo = "serial_no"
            case inType = "in_type"
        }
    }

    let recordNo: String
    let modelId: UUID
    let count: Int
    let firstCount: Int
    let restockCount: Int
    let items: [Item]
    /// 同一请求编号重复提交时为 true（数据库直接返回上次结果，库存没有再次增加）
    let duplicate: Bool?

    enum CodingKeys: String, CodingKey {
        case recordNo = "record_no"
        case modelId = "model_id"
        case count, items, duplicate
        case firstCount = "first_count"
        case restockCount = "restock_count"
    }
}

/// 业务函数 create_model 的返回结果
struct CreateModelResult: Decodable {
    let modelId: UUID
    let stockIn: StockInResult?

    enum CodingKeys: String, CodingKey {
        case modelId = "model_id"
        case stockIn = "stock_in"
    }
}
