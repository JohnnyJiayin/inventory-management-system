import Foundation

// MARK: - 报表文档（屏幕显示与 CSV / Excel / PDF 导出共用同一份数据，保证内容一致）

/// 表格中的一个值
enum ReportValue: Hashable {
    case text(String)
    case int(Int)
    case money(Decimal)
    case none

    /// 屏幕和 PDF 中的显示文字
    var display: String {
        switch self {
        case let .text(s): s
        case let .int(n): "\(n)"
        case let .money(m): Money.format(m)
        case .none: ""
        }
    }

    /// CSV 中的文字：金额不带货币符号和千分位，方便表格软件按数字处理
    var plain: String {
        switch self {
        case let .text(s): s
        case let .int(n): "\(n)"
        case let .money(m): Money.plain(m)
        case .none: ""
        }
    }

    var isNumeric: Bool {
        switch self {
        case .int, .money: true
        case .text, .none: false
        }
    }
}

struct ReportColumn: Hashable {
    let title: String
    /// 数字列右对齐
    var numeric = false
}

struct ReportTable: Identifiable, Hashable {
    let title: String
    let columns: [ReportColumn]
    let rows: [[ReportValue]]
    /// 合计行（可选）
    var total: [ReportValue]?

    var id: String { title }
}

struct ReportDocument: Hashable {
    /// 例如“月度统计”
    let title: String
    /// 当前筛选条件的文字说明，导出时写在标题下方
    let filterText: String
    let tables: [ReportTable]
    /// 统计口径说明（屏幕底部与导出文件中显示）
    var note: String?
    let generatedAt: Date
}

// MARK: - 统计函数返回的数据行

/// report_monthly
struct MonthlyReportRow: Decodable {
    let month: String
    let inQty: Int
    let outQty: Int
    let orderCount: Int
    let productsAmount: Decimal
    let shippingFee: Decimal
    let totalAmount: Decimal
    let inWarrantyQty: Int
    let expiredQty: Int

    enum CodingKeys: String, CodingKey {
        case month
        case inQty = "in_qty"
        case outQty = "out_qty"
        case orderCount = "order_count"
        case productsAmount = "products_amount"
        case shippingFee = "shipping_fee"
        case totalAmount = "total_amount"
        case inWarrantyQty = "in_warranty_qty"
        case expiredQty = "expired_qty"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        month = try c.decode(String.self, forKey: .month)
        inQty = try c.decode(Int.self, forKey: .inQty)
        outQty = try c.decode(Int.self, forKey: .outQty)
        orderCount = try c.decode(Int.self, forKey: .orderCount)
        productsAmount = try c.decodeMoney(forKey: .productsAmount)
        shippingFee = try c.decodeMoney(forKey: .shippingFee)
        totalAmount = try c.decodeMoney(forKey: .totalAmount)
        inWarrantyQty = try c.decode(Int.self, forKey: .inWarrantyQty)
        expiredQty = try c.decode(Int.self, forKey: .expiredQty)
    }
}

/// report_dealers
struct DealerReportRow: Decodable {
    struct ModelQty: Decodable {
        let modelName: String
        let model: String
        let qty: Int

        enum CodingKeys: String, CodingKey {
            case model, qty
            case modelName = "model_name"
        }
    }

    let dealerId: UUID
    let dealerName: String
    let orderCount: Int
    let itemCount: Int
    let productsAmount: Decimal
    let shippingFee: Decimal
    let totalAmount: Decimal
    let models: [ModelQty]

    enum CodingKeys: String, CodingKey {
        case models
        case dealerId = "dealer_id"
        case dealerName = "dealer_name"
        case orderCount = "order_count"
        case itemCount = "item_count"
        case productsAmount = "products_amount"
        case shippingFee = "shipping_fee"
        case totalAmount = "total_amount"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dealerId = try c.decode(UUID.self, forKey: .dealerId)
        dealerName = try c.decode(String.self, forKey: .dealerName)
        orderCount = try c.decode(Int.self, forKey: .orderCount)
        itemCount = try c.decode(Int.self, forKey: .itemCount)
        productsAmount = try c.decodeMoney(forKey: .productsAmount)
        shippingFee = try c.decodeMoney(forKey: .shippingFee)
        totalAmount = try c.decodeMoney(forKey: .totalAmount)
        models = try c.decode([ModelQty].self, forKey: .models)
    }
}

/// report_models
struct ModelReportRow: Decodable {
    let modelName: String
    let model: String
    let inQty: Int
    let outQty: Int
    let stockQty: Int
    let dealerCount: Int
    let productsAmount: Decimal
    let inWarrantyQty: Int
    let expiredQty: Int

    enum CodingKeys: String, CodingKey {
        case model
        case modelName = "model_name"
        case inQty = "in_qty"
        case outQty = "out_qty"
        case stockQty = "stock_qty"
        case dealerCount = "dealer_count"
        case productsAmount = "products_amount"
        case inWarrantyQty = "in_warranty_qty"
        case expiredQty = "expired_qty"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelName = try c.decode(String.self, forKey: .modelName)
        model = try c.decode(String.self, forKey: .model)
        inQty = try c.decode(Int.self, forKey: .inQty)
        outQty = try c.decode(Int.self, forKey: .outQty)
        stockQty = try c.decode(Int.self, forKey: .stockQty)
        dealerCount = try c.decode(Int.self, forKey: .dealerCount)
        productsAmount = try c.decodeMoney(forKey: .productsAmount)
        inWarrantyQty = try c.decode(Int.self, forKey: .inWarrantyQty)
        expiredQty = try c.decode(Int.self, forKey: .expiredQty)
    }
}

/// report_shipping：每张订单一行
struct ShippingReportRow: Decodable {
    let month: String
    let dealerId: UUID
    let dealerName: String
    let orderNo: String
    let shippedAt: Date
    let itemCount: Int
    let productsAmount: Decimal
    let shippingFee: Decimal
    let totalAmount: Decimal

    enum CodingKeys: String, CodingKey {
        case month
        case dealerId = "dealer_id"
        case dealerName = "dealer_name"
        case orderNo = "order_no"
        case shippedAt = "shipped_at"
        case itemCount = "item_count"
        case productsAmount = "products_amount"
        case shippingFee = "shipping_fee"
        case totalAmount = "total_amount"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        month = try c.decode(String.self, forKey: .month)
        dealerId = try c.decode(UUID.self, forKey: .dealerId)
        dealerName = try c.decode(String.self, forKey: .dealerName)
        orderNo = try c.decode(String.self, forKey: .orderNo)
        shippedAt = try c.decode(Date.self, forKey: .shippedAt)
        itemCount = try c.decode(Int.self, forKey: .itemCount)
        productsAmount = try c.decodeMoney(forKey: .productsAmount)
        shippingFee = try c.decodeMoney(forKey: .shippingFee)
        totalAmount = try c.decodeMoney(forKey: .totalAmount)
    }
}

/// report_warranty
struct WarrantyReportSummary: Decodable {
    let inWarrantyQty: Int
    let expiringQty: Int
    let expiredQty: Int
    let voidQty: Int

    enum CodingKeys: String, CodingKey {
        case inWarrantyQty = "in_warranty_qty"
        case expiringQty = "expiring_qty"
        case expiredQty = "expired_qty"
        case voidQty = "void_qty"
    }
}
