import Foundation
import Supabase

/// 全局唯一的 Supabase 客户端。会话保存在钥匙串中，重启 App 后自动恢复登录。
let supabase = SupabaseClient(
    supabaseURL: AppConfig.supabaseURL,
    supabaseKey: AppConfig.supabaseAnonKey,
    options: SupabaseClientOptions(
        auth: .init(
            storage: AuthClient.Configuration.defaultLocalStorage,
            emitLocalSessionAsInitialSession: true
        )
    )
)
