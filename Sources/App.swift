import SwiftUI

@main
struct HiCrispApp: App {
    @StateObject private var displayManager = DisplayManager()
    @StateObject private var virtualDisplayManager = VirtualDisplayManager()

    var body: some Scene {
        MenuBarExtra("HiCrisp", systemImage: "display") {
            MenuBarView(
                displayManager: displayManager,
                virtualDisplayManager: virtualDisplayManager
            )
        }
        .menuBarExtraStyle(.window)
    }
}
