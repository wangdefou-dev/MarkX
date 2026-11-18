import SwiftUI

@main
struct XArticleArchiverApp: App {
    @NSApplicationDelegateAdaptor(MarkXAppDelegate.self) private var appDelegate
    @StateObject private var model = AppViewModel()
    @AppStorage("articlePreviewTextScale") private var articleTextScale = 1.0

    var body: some Scene {
        Window("MarkX", id: "main") {
            #if DEBUG
            if InterfacePreviewGallery.isEnabled {
                InterfacePreviewGallery().environmentObject(model)
            } else {
                libraryWindow
            }
            #else
            libraryWindow
            #endif
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1_360, height: 860)
        .handlesExternalEvents(matching: MarkXWindowPolicy.externalEventKeys)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { AppUpdater.shared.check(userInitiated: true) }
            }
            // HIG: every toolbar and context action is also reachable from the
            // menu bar, with standard shortcuts.
            CommandGroup(replacing: .newItem) {
                Button("下载文章…") { model.presentDownloadSheet() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(isBusy)
                Button("同步所有博主…") { model.requestSyncAll() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(isBusy || model.enabledCreatorCount == 0)
                Divider()
                Button("显示下载进度") { model.showDownloadProgressWindow() }
                    .disabled(!model.hasActiveDownloadProgress)
                Button("停止当前任务") { model.cancelCurrentTask() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!isBusy)
            }
            SidebarCommands()
            ToolbarCommands()
            CommandGroup(after: .toolbar) {
                Divider()
                Button("放大正文") { setArticleTextScale(articleTextScale + 0.1) }
                    .keyboardShortcut("+", modifiers: .command)
                    .disabled(articleTextScale >= 1.6)
                Button("缩小正文") { setArticleTextScale(articleTextScale - 0.1) }
                    .keyboardShortcut("-", modifiers: .command)
                    .disabled(articleTextScale <= 0.8)
                Button("正文实际大小") { articleTextScale = 1.0 }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(articleTextScale == 1.0)
            }
            CommandMenu("文章") {
                let article = model.selectedArticle
                Button("在浏览器中打开原文") { model.openSource() }
                    .keyboardShortcut("l", modifiers: .command)
                    .disabled(article == nil)
                Button("打开 Markdown") { model.openSelectedArticle() }
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(article == nil)
                Button("在 Finder 中显示") { model.revealSelectedArticle() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(article == nil)
                Divider()
                Button("重新处理") { if let article { model.restartProcessing(article) } }
                    .disabled(article == nil || isBusy)
                Divider()
                Button("删除文章…") { if let article { model.requestDeleteArticle(article) } }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(article == nil || isBusy || model.selectedCollectionID != nil)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }

    private var isBusy: Bool { model.isRunning || model.hasActiveDownloadProgress }

    /// Same 80–160% range and 10% steps as the reading view's A−/A+ controls.
    private func setArticleTextScale(_ value: Double) {
        articleTextScale = min(max((value * 10).rounded(), 8), 16) / 10
    }

    private var libraryWindow: some View {
        RootView()
            .environmentObject(model)
            .frame(minWidth: 1_080, minHeight: 680)
            .onAppear {
                MarkXWindowPolicy.enforceSingleMainWindow()
                AppUpdater.shared.isBusy = { [weak model] in
                    guard let model else { return false }
                    return model.isRunning || model.hasActiveDownloadProgress
                }
                AppUpdater.shared.startAutomaticChecks()
            }
    }
}
