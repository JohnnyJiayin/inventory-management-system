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

// MARK: - 报表（Issue #44–#49）

extension ReportService {
    enum Kind: String, CaseIterable, Identifiable {
        case monthly, dealers, models, shipping, warranty
        var id: Self { self }

        var title: String {
            switch self {
            case .monthly: "月度统计"
            case .dealers: "经销商统计"
            case .models: "产品型号统计"
            case .shipping: "运费统计"
            case .warranty: "保修统计"
            }
        }

        var shortTitle: String {
            switch self {
            case .monthly: "月度"
            case .dealers: "经销商"
            case .models: "型号"
            case .shipping: "运费"
            case .warranty: "保修"
            }
        }
    }

    enum OrderStatusFilter: String, CaseIterable, Identifiable {
        case completed, cancelled
        var id: Self { self }
        var title: String { self == .completed ? "有效订单" : "已撤销订单" }
    }

    enum WarrantyFilter: String, CaseIterable, Identifiable {
        case inWarranty = "in_warranty"
        case expiring, expired, void
        var id: Self { self }

        var title: String {
            switch self {
            case .inWarranty: "保修中"
            case .expiring: "即将过保"
            case .expired: "已过保"
            case .void: "已失效"
            }
        }
    }

    enum Period: String, CaseIterable, Identifiable {
        case month, custom, all
        var id: Self { self }

        var title: String {
            switch self {
            case .month: "按月"
            case .custom: "自定义日期"
            case .all: "全部时间"
            }
        }
    }

    /// 报表统一筛选条件（需求 15.4）：切换报表时保留
    struct Filter: Equatable {
        var period = Period.month
        /// 所选月份中的任意一天
        var month = Date()
        var from = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
        var to = Date()
        var dealerID: UUID?
        var modelID: UUID?
        var serialNo = ""
        var orderStatus = OrderStatusFilter.completed
        var warranty: WarrantyFilter?

        /// 北京时间日期范围 yyyy-MM-dd（含两端）；全部时间为 nil
        var dateRange: (from: String, to: String)? {
            switch period {
            case .all:
                return nil
            case .custom:
                return (BeijingDate.string(min(from, to)), BeijingDate.string(max(from, to)))
            case .month:
                let start = BeijingDate.monthStart(month)
                let end = BeijingDate.calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? start
                return (BeijingDate.string(start), BeijingDate.string(end))
            }
        }

        var trimmedSerial: String { serialNo.trimmingCharacters(in: .whitespaces) }
    }

    private struct Params: Encodable {
        let p_from: String?
        let p_to: String?
        let p_dealer_id: UUID?
        let p_model_id: UUID?
        let p_serial_no: String?
        let p_order_status: String
        let p_warranty_status: String?

        init(_ f: Filter) {
            let range = f.dateRange
            p_from = range?.from
            p_to = range?.to
            p_dealer_id = f.dealerID
            p_model_id = f.modelID
            p_serial_no = f.trimmedSerial.isEmpty ? nil : f.trimmedSerial
            p_order_status = f.orderStatus.rawValue
            p_warranty_status = f.warranty?.rawValue
        }
    }

    private static func rpc<T: Decodable>(_ name: String, _ filter: Filter) async throws -> T {
        try await supabase.rpc(name, params: Params(filter)).execute().value
    }

    /// 筛选条件的文字说明（导出文件中写在标题下方）
    static func describe(_ f: Filter, dealerName: String?, modelName: String?) -> String {
        var parts: [String] = []
        if let range = f.dateRange {
            parts.append(f.period == .month ? "月份：\(BeijingDate.monthTitle(f.month))"
                                            : "日期：\(range.from) 至 \(range.to)")
        } else {
            parts.append("时间：全部")
        }
        if let dealerName { parts.append("经销商：\(dealerName)") }
        if let modelName { parts.append("型号：\(modelName)") }
        if !f.trimmedSerial.isEmpty { parts.append("机身号：\(f.trimmedSerial)") }
        parts.append("订单状态：\(f.orderStatus.title)")
        if let w = f.warranty { parts.append("保修状态：\(w.title)") }
        return parts.joined(separator: "；")
    }

    private static let commonNote =
        "只统计已完成订单（筛选“已撤销订单”时除外）；运费按订单计一次；日期与月份按北京时间。"

    static func load(_ kind: Kind, filter: Filter, dealerName: String?, modelName: String?) async throws -> ReportDocument {
        let filterText = describe(filter, dealerName: dealerName, modelName: modelName)
        let tables: [ReportTable]
        var note = commonNote
        switch kind {
        case .monthly:
            tables = [monthlyTable(try await rpc("report_monthly", filter))]
            note += "入库数量只受日期、型号、机身号筛选影响。保修中 / 已过保按每台产品的当前保修计算。"
        case .dealers:
            tables = [dealerTable(try await rpc("report_dealers", filter))]
        case .models:
            tables = [modelTable(try await rpc("report_models", filter))]
            note += "当前库存不受日期筛选影响。"
        case .shipping:
            tables = shippingTables(try await rpc("report_shipping", filter))
        case .warranty:
            let summary: [WarrantyReportSummary] = try await rpc("report_warranty", filter)
            tables = warrantyTables(summary.first, try await warrantyRecords(filter))
            note = "保修中 / 即将过保 / 已过保按每台产品的当前保修计算，与保修查询页“只看当前保修”一致；"
                + "即将过保 = 30 天内到期。日期按北京时间。"
        }
        return ReportDocument(title: kind.title, filterText: filterText, tables: tables, note: note, generatedAt: Date())
    }

    // MARK: 各报表转换为表格

    private static func monthlyTable(_ rows: [MonthlyReportRow]) -> ReportTable {
        ReportTable(
            title: "月度统计",
            columns: [
                .init(title: "月份"), .init(title: "入库数量", numeric: true), .init(title: "出库数量", numeric: true),
                .init(title: "有效订单数", numeric: true), .init(title: "销售金额", numeric: true),
                .init(title: "运费总额", numeric: true), .init(title: "订单总金额", numeric: true),
                .init(title: "保修中", numeric: true), .init(title: "已过保", numeric: true),
            ],
            rows: rows.map {
                [.text(BeijingDate.monthTitle(dayString: $0.month)), .int($0.inQty), .int($0.outQty), .int($0.orderCount),
                 .money($0.productsAmount), .money($0.shippingFee), .money($0.totalAmount),
                 .int($0.inWarrantyQty), .int($0.expiredQty)]
            },
            total: rows.isEmpty ? nil : [
                .text("合计"), .int(rows.sum(\.inQty)), .int(rows.sum(\.outQty)), .int(rows.sum(\.orderCount)),
                .money(rows.sum(\.productsAmount)), .money(rows.sum(\.shippingFee)), .money(rows.sum(\.totalAmount)),
                .int(rows.sum(\.inWarrantyQty)), .int(rows.sum(\.expiredQty)),
            ])
    }

    private static func dealerTable(_ rows: [DealerReportRow]) -> ReportTable {
        ReportTable(
            title: "经销商统计",
            columns: [
                .init(title: "经销商"), .init(title: "订单数量", numeric: true), .init(title: "产品数量", numeric: true),
                .init(title: "各型号出库数量"), .init(title: "销售金额", numeric: true),
                .init(title: "运费总额", numeric: true), .init(title: "订单总金额", numeric: true),
            ],
            rows: rows.map { r in
                [.text(r.dealerName), .int(r.orderCount), .int(r.itemCount),
                 .text(r.models.map { "\($0.modelName) \($0.model) × \($0.qty)" }.joined(separator: "、")),
                 .money(r.productsAmount), .money(r.shippingFee), .money(r.totalAmount)]
            },
            total: rows.isEmpty ? nil : [
                .text("合计"), .int(rows.sum(\.orderCount)), .int(rows.sum(\.itemCount)), .none,
                .money(rows.sum(\.productsAmount)), .money(rows.sum(\.shippingFee)), .money(rows.sum(\.totalAmount)),
            ])
    }

    private static func modelTable(_ rows: [ModelReportRow]) -> ReportTable {
        ReportTable(
            title: "产品型号统计",
            columns: [
                .init(title: "产品名称"), .init(title: "型号"), .init(title: "入库数量", numeric: true),
                .init(title: "出库数量", numeric: true), .init(title: "当前库存", numeric: true),
                .init(title: "涉及经销商", numeric: true), .init(title: "销售金额", numeric: true),
                .init(title: "保修中", numeric: true), .init(title: "已过保", numeric: true),
            ],
            rows: rows.map {
                [.text($0.modelName), .text($0.model), .int($0.inQty), .int($0.outQty), .int($0.stockQty),
                 .int($0.dealerCount), .money($0.productsAmount), .int($0.inWarrantyQty), .int($0.expiredQty)]
            },
            // 涉及经销商数不能跨型号相加（同一经销商会重复计算），合计行留空
            total: rows.isEmpty ? nil : [
                .text("合计"), .none, .int(rows.sum(\.inQty)), .int(rows.sum(\.outQty)), .int(rows.sum(\.stockQty)),
                .none, .money(rows.sum(\.productsAmount)), .int(rows.sum(\.inWarrantyQty)), .int(rows.sum(\.expiredQty)),
            ])
    }

    /// 运费统计（需求 15.5）：每月汇总、每个经销商每月运费、每笔订单明细
    private static func shippingTables(_ rows: [ShippingReportRow]) -> [ReportTable] {
        let months = Dictionary(grouping: rows, by: \.month).sorted { $0.key > $1.key }
        let monthly = ReportTable(
            title: "每月运费汇总",
            columns: [
                .init(title: "月份"), .init(title: "订单数", numeric: true), .init(title: "出库产品数", numeric: true),
                .init(title: "产品金额", numeric: true), .init(title: "运费总额", numeric: true),
                .init(title: "订单总金额", numeric: true),
            ],
            rows: months.map { month, rs in
                [.text(BeijingDate.monthTitle(dayString: month)), .int(rs.count), .int(rs.sum(\.itemCount)),
                 .money(rs.sum(\.productsAmount)), .money(rs.sum(\.shippingFee)), .money(rs.sum(\.totalAmount))]
            },
            total: rows.isEmpty ? nil : [
                .text("合计"), .int(rows.count), .int(rows.sum(\.itemCount)),
                .money(rows.sum(\.productsAmount)), .money(rows.sum(\.shippingFee)), .money(rows.sum(\.totalAmount)),
            ])

        let byDealer = ReportTable(
            title: "经销商每月运费",
            columns: [
                .init(title: "月份"), .init(title: "经销商"), .init(title: "订单数", numeric: true),
                .init(title: "出库产品数", numeric: true), .init(title: "运费", numeric: true),
            ],
            rows: months.flatMap { month, rs in
                Dictionary(grouping: rs, by: \.dealerId)
                    .map { _, ds in ds }
                    .sorted { $0[0].dealerName < $1[0].dealerName }
                    .map { ds -> [ReportValue] in
                        [.text(BeijingDate.monthTitle(dayString: month)), .text(ds[0].dealerName), .int(ds.count),
                         .int(ds.sum(\.itemCount)), .money(ds.sum(\.shippingFee))]
                    }
            })

        let detail = ReportTable(
            title: "订单运费明细",
            columns: [
                .init(title: "月份"), .init(title: "经销商"), .init(title: "出库单号"), .init(title: "出库日期"),
                .init(title: "产品数量", numeric: true), .init(title: "产品金额", numeric: true),
                .init(title: "订单运费", numeric: true), .init(title: "订单总金额", numeric: true),
            ],
            rows: rows.map {
                [.text(BeijingDate.monthTitle(dayString: $0.month)), .text($0.dealerName), .text($0.orderNo),
                 .text(BeijingDate.string($0.shippedAt)), .int($0.itemCount), .money($0.productsAmount),
                 .money($0.shippingFee), .money($0.totalAmount)]
            },
            total: rows.isEmpty ? nil : [
                .text("合计"), .none, .text("\(rows.count) 张订单"), .none, .int(rows.sum(\.itemCount)),
                .money(rows.sum(\.productsAmount)), .money(rows.sum(\.shippingFee)), .money(rows.sum(\.totalAmount)),
            ])
        return [monthly, byDealer, detail]
    }

    /// 保修统计（需求 13.3）：数量汇总 + 明细
    private static func warrantyTables(_ s: WarrantyReportSummary?, _ records: [WarrantyRecord]) -> [ReportTable] {
        let summary = ReportTable(
            title: "保修数量",
            columns: [.init(title: "保修状态"), .init(title: "产品数量", numeric: true)],
            rows: [
                [.text("保修中"), .int(s?.inWarrantyQty ?? 0)],
                [.text("其中即将过保（30 天内）"), .int(s?.expiringQty ?? 0)],
                [.text("已过保"), .int(s?.expiredQty ?? 0)],
                [.text("已失效（订单已撤销）"), .int(s?.voidQty ?? 0)],
            ])
        let detail = ReportTable(
            title: "保修明细",
            columns: [
                .init(title: "产品名称"), .init(title: "型号"), .init(title: "机身号"), .init(title: "经销商"),
                .init(title: "出库单号"), .init(title: "出库日期"), .init(title: "保修截止"),
                .init(title: "保修状态"), .init(title: "剩余天数", numeric: true),
            ],
            rows: records.map { r in
                let status = r.expiringSoon ? "即将过保" : r.warrantyStatus.title
                return [.text(r.modelName), .text(r.model), .text(r.serialNo), .text(r.dealerName ?? ""),
                        .text(r.orderNo), .text(r.shippedAt.map(BeijingDate.string) ?? ""), .text(r.warrantyEnd),
                        .text(status), r.daysLeft.map { .int(max($0, 0)) } ?? .none]
            })
        return [summary, detail]
    }

    /// 保修明细：与 report_warranty 使用相同的条件（有效订单只取当前保修）
    private static func warrantyRecords(_ f: Filter) async throws -> [WarrantyRecord] {
        var query = supabase.from("v_warranty").select()
        if f.orderStatus == .completed {
            query = query.eq("is_current", value: true)
        } else {
            query = query.eq("order_status", value: "cancelled")
        }
        if let range = f.dateRange {
            query = query.gte("shipped_date", value: range.from).lte("shipped_date", value: range.to)
        }
        if let dealerID = f.dealerID { query = query.eq("dealer_id", value: dealerID) }
        if let modelID = f.modelID { query = query.eq("model_id", value: modelID) }
        if !f.trimmedSerial.isEmpty { query = query.eq("serial_no", value: f.trimmedSerial) }
        switch f.warranty {
        case .none: break
        case .expiring: query = query.eq("expiring_soon", value: true)
        case let .some(w): query = query.eq("warranty_status", value: w.rawValue)
        }
        return try await query
            .order("warranty_end")
            .order("serial_no")
            .limit(5000)
            .execute()
            .value
    }
}

private extension Sequence {
    func sum(_ key: KeyPath<Element, Int>) -> Int { reduce(0) { $0 + $1[keyPath: key] } }
    func sum(_ key: KeyPath<Element, Decimal>) -> Decimal { reduce(Decimal(0)) { $0 + $1[keyPath: key] } }
}
