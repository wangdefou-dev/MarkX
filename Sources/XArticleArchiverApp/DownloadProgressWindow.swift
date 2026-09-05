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

    var body: some View {
        Group {
            if model.showingCreatorArticleDiscovery {
                BrowserCreatorArticleDiscoveryView()
            } else if model.showingBrowserCapture {
                BrowserArticleCaptureView()
            } else {
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
