import Foundation
import Supabase

/// 首页（Issue #42）与统计报表（Issue #43–#49）。数字全部由数据库统计函数计算。
enum ReportService {
    static func dashboard() async throws -> DashboardSummary {
        try await supabase.rpc("dashboard_summary").execute().value
    }
}

/// 首页数字（dashboard_summary）；“当月”按北京时间自然月
struct DashboardSummary: Decodable, Equatable {
    /// 当月第一天 yyyy-MM-dd
    let month: String
    let stockQty: Int
    let modelCount: Int
    let monthInQty: Int
    let monthOutQty: Int
    let monthOrderCount: Int
    let monthSales: Decimal
    let monthShipping: Decimal
    let expiringQty: Int

    enum CodingKeys: String, CodingKey {
        case month
        case stockQty = "stock_qty"
        case modelCount = "model_count"
        case monthInQty = "month_in_qty"
        case monthOutQty = "month_out_qty"
        case monthOrderCount = "month_order_count"
        case monthSales = "month_sales"
        case monthShipping = "month_shipping"
        case expiringQty = "expiring_qty"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        month = try c.decode(String.self, forKey: .month)
        stockQty = try c.decode(Int.self, forKey: .stockQty)
        modelCount = try c.decode(Int.self, forKey: .modelCount)
        monthInQty = try c.decode(Int.self, forKey: .monthInQty)
        monthOutQty = try c.decode(Int.self, forKey: .monthOutQty)
        monthOrderCount = try c.decode(Int.self, forKey: .monthOrderCount)
        monthSales = try c.decodeMoney(forKey: .monthSales)
        monthShipping = try c.decodeMoney(forKey: .monthShipping)
        expiringQty = try c.decode(Int.self, forKey: .expiringQty)
    }

    /// 例如“10 月”
    var monthTitle: String {
        let parts = month.split(separator: "-")
        guard parts.count >= 2, let m = Int(parts[1]) else { return "本月" }
        return "\(m) 月"
    }
}
