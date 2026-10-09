import Foundation
import Supabase

/// 出库订单（Issue #27–#29）。读取查询视图 v_order_summary 和明细表；写操作调用业务函数。
enum OrderService {
    struct Filter: Equatable {
        var status: OrderStatus?
        var dealerID: UUID?
        /// 按单号或经销商名称搜索
        var query = ""
    }

    static func fetchOrders(_ filter: Filter, limit: Int = 300) async throws -> [OrderSummary] {
        var query = supabase.from("v_order_summary").select()
        if let status = filter.status {
            query = query.eq("status", value: status.rawValue)
        }
        if let dealerID = filter.dealerID {
            query = query.eq("dealer_id", value: dealerID)
        }
        let q = PostgrestPattern.sanitize(filter.query)
        if !q.isEmpty {
            query = query.or("order_no.ilike.*\(q)*,dealer_name.ilike.*\(q)*")
        }
        return try await query
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    static func fetchOrder(id: UUID) async throws -> OrderSummary? {
        let rows: [OrderSummary] = try await supabase.from("v_order_summary")
            .select()
            .eq("id", value: id)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    static func fetchItems(orderID: UUID) async throws -> [OrderItem] {
        try await supabase.from("outbound_items")
            .select("*,product_models(name,model)")
            .eq("order_id", value: orderID)
            .order("created_at")
            .execute()
            .value
    }

    // MARK: - 业务函数

    struct Created: Decodable {
        let orderId: UUID
        let orderNo: String

        enum CodingKeys: String, CodingKey {
            case orderId = "order_id"
            case orderNo = "order_no"
        }
    }

    /// 新建“编辑中”的订单。requestID 防止连点生成两张订单。
    static func createOrder(dealerID: UUID, addressID: UUID?, requestID: UUID) async throws -> Created {
        struct P: Encodable { let p_dealer_id: UUID; let p_address_id: UUID?; let p_request_id: UUID }
        return try await supabase.rpc("create_order", params: P(
            p_dealer_id: dealerID, p_address_id: addressID, p_request_id: requestID
        )).execute().value
    }

    /// 加入一台产品。resetPrice：单台订单已改价时加入第 2 台，需用户确认后传 true（已改价格恢复为默认单价）
    static func addItem(orderID: UUID, modelID: UUID, serialNo: String, resetPrice: Bool) async throws {
        struct P: Encodable {
            let p_order_id: UUID
            let p_model_id: UUID
            let p_serial_no: String
            let p_reset_price: Bool
        }
        try await supabase.rpc("add_order_item", params: P(
            p_order_id: orderID, p_model_id: modelID, p_serial_no: serialNo, p_reset_price: resetPrice
        )).execute()
    }

    static func removeItem(id: UUID) async throws {
        struct P: Encodable { let p_item_id: UUID }
        try await supabase.rpc("remove_order_item", params: P(p_item_id: id)).execute()
    }

    /// 修改收货地址、运费（nil = 尚未填写）、备注
    static func updateOrder(id: UUID, addressID: UUID?, shippingFee: Decimal?, note: String?) async throws {
        struct P: Encodable {
            let p_order_id: UUID
            let p_address_id: UUID?
            let p_shipping_fee: String?
            let p_note: String?

            func encode(to encoder: Encoder) throws {
                // nil 也要显式传 null（运费清空），否则 PostgREST 找不到四个参数的函数
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_order_id, forKey: .p_order_id)
                try c.encode(p_address_id, forKey: .p_address_id)
                try c.encode(p_shipping_fee, forKey: .p_shipping_fee)
                try c.encode(p_note, forKey: .p_note)
            }

            enum CodingKeys: String, CodingKey { case p_order_id, p_address_id, p_shipping_fee, p_note }
        }
        try await supabase.rpc("update_order", params: P(
            p_order_id: id, p_address_id: addressID, p_shipping_fee: shippingFee.map(Money.param), p_note: note
        )).execute()
    }

    /// 修改实际单价（只有单台订单可以改，可以为 0）
    static func setItemPrice(itemID: UUID, price: Decimal) async throws {
        struct P: Encodable { let p_item_id: UUID; let p_actual_price: String }
        try await supabase.rpc("set_order_item_price", params: P(
            p_item_id: itemID, p_actual_price: Money.param(price)
        )).execute()
    }

    /// 确认出库。requestID 在点击确认时生成，重试时必须使用同一个，数据库据此保证库存只扣一次。
    static func confirm(orderID: UUID, requestID: UUID) async throws -> ConfirmOrderResult {
        struct P: Encodable { let p_order_id: UUID; let p_request_id: UUID }
        return try await supabase.rpc("confirm_order", params: P(
            p_order_id: orderID, p_request_id: requestID
        )).execute().value
    }

    /// 撤销已完成的订单（产品恢复在库），或作废编辑中的订单
    static func cancel(orderID: UUID, reason: String, requestID: UUID) async throws {
        struct P: Encodable { let p_order_id: UUID; let p_reason: String; let p_request_id: UUID }
        try await supabase.rpc("cancel_order", params: P(
            p_order_id: orderID, p_reason: reason, p_request_id: requestID
        )).execute()
    }
}

/// PostgREST or=(…) / ilike 过滤中的搜索词：去掉会破坏过滤语法的字符，
/// 并转义 `_`（ILIKE 中匹配任意单个字符，否则搜 A_1 会匹配到 AB1）
enum PostgrestPattern {
    static func sanitize(_ text: String) -> String {
        let banned = CharacterSet(charactersIn: ",()*%\\:\"")
        let kept = String(text.trimmingCharacters(in: .whitespaces).unicodeScalars.filter { !banned.contains($0) })
        return kept.replacingOccurrences(of: "_", with: "\\_")
    }
}
