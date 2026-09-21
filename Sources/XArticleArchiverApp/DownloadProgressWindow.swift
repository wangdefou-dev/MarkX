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

    private enum Content: Hashable {
        case discovery
        case capture
        case switching
    }

    private var content: Content {
        if model.showingCreatorArticleDiscovery { return .discovery }
        if model.showingBrowserCapture { return .capture }
        return .switching
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.showingCreatorArticleDiscovery {
                BrowserCreatorArticleDiscoveryView()
            }
            if model.showingCreatorArticleDiscovery && model.showingBrowserCapture {
                Divider()
            }
            if model.showingBrowserCapture {
                BrowserArticleCaptureView()
            }
            if content == .switching {
                ContentUnavailableView(
                    "下载阶段切换中",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("正在从文章列表进入正文下载队列。")
                )
                .frame(minWidth: 760, minHeight: 590)
            }
        }
        .environmentObject(model)
    }
}
