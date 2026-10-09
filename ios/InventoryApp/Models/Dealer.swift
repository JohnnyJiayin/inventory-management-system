import Foundation

/// 经销商（需求 6.3）；addresses 来自嵌入查询 dealer_addresses(*)
struct Dealer: Decodable, Identifiable, Hashable {
    let id: UUID
    var companyName: String
    var contactName: String
    var phone: String
    var active: Bool
    let createdAt: Date
    let updatedAt: Date
    var addresses: [DealerAddress]

    /// 有效地址，默认地址在前
    var activeAddresses: [DealerAddress] {
        addresses.filter(\.active).sorted { a, b in
            a.isDefault != b.isDefault ? a.isDefault : a.createdAt < b.createdAt
        }
    }

    var defaultAddress: DealerAddress? { activeAddresses.first }

    enum CodingKeys: String, CodingKey {
        case id, phone, active
        case companyName = "company_name"
        case contactName = "contact_name"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case addresses = "dealer_addresses"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        companyName = try c.decode(String.self, forKey: .companyName)
        contactName = try c.decode(String.self, forKey: .contactName)
        phone = try c.decode(String.self, forKey: .phone)
        active = try c.decode(Bool.self, forKey: .active)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        addresses = try c.decodeIfPresent([DealerAddress].self, forKey: .addresses) ?? []
    }
}

/// 经销商地址（需求 6.4）：每个经销商最多一个默认地址
struct DealerAddress: Decodable, Identifiable, Hashable {
    let id: UUID
    let dealerId: UUID
    var label: String?
    var address: String
    var isDefault: Bool
    var active: Bool
    let createdAt: Date

    /// “仓库：上海市…”
    var displayText: String {
        if let label, !label.isEmpty { return "\(label)：\(address)" }
        return address
    }

    enum CodingKeys: String, CodingKey {
        case id, label, address, active
        case dealerId = "dealer_id"
        case isDefault = "is_default"
        case createdAt = "created_at"
    }
}

/// 经销商产品价格（需求 6.5）；model 来自嵌入查询 product_models(…)
struct DealerPrice: Decodable, Identifiable, Hashable {
    struct ModelInfo: Decodable, Hashable {
        let name: String
        let model: String
        let barcode: String
        let active: Bool
        var displayName: String { "\(name) \(model)" }
    }

    let id: UUID
    let dealerId: UUID
    let modelId: UUID
    let price: Decimal
    let active: Bool
    let updatedAt: Date
    let model: ModelInfo?

    enum CodingKeys: String, CodingKey {
        case id, price, active
        case dealerId = "dealer_id"
        case modelId = "model_id"
        case updatedAt = "updated_at"
        case model = "product_models"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        dealerId = try c.decode(UUID.self, forKey: .dealerId)
        modelId = try c.decode(UUID.self, forKey: .modelId)
        price = try c.decodeMoney(forKey: .price)
        active = try c.decode(Bool.self, forKey: .active)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        model = try c.decodeIfPresent(ModelInfo.self, forKey: .model)
    }
}
