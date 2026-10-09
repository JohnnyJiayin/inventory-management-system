import Foundation
import Supabase

/// 保修查询（Issue #37，视图 v_warranty）
enum WarrantyService {
    enum StatusFilter: String, CaseIterable, Identifiable {
        case all, inWarranty, expiring, expired, void
        var id: Self { self }

        var title: String {
            switch self {
            case .all: "全部"
            case .inWarranty: "保修中"
            case .expiring: "即将过保"
            case .expired: "已过保"
            case .void: "已失效"
            }
        }
    }

    struct Filter: Equatable {
        /// 按产品名称、型号、条码、机身号、经销商、出库单号搜索
        var query = ""
        var status: StatusFilter = .all
        /// 只看当前保修（每台产品最近一次有效出库）
        var currentOnly = true
        var shippedFrom: Date?
        var shippedTo: Date?
    }

    static func search(_ filter: Filter, limit: Int = 500) async throws -> [WarrantyRecord] {
        var query = supabase.from("v_warranty").select()
        let q = PostgrestPattern.sanitize(filter.query)
        if !q.isEmpty {
            query = query.or([
                "model_name", "model", "barcode", "serial_no", "dealer_name", "order_no",
            ].map { "\($0).ilike.*\(q)*" }.joined(separator: ","))
        }
        switch filter.status {
        case .all: break
        case .inWarranty: query = query.eq("warranty_status", value: WarrantyStatus.inWarranty.rawValue)
        case .expiring: query = query.eq("expiring_soon", value: true)
        case .expired: query = query.eq("warranty_status", value: WarrantyStatus.expired.rawValue)
        case .void: query = query.eq("warranty_status", value: WarrantyStatus.void.rawValue)
        }
        if filter.currentOnly, filter.status != .void {
            query = query.eq("is_current", value: true)
        }
        if let from = filter.shippedFrom {
            query = query.gte("shipped_date", value: BeijingDate.string(from))
        }
        if let to = filter.shippedTo {
            query = query.lte("shipped_date", value: BeijingDate.string(to))
        }
        return try await query
            .order("shipped_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }
}

/// 业务日期一律按北京时间（架构设计 7）
enum BeijingDate {
    static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    static func string(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
