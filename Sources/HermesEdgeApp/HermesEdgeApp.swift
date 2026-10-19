import SwiftUI

@main
struct HermesEdgeApp: App {
    init() {
        _ = AppLogger.shared
    }

    var body: some Scene {
        WindowGroup {
            ChatView()
        }
    }
}
