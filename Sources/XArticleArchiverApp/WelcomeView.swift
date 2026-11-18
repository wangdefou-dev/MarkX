import AppKit
import SwiftUI

/// Full-width page for a first run or an empty library. It replaces the narrow
/// list column so setup reads as one centred, unhurried page.
struct WelcomeView: View {
    @EnvironmentObject private var model: AppViewModel

    private static let columnWidth: CGFloat = 640

    private var isConfigured: Bool { model.archiveRoot != nil && model.imageHostVerified }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                    setupSteps.padding(.top, MarkXSpace.x5)
                    actions.padding(.top, MarkXSpace.x4)
                    highlights.padding(.top, MarkXSpace.x6)
                }
                .frame(maxWidth: Self.columnWidth, alignment: .leading)
                .padding(.horizontal, MarkXSpace.x6)
                .padding(.vertical, MarkXSpace.pageTop)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
            }
        }
        .background(WelcomeBackdrop())
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
                .accessibilityHidden(true)
            Text(isConfigured ? "资料库已就绪" : "欢迎使用 MarkX")
                .font(MarkXFont.detailStrong)
                .foregroundStyle(MarkXInterface.text2)
                .padding(.top, MarkXSpace.x3)
            Text("把 X Article 全文收进自己的 Mac")
                .font(MarkXFont.display)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, MarkXSpace.m)
            Text(isConfigured
                 ? "粘贴博主主页、用户名或文章链接，MarkX 会在后台保存正文、原图和视频，并导出可迁移的 Markdown。"
                 : "按博主读取 X Articles 列表，逐篇保存标题、段落、表格、代码、图片和视频顺序。全程不调用 X API，文章只保存在你选择的文件夹里。")
                .font(MarkXFont.lead)
                .foregroundStyle(MarkXInterface.text2)
                .lineSpacing(MarkXSpace.s)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, MarkXSpace.l)
        }
    }

    private var setupSteps: some View {
        VStack(spacing: 0) {
            WelcomeStepRow(
                symbol: "folder",
                title: "本地归档目录",
                detail: model.archiveRoot?.path ?? "选择一个文件夹，用来保存文章、图片和 Markdown",
                isReady: model.archiveRoot != nil
            )
            Rectangle().fill(MarkXInterface.hairline).frame(height: 1).padding(.leading, MarkXSpace.xl + MarkXIcon.tile + MarkXSpace.l)
            WelcomeStepRow(
                symbol: "person.badge.key",
                title: "浏览器 X 登录",
                detail: model.browserSessionProbe.summary,
                isReady: model.hasBrowserSessionData
            ) {
                if let browser = model.browserNameNeedingAccess {
                    Button("授权读取 \(browser)…") { model.chooseBrowserDataDirectory() }.buttonStyle(.markxCompactProminent)
                        .help("macOS 需要你确认一次，MarkX 才能读取 \(browser) 里的 X 登录记录")
                }
            }
            Rectangle().fill(MarkXInterface.hairline).frame(height: 1).padding(.leading, MarkXSpace.xl + MarkXIcon.tile + MarkXSpace.l)
            WelcomeStepRow(
                symbol: "photo.on.rectangle",
                title: "媒体存储",
                detail: model.imageHostDetail,
                isReady: model.imageHostVerified
            )
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: MarkXRadius.hero))
        .overlay(RoundedRectangle(cornerRadius: MarkXRadius.hero).strokeBorder(MarkXInterface.hairline, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: MarkXSpace.l) {
            if isConfigured {
                Button { model.presentDownloadSheet() } label: {
                    Label("开始下载文章", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.markxPillProminent)
                                .disabled(model.isRunning || model.hasActiveDownloadProgress)
                .help("输入博主主页或 X Article 链接开始下载")
            } else {
                Button("开始配置") { model.showingConnectionSetup = true }
                .buttonStyle(.markxPillProminent)
                                .help("设置本地归档目录和图片、视频存储方式")
            }
            if model.archiveRoot != nil {
                Button("生成体验样例") { model.installDemo() }
                    .buttonStyle(.markxPill)
                    .disabled(model.isRunning)
                    .help("在已选目录生成一篇不需要网络的演示文章")
            }
        }
    }

    private var highlights: some View {
        HStack(alignment: .top, spacing: MarkXSpace.x4) {
            WelcomeHighlight(symbol: "text.alignleft", title: "完整排版",
                             detail: "标题、列表、引用、代码和表格按原文保留")
            WelcomeHighlight(symbol: "photo.stack", title: "原图与视频",
                             detail: "按原文顺序保存，并逐项校验")
            WelcomeHighlight(symbol: "lock.shield", title: "只在本机",
                             detail: "登录信息仅在内存中使用，不上传")
        }
    }
}

private struct WelcomeStepRow<Accessory: View>: View {
    let symbol: String
    let title: String
    let detail: String
    let isReady: Bool
    @ViewBuilder var accessory: Accessory

    init(symbol: String, title: String, detail: String, isReady: Bool,
         @ViewBuilder accessory: () -> Accessory = { EmptyView() }) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.isReady = isReady
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: MarkXSpace.l) {
            MarkXIconTile(systemImage: symbol)
            VStack(alignment: .leading, spacing: MarkXSpace.xs) {
                Text(title).font(MarkXFont.headline)
                Text(detail)
                    .font(MarkXFont.meta)
                    .foregroundStyle(MarkXInterface.text2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
            HStack(spacing: MarkXSpace.s) {
                StatusDot(color: isReady ? .green : MarkXInterface.text3)
                Text(isReady ? "已就绪" : "待设置")
            }
            .font(MarkXFont.metaStrong)
            .foregroundStyle(isReady ? AnyShapeStyle(.primary) : AnyShapeStyle(MarkXInterface.text2))
            .fixedSize()
        }
        .padding(.horizontal, MarkXSpace.xl)
        .padding(.vertical, MarkXSpace.xl)
        .accessibilityElement(children: .contain)
    }
}

private struct WelcomeHighlight: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: MarkXSpace.s) {
            Image(systemName: symbol)
                .font(MarkXFont.headline)
                .foregroundStyle(MarkXInterface.text3)
                .frame(height: MarkXIcon.rowWidth, alignment: .leading)
                .accessibilityHidden(true)
            Text(title).font(MarkXFont.detailStrong)
            Text(detail)
                .font(MarkXFont.meta)
                .foregroundStyle(MarkXInterface.text2)
                .lineSpacing(MarkXSpace.xxs)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Deep, low-saturation wash: cool at the top, a faint warm glow at the bottom.
private struct WelcomeBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            MarkXInterface.canvas
            LinearGradient(
                colors: dark
                    ? [Color(red: 0.13, green: 0.14, blue: 0.17), Color(red: 0.10, green: 0.10, blue: 0.12)]
                    : [Color(red: 0.95, green: 0.96, blue: 0.98), Color(red: 0.98, green: 0.98, blue: 0.99)],
                startPoint: .top, endPoint: .bottom
            )
            RadialGradient(
                colors: [Color(red: 0.55, green: 0.25, blue: 0.22).opacity(dark ? 0.16 : 0.07), .clear],
                center: UnitPoint(x: 0.75, y: 1.05), startRadius: 0, endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}
