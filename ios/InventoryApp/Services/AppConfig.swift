import Foundation

/// 从 Info.plist 读取 Supabase 配置（值由 Config/Secrets.xcconfig 注入）。
enum AppConfig {
    static let supabaseURL: URL = {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
              let url = URL(string: raw), url.scheme != nil, url.host != nil else {
            fatalError("SUPABASE_URL 未配置：复制 ios/Config/Secrets.example.xcconfig 为 Secrets.xcconfig 并填写")
        }
        return url
    }()

    static let supabaseAnonKey: String = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
              !key.isEmpty, key != "your-anon-key" else {
            fatalError("SUPABASE_ANON_KEY 未配置：复制 ios/Config/Secrets.example.xcconfig 为 Secrets.xcconfig 并填写")
        }
        return key
    }()

    /// 产品照片存储桶（私有）
    static let photoBucket = "product-photos"
}
