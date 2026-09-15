import SwiftUI

@main
struct XArticleArchiverApp: App {
    @NSApplicationDelegateAdaptor(MarkXAppDelegate.self) private var appDelegate
    @StateObject private var model = AppViewModel()

    var body: some Scene {
        Window("MarkX", id: "main") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1_080, minHeight: 680)
                .onAppear {
                    MarkXWindowPolicy.enforceSingleMainWindow()
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1_280, height: 780)
        .handlesExternalEvents(matching: MarkXWindowPolicy.externalEventKeys)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 640, height: 560)
        }
    }
}
