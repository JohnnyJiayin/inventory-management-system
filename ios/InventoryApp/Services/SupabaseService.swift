import Foundation
import Supabase

/// 全局唯一的 Supabase 客户端。会话保存在钥匙串中，重启 App 后自动恢复登录。
let supabase = SupabaseClient(
    supabaseURL: AppConfig.supabaseURL,
    supabaseKey: AppConfig.supabaseAnonKey,
    options: SupabaseClientOptions(
        db: .init(decoder: DatabaseJSON.decoder),
        auth: .init(
            storage: AuthClient.Configuration.defaultLocalStorage,
            emitLocalSessionAsInitialSession: true
        )
    )
)

/// 数据库返回的时间带时区偏移（数据库时区为北京时间，例如 2026-10-09T15:54:58.318348+08:00）。
/// SDK 默认的解析格式不含时区，会忽略 +08:00 把时间当成 UTC，显示快 8 小时；这里按完整的 ISO 8601 解析。
enum DatabaseJSON {
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = parse(string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法解析的时间：\(string)")
        }
        return decoder
    }()

    static func parse(_ string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return withFraction.date(from: string) ?? withoutFraction.date(from: string)
    }

    // ISO8601DateFormatter 不保证线程安全，解码可能在多个任务中并发进行
    private static let lock = NSLock()

    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let withoutFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
