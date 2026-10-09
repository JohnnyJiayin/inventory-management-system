import SwiftUI

@main
struct InventoryApp: App {
    @StateObject private var auth = AuthStore()
    @StateObject private var network = NetworkMonitor()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(auth)
                .environmentObject(network)
        }
    }
}
