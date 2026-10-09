import Foundation
import Supabase

/// 经销商、地址、价格（Issue #23）。读取直接查询表（RLS 只读）；写操作调用业务函数。
enum DealerService {
    private static let dealerColumns = "*,dealer_addresses(*)"

    static func fetchDealers() async throws -> [Dealer] {
        try await supabase.from("dealers")
            .select(dealerColumns)
            .order("active", ascending: false)
            .order("company_name")
            .execute()
            .value
    }

    static func fetchDealer(id: UUID) async throws -> Dealer? {
        let rows: [Dealer] = try await supabase.from("dealers")
            .select(dealerColumns)
            .eq("id", value: id)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// 经销商的有效价格表
    static func fetchPrices(dealerID: UUID) async throws -> [DealerPrice] {
        let rows: [DealerPrice] = try await supabase.from("dealer_prices")
            .select("*,product_models(name,model,barcode,active)")
            .eq("dealer_id", value: dealerID)
            .eq("active", value: true)
            .execute()
            .value
        return rows.sorted { ($0.model?.displayName ?? "") < ($1.model?.displayName ?? "") }
    }

    /// 某经销商某型号的默认单价；未设置返回 nil
    static func fetchPrice(dealerID: UUID, modelID: UUID) async throws -> Decimal? {
        let rows: [DealerPrice] = try await supabase.from("dealer_prices")
            .select()
            .eq("dealer_id", value: dealerID)
            .eq("model_id", value: modelID)
            .eq("active", value: true)
            .limit(1)
            .execute()
            .value
        return rows.first?.price
    }

    // MARK: - 业务函数

    struct NewAddress: Encodable, Hashable {
        var label: String
        var address: String
        var isDefault: Bool

        enum CodingKeys: String, CodingKey {
            case label, address
            case isDefault = "is_default"
        }
    }

    struct CreateParams: Encodable, Equatable {
        var companyName: String
        var contactName: String
        var phone: String
        var addresses: [NewAddress]
        var requestID: UUID

        enum CodingKeys: String, CodingKey {
            case companyName = "p_company_name"
            case contactName = "p_contact_name"
            case phone = "p_phone"
            case addresses = "p_addresses"
            case requestID = "p_request_id"
        }
    }

    /// 新增经销商（至少一个地址），返回经销商 ID
    static func createDealer(_ params: CreateParams) async throws -> UUID {
        struct R: Decodable { let dealer_id: UUID }
        let r: R = try await supabase.rpc("create_dealer", params: params).execute().value
        return r.dealer_id
    }

    static func updateDealer(id: UUID, companyName: String, contactName: String, phone: String, active: Bool) async throws {
        struct P: Encodable {
            let p_dealer_id: UUID
            let p_company_name: String
            let p_contact_name: String
            let p_phone: String
            let p_active: Bool
        }
        try await supabase.rpc("update_dealer", params: P(
            p_dealer_id: id, p_company_name: companyName, p_contact_name: contactName,
            p_phone: phone, p_active: active
        )).execute()
    }

    static func setActive(dealerID: UUID, active: Bool) async throws {
        struct P: Encodable { let p_dealer_id: UUID; let p_active: Bool }
        try await supabase.rpc("set_dealer_active", params: P(p_dealer_id: dealerID, p_active: active)).execute()
    }

    static func addAddress(dealerID: UUID, label: String, address: String, isDefault: Bool) async throws {
        struct P: Encodable {
            let p_dealer_id: UUID
            let p_label: String
            let p_address: String
            let p_is_default: Bool
        }
        try await supabase.rpc("add_dealer_address", params: P(
            p_dealer_id: dealerID, p_label: label, p_address: address, p_is_default: isDefault
        )).execute()
    }

    static func updateAddress(id: UUID, label: String, address: String, active: Bool) async throws {
        struct P: Encodable {
            let p_address_id: UUID
            let p_label: String
            let p_address: String
            let p_active: Bool
        }
        try await supabase.rpc("update_dealer_address", params: P(
            p_address_id: id, p_label: label, p_address: address, p_active: active
        )).execute()
    }

    /// 设为默认地址（数据库自动取消原默认地址）
    static func setDefaultAddress(id: UUID) async throws {
        struct P: Encodable { let p_address_id: UUID }
        try await supabase.rpc("set_default_address", params: P(p_address_id: id)).execute()
    }

    /// 设置默认单价：已有有效价格时修改，否则新增
    static func setPrice(dealerID: UUID, modelID: UUID, price: Decimal) async throws {
        struct P: Encodable { let p_dealer_id: UUID; let p_model_id: UUID; let p_price: String }
        try await supabase.rpc("set_dealer_price", params: P(
            p_dealer_id: dealerID, p_model_id: modelID, p_price: Money.param(price)
        )).execute()
    }

    static func deactivatePrice(id: UUID) async throws {
        struct P: Encodable { let p_price_id: UUID }
        try await supabase.rpc("deactivate_dealer_price", params: P(p_price_id: id)).execute()
    }
}
