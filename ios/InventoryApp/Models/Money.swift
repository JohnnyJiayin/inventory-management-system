import Foundation

/// 金额统一使用 Decimal（架构设计 5.4），不用 Double，避免 0.1 + 0.2 之类的误差。
/// 数据库字段为 numeric(12,2)。
enum Money {
    /// 四舍五入到两位小数
    static func rounded(_ value: Decimal) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, 2, .plain)
        return result
    }

    /// 从用户输入解析金额：不能为负、最多两位小数；无效时返回 nil
    static func parse(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.range(of: #"^\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }
        return value
    }

    static func format(_ value: Decimal) -> String {
        formatter.string(from: rounded(value) as NSDecimalNumber) ?? "\(value)"
    }

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "CNY"
        f.currencySymbol = "¥"
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()
}
