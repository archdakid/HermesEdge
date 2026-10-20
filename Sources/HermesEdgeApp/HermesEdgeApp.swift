import SwiftUI

@main
struct HermesEdgeApp: App {
    init() {
        _ = AppLogger.shared
        AppLogger.shared.log("HermesEdge app launched (build 22)", tag: "BOOT")
    }

    var body: some Scene {
        WindowGroup {
            ChatView()
        }
    }
}
