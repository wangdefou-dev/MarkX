#if DEBUG
import SwiftUI

/// A separate debug bundle uses this gallery to review layouts with fixtures.
/// It never bootstraps a real archive or starts jobs. Browser settings still use
/// real local probes so data-access failures can be reviewed accurately.
struct InterfacePreviewGallery: View {
    static var isEnabled: Bool { Bundle.main.object(forInfoDictionaryKey: "MarkXInterfacePreview") as? Bool == true }
    private enum Page: String, CaseIterable {
        case sidebar = "侧边栏", articleNumbers = "文章序号", download = "下载配置", connection = "连接存储"
        case sync = "同步", settings = "设置", result = "结果", progress = "进度"
    }
    @EnvironmentObject private var model: AppViewModel
    @State private var page: Page = .sidebar
    @State private var dark = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 20) {
                Picker("预览页面", selection: $page) {
                    ForEach(Page.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
                Toggle("深色预览", isOn: $dark).toggleStyle(.switch).fixedSize()
            }
            .padding(16)
            Divider()
            Group {
                switch page {
                case .sidebar: RootView()
                case .articleNumbers: articleNumberPreview
                case .download: AddCreatorsView()
                case .connection: ConnectionSetupView()
                case .sync: SyncAllCreatorsView()
                case .settings: SettingsView()
                case .result: DownloadResultView(notice: previewNotice)
                case .progress: DownloadProgressRootView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1120, minHeight: 790)
        .background(MarkXInterface.canvas)
        .font(MarkXTypography.body)
        .preferredColorScheme(dark ? .dark : .light)
        .onChange(of: page) { _, value in
            model.showingCreatorArticleDiscovery = value == .progress
            model.showingBrowserCapture = value == .progress
        }
    }

    private var articleNumberPreview: some View {
        HStack(alignment: .top, spacing: 30) {
            ForEach([360, 430], id: \.self) { width in
                VStack(spacing: 12) {
                    Text("\(width)pt 文章列表").font(MarkXTypography.headline)
                    List {
                        if let article = model.articles.first {
                            ForEach([1, 999, 9999, 10000, 99999], id: \.self) { index in
                                ArticleRow(article: article, index: index,
                                           creator: model.creators.first { $0.id == article.creatorID })
                            }
                        }
                    }
                    .listStyle(.inset)
                }
                .frame(width: CGFloat(width))
            }
        }
        .padding(24)
    }

    private var previewNotice: DownloadResultNotice {
        DownloadResultNotice(title: "本次同步结束，仍有未完成文章", message: "已检查 38 位博主，共识别 120 篇文章。新增保存 18 篇，已有完整归档跳过 96 篇，需订阅 4 篇，失败 2 篇。\n\n已保存的正文、图片和视频会保留。你可以在「需要处理」中查看原因并重新处理。", metrics: [
            .init(id: "creators", label: "博主", value: "38", systemImage: "person.2", tone: .accent),
            .init(id: "checked", label: "检查文章", value: "120", systemImage: "doc.text.magnifyingglass", tone: .neutral),
            .init(id: "saved", label: "新增保存", value: "18", systemImage: "checkmark.circle", tone: .positive),
            .init(id: "skipped", label: "已跳过", value: "96", systemImage: "forward.end", tone: .neutral),
            .init(id: "subscription", label: "需订阅", value: "4", systemImage: "lock", tone: .warning),
            .init(id: "failed", label: "失败", value: "2", systemImage: "xmark.circle", tone: .danger),
            .init(id: "images", label: "图片", value: "138", systemImage: "photo", tone: .neutral),
            .init(id: "videos", label: "视频", value: "12", systemImage: "video", tone: .neutral),
            .init(id: "pending", label: "待处理", value: "6", systemImage: "clock", tone: .warning)
        ])
    }
}
#endif
