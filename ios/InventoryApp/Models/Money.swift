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

extension KeyedDecodingContainer {
    /// 解码 numeric(12,2) 金额。PostgREST 以 JSON 数字返回，解码时可能经过二进制浮点，
    /// 四舍五入到两位小数即可还原数据库中的精确值（12 位有效数字在 Double 精度之内）。
    func decodeMoney(forKey key: Key) throws -> Decimal {
        Money.rounded(try decode(Decimal.self, forKey: key))
    }

    func decodeMoneyIfPresent(forKey key: Key) throws -> Decimal? {
        try decodeIfPresent(Decimal.self, forKey: key).map(Money.rounded)
    }
}

extension Money {
    /// 传给业务函数的金额：以字符串传递，避免 JSON 数字经过浮点转换
    static func param(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: rounded(value)).stringValue
    }

    /// 编辑框中显示的金额（不带货币符号，例如 "12.5"）
    static func plain(_ value: Decimal) -> String {
        param(value)
    }
}
