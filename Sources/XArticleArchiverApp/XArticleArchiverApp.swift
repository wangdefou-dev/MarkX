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
            CommandMenu("资料库") {
                Button("整理重复媒体缓存…") { model.cleanVerifiedMediaCache() }
                    .disabled(model.isRunning || model.hasActiveDownloadProgress || model.archiveRoot == nil)
                    .help("核对并移除已有完整备份的重复隐藏缓存")
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 640, height: 560)
        }
    }
}
