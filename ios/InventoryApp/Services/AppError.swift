import Foundation
import Supabase

/// 把各种错误转换成可以直接展示给用户的中文说明。
/// 业务函数抛出的错误 message 本身就是中文说明（见 supabase/migrations）。
enum AppError {
    static func message(_ error: Error) -> String {
        if let e = error as? PostgrestError {
            return e.message
        }
        if let e = error as? AuthError {
            if e.errorCode == .invalidCredentials {
                return "邮箱或密码错误"
            }
            return e.message
        }
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "网络未连接，请检查网络后重试"
            case .timedOut:
                return "连接服务器超时，请重试"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "无法连接服务器，请稍后重试"
            default:
                return "网络错误：\(e.localizedDescription)"
            }
        }
        return error.localizedDescription
    }

    /// 是否为网络类错误（这类错误可以用同一个请求编号安全重试）
    static func isNetwork(_ error: Error) -> Bool {
        error is URLError
    }
}
