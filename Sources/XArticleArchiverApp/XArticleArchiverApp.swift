import SwiftUI

@main
struct XArticleArchiverApp: App {
    @StateObject private var model = AppViewModel()

    var body: some Scene {
        WindowGroup("MarkX") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1_080, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1_280, height: 780)

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 640, height: 560)
        }
    }
}
