import AppKit
import SwiftUI

@MainActor
final class DownloadProgressWindowDelegate: NSObject, NSWindowDelegate {
    private weak var model: AppViewModel?

    init(model: AppViewModel) {
        self.model = model
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        model?.hideDownloadProgressWindow()
        return false
    }

}

struct DownloadProgressRootView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var stage = Stage.discovery
    private enum Stage: Hashable { case discovery, capture }
    private var bothStages: Bool { model.showingCreatorArticleDiscovery && model.showingBrowserCapture }
    private var showsDiscovery: Bool { model.showingCreatorArticleDiscovery && (!bothStages || stage == .discovery) }
    private var showsCapture: Bool { model.showingBrowserCapture && (!bothStages || stage == .capture) }

    var body: some View {
        VStack(spacing: 0) {
            if bothStages {
                Picker("下载阶段", selection: $stage) {
                    Text("发现文章").tag(Stage.discovery)
                    Text("保存正文").tag(Stage.capture)
                }
                .labelsHidden().pickerStyle(.segmented)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .help("切换查看进度，两个阶段仍在后台同时运行")
                Divider()
            }
            ZStack {
                // Opacity switches the presentation without unmounting either
                // WebKit controller or cancelling its capture task.
                if model.showingCreatorArticleDiscovery {
                    BrowserCreatorArticleDiscoveryView()
                        .opacity(showsDiscovery ? 1 : 0)
                        .allowsHitTesting(showsDiscovery).accessibilityHidden(!showsDiscovery)
                }
                if model.showingBrowserCapture {
                    BrowserArticleCaptureView()
                        .opacity(showsCapture ? 1 : 0)
                        .allowsHitTesting(showsCapture).accessibilityHidden(!showsCapture)
                }
                if !model.showingCreatorArticleDiscovery && !model.showingBrowserCapture {
                    ContentUnavailableView("正在准备下一阶段", systemImage: "arrow.triangle.2.circlepath",
                        description: Text("已保存的内容会保留，后台队列正在继续。"))
                }
            }
        }
        .frame(minWidth: 760, minHeight: 590)
        .background(MarkXInterface.canvas)
        .font(MarkXTypography.body)
        .onAppear { stage = model.showingBrowserCapture ? .capture : .discovery }
        .onChange(of: model.showingBrowserCapture) { _, value in if value { stage = .capture } }
    }
}
