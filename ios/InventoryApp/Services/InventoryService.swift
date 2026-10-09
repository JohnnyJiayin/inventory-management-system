import Foundation
import Supabase

/// 库存查询（Issue #40）与产品详情的出入库记录（Issue #41）
enum InventoryService {
    enum UnitStatusFilter: String, CaseIterable, Identifiable {
        case inStock = "in_stock"
        case shipped
        var id: Self { self }

        var title: String {
            switch self {
            case .inStock: "有在库产品"
            case .shipped: "有已出库产品"
            }
        }
    }

    enum WarrantyFilter: String, CaseIterable, Identifiable {
        case inWarranty = "in_warranty"
        case expiring
        case expired
        var id: Self { self }

        var title: String {
            switch self {
            case .inWarranty: "保修中"
            case .expiring: "即将过保"
            case .expired: "已过保"
            }
        }
    }

    /// 多条件查询：名称 / 型号 / 条码之外的条件都针对同一台产品判断（见 search_models）
    struct Filter: Equatable {
        var serialNo = ""
        var unitStatus: UnitStatusFilter?
        var inFrom: Date?
        var inTo: Date?
        var dealerID: UUID?
        var outFrom: Date?
        var outTo: Date?
        var warranty: WarrantyFilter?

        /// 已设置的条件数量（工具栏按钮上显示）
        var activeCount: Int {
            [
                !serialNo.trimmingCharacters(in: .whitespaces).isEmpty,
                unitStatus != nil,
                inFrom != nil,
                dealerID != nil,
                outFrom != nil,
                warranty != nil,
            ].filter { $0 }.count
        }

        var isEmpty: Bool { activeCount == 0 }
    }

    static func search(query: String, filter: Filter) async throws -> [ProductModel] {
        struct P: Encodable {
            let p_query: String?
            let p_serial_no: String?
            let p_unit_status: String?
            let p_in_from: String?
            let p_in_to: String?
            let p_dealer_id: UUID?
            let p_out_from: String?
            let p_out_to: String?
            let p_warranty_status: String?
        }
        func text(_ s: String) -> String? {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
        let params = P(
            p_query: text(query),
            p_serial_no: text(filter.serialNo),
            p_unit_status: filter.unitStatus?.rawValue,
            p_in_from: filter.inFrom.map(BeijingDate.string),
            p_in_to: filter.inTo.map(BeijingDate.string),
            p_dealer_id: filter.dealerID,
            p_out_from: filter.outFrom.map(BeijingDate.string),
            p_out_to: filter.outTo.map(BeijingDate.string),
            p_warranty_status: filter.warranty?.rawValue)
        return try await supabase.rpc("search_models", params: params).execute().value
    }

    /// 某型号的全部入库记录（最新的在前）
    static func fetchStockIns(modelID: UUID) async throws -> [StockInRecord] {
        try await supabase.from("stock_in_records")
            .select("id,record_no,unit_id,serial_no,in_type,in_at,note")
            .eq("model_id", value: modelID)
            .order("in_at", ascending: false)
            .order("serial_no")
            .execute()
            .value
    }

    /// 某型号的全部出库记录，含已撤销订单（最新的在前）
    static func fetchOutbound(modelID: UUID) async throws -> [OutboundRecord] {
        try await supabase.from("v_report_items")
            .select("item_id,order_id,order_no,order_status,dealer_name,serial_no,actual_price,shipped_at")
            .eq("model_id", value: modelID)
            .order("shipped_at", ascending: false)
            .order("serial_no")
            .execute()
            .value
    }
}
