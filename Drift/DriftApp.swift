import SwiftUI

@main struct DriftApp: App {
    @State private var store = DriftStore()
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--callback-probe") {
                CallbackProbeView()
            } else {
                CreateView(store: store).tint(Palette.accent).foregroundStyle(Palette.ink)
            }
            #else
            CreateView(store: store).tint(Palette.accent).foregroundStyle(Palette.ink)
            #endif
        }
    }
}
