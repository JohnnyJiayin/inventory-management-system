import Foundation
import Network

/// 网络监测（需求 17、架构设计 9.1）
///   * NWPathMonitor 实时监测本机网络；
///   * 启动时、网络恢复时、以及断开期间每隔几秒检查一次服务器是否可达。
/// 只有两者都正常时 isOnline 才为 true，所有写操作按钮据此禁用。
@MainActor
final class NetworkMonitor: ObservableObject {
    enum Status: Equatable {
        case online
        case noNetwork
        case serverUnreachable
    }

    @Published private(set) var status: Status = .online
    var isOnline: Bool { status == .online }

    private let monitor = NWPathMonitor()
    private var pathSatisfied = true
    private var retryTask: Task<Void, Never>?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.pathChanged(satisfied: path.status == .satisfied)
            }
        }
        monitor.start(queue: DispatchQueue(label: "NetworkMonitor"))
        Task { await checkServer() }
    }

    deinit { monitor.cancel() }

    private func pathChanged(satisfied: Bool) {
        pathSatisfied = satisfied
        if satisfied {
            Task { await checkServer() }
        } else {
            status = .noNetwork
            scheduleRetry()
        }
    }

    /// 检查服务器连接（调用 Auth 健康检查接口，不读写任何业务数据）。
    /// 以实际请求结果为准：NWPathMonitor 负责断网时立即提示，但它偶尔会误报（例如模拟器），
    /// 所以断开期间仍会定时真正请求一次服务器，成功即恢复。
    func checkServer() async {
        var request = URLRequest(url: AppConfig.supabaseURL.appendingPathComponent("auth/v1/health"))
        request.timeoutInterval = 6
        request.setValue(AppConfig.supabaseAnonKey, forHTTPHeaderField: "apikey")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let ok = (response as? HTTPURLResponse).map { (200..<500).contains($0.statusCode) } ?? false
            status = ok ? .online : .serverUnreachable
        } catch {
            status = pathSatisfied ? .serverUnreachable : .noNetwork
        }
        if status != .online { scheduleRetry() }
    }

    private func scheduleRetry() {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self else { return }
            self.retryTask = nil
            if self.status != .online { await self.checkServer() }
        }
    }
}
