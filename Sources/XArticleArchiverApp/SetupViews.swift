@preconcurrency import AppKit
import SwiftUI
import XArticleArchiverCore

struct AddCreatorsView: View {
    private enum EntryMode: String, CaseIterable {
        case single = "单个博主"
        case batch = "批量博主"
        case articleLinks = "文章链接"
    }
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var mode: ArchiveMode = .recentWindow
    @State private var entryMode: EntryMode = .single
    @State private var articleLimit = 10
    @State private var refreshExistingLinks = false
    @State private var resolveTotalCount = false

    private var parsedHandles: [String] { HandleParser.parse(input) }
    private var parsedArticleLinks: [XArticleLink] { XArticleURLParser.parse(input) }
    private var canDownload: Bool {
        if !parsedArticleLinks.isEmpty { return parsedArticleLinks.count <= 500 }
        return entryMode == .single ? parsedHandles.count == 1 : entryMode == .batch && !parsedHandles.isEmpty
    }
    private var downloadTitle: String {
        if entryMode == .articleLinks && parsedArticleLinks.isEmpty { return "下载文章" }
        if !parsedArticleLinks.isEmpty { return "下载 \(parsedArticleLinks.count) 篇文章" }
        return mode == .recentWindow ? "下载最近 \(articleLimit) 篇" : "下载全部文章"
    }

    var body: some View {
        VStack(spacing: 0) {
            MarkXPaneHeader(title: model.downloadSheetPrefill.isEmpty ? "开始下载文章" : "重新拉取文章",
                subtitle: "选择来源与下载范围，完整文章会保存在你的 Mac。")
            ScrollView {
                VStack(alignment: .leading, spacing: MarkXInterface.spacing) {
                    Picker("添加方式", selection: $entryMode) {
                        ForEach(EntryMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented)
                    .help("选择输入单个博主、多个博主，或 X Article 链接")
                    inputSection
                    if entryMode != .articleLinks { rangeSection }
                    MarkXInfoLine(symbol: "checkmark.shield", text: "仅下载 X Article，保留正文排版、图片与视频。")
                }
                .padding(MarkXInterface.inset)
            }
            MarkXFooter(note: "已有完整归档默认跳过") {
                Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    .help("关闭窗口，不创建下载任务")
                Button(downloadTitle, action: startDownload)
                    .buttonStyle(.markxPillProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canDownload).frame(minWidth: 120)
                    .help("按所选范围加入后台下载队列")
            }
        }
        .background(MarkXInterface.canvas)
        .font(MarkXFont.body)
        .frame(width: 640, height: MarkXInterface.sheetHeight(610))
        .onAppear {
            input = model.downloadSheetPrefill
            entryMode = model.downloadSheetUsesArticleLinks ? .articleLinks : .single
        }
        .onChange(of: input) { _, value in
            if !XArticleURLParser.parse(value).isEmpty { entryMode = .articleLinks }
        }
        .onChange(of: entryMode) { _, value in
            if value == .single { input = SingleCreatorInputPolicy.sanitize(input) }
        }
    }

    @ViewBuilder private var inputSection: some View {
        switch entryMode {
        case .single:
            MarkXSection(title: "博主主页", detail: "输入用户名或 X 主页链接。") {
                StrictSingleLineTextField(text: Binding(get: { input }, set: { input = SingleCreatorInputPolicy.sanitize($0) }),
                    placeholder: "@username 或 https://x.com/username")
                    .frame(height: 20)
                    .padding(.horizontal, MarkXSpace.m + MarkXSpace.xxs)
                    .frame(height: 32)
                    .background(MarkXInterface.wash, in: RoundedRectangle(cornerRadius: MarkXRadius.control))
                    .help("只接受一行；粘贴多行时保留第一条非空内容")
                if let handle = parsedHandles.first {
                    MarkXInfoLine(symbol: "person.crop.circle.badge.checkmark", text: "已识别 @\(handle)")
                }
            }
        case .batch:
            MarkXSection(title: "博主列表", detail: "每行一位，支持 @用户名或主页链接。") {
                multilineInput(placeholder: "@username\nhttps://x.com/another_creator")
                Text("已识别 \(parsedHandles.count) 位博主")
                    .font(MarkXFont.meta).foregroundStyle(MarkXInterface.text2).monospacedDigit()
            }
        case .articleLinks:
            MarkXSection(title: "X Article 链接", detail: "每行一条，最多 500 条；重复链接会自动合并。") {
                multilineInput(placeholder: "https://x.com/username/status/…")
                Text("已识别 \(parsedArticleLinks.count) 条链接")
                    .font(MarkXFont.meta).monospacedDigit()
                    .foregroundStyle(parsedArticleLinks.count > 500 ? Color.red : MarkXInterface.text2)
                Rectangle().fill(MarkXInterface.hairline).frame(height: 1)
                Toggle("重新获取已归档文章", isOn: $refreshExistingLinks)
                    .font(MarkXFont.detail).help("重新打开原页并校验完整排版，手工修改的 Markdown 受到保护")
                if refreshExistingLinks {
                    Text("校验成功后更新本地归档，手工修改的正文不会被直接覆盖。")
                        .font(MarkXFont.meta).foregroundStyle(MarkXInterface.text2)
                }
            }
        }
    }

    private func multilineInput(placeholder: String) -> some View {
        TextEditor(text: $input)
            .font(MarkXFont.detail.monospaced())
            .scrollContentBackground(.hidden)
            .frame(height: 120).padding(MarkXSpace.m)
            .background(MarkXInterface.wash, in: RoundedRectangle(cornerRadius: MarkXRadius.control))
            .overlay(alignment: .topLeading) {
                if input.isEmpty {
                    Text(placeholder).font(MarkXFont.detail.monospaced()).foregroundStyle(MarkXInterface.text3)
                        .padding(MarkXSpace.l).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .accessibilityLabel(entryMode == .batch ? "博主列表" : "文章链接")
    }

    private var rangeSection: some View {
        MarkXSection(title: "下载范围") {
            Picker("归档范围", selection: $mode) {
                ForEach(ArchiveMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).help("选择最近文章或全部可见文章")
            if mode == .recentWindow {
                HStack {
                    Text("每位博主").font(MarkXFont.detail)
                    Spacer()
                    Menu("预设") {
                        ForEach([5, 10, 20, 50, 100], id: \.self) { value in
                            Button("最近 \(value) 篇") { articleLimit = value }
                        }
                    }
                    .fixedSize().help("快速选择每位博主的文章数量")
                    Stepper(value: $articleLimit, in: 1...100) {
                        Text("\(articleLimit) 篇").monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                    }
                    .fixedSize().help("每位博主下载最近 1–100 篇文章")
                }
                Divider()
                Toggle("同时刷新线上文章总数", isOn: $resolveTotalCount)
                    .font(MarkXFont.detail).help("扫描完整列表来更新总数，下载范围仍为最近指定数量")
                Text(resolveTotalCount ? "将额外扫描完整列表，所需时间更长。" : "优先读取最近文章；总数也可稍后单独刷新。")
                    .font(MarkXFont.meta).foregroundStyle(MarkXInterface.text2)
            } else {
                MarkXInfoLine(symbol: "text.page", text: "扫描到列表底部，下载全部可见文章，不受 100 篇限制。")
            }
        }
    }

    private func startDownload() {
        if !parsedArticleLinks.isEmpty {
            model.archiveArticleLinks(input: input, refreshExisting: refreshExistingLinks)
        } else {
            model.addAndArchiveCreators(input: input, mode: mode, articleLimit: articleLimit, resolveTotalCount: resolveTotalCount)
        }
    }
}

/// A native one-line field that intercepts paste before AppKit converts line
/// separators to spaces. SwiftUI's TextField is visually one line, but AppKit
/// can normalize a multi-line paste into one space-separated value before its
/// Binding setter sees it, which would silently accept multiple creators.
private struct StrictSingleLineTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> StrictSingleLineNSTextField {
        let field = StrictSingleLineNSTextField()
        field.delegate = context.coordinator
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: MarkXTypography.pointSize(13))
        // Fog's filled field: the wash and corners come from SwiftUI.
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.setAccessibilityLabel("博主主页")
        field.stringValue = SingleCreatorInputPolicy.sanitize(text)
        context.coordinator.installKeyboardGuard(for: field)
        return field
    }

    func updateNSView(_ field: StrictSingleLineNSTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = placeholder
        let sanitized = SingleCreatorInputPolicy.sanitize(text)
        if field.stringValue != sanitized {
            field.stringValue = sanitized
        }
    }

    static func dismantleNSView(_ field: StrictSingleLineNSTextField, coordinator: Coordinator) {
        coordinator.removeKeyboardGuard()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: StrictSingleLineTextField
        private weak var field: StrictSingleLineNSTextField?
        private var keyboardMonitor: Any?

        init(parent: StrictSingleLineTextField) {
            self.parent = parent
        }

        func installKeyboardGuard(for field: StrictSingleLineNSTextField) {
            self.field = field
            keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let coordinator = UnsafeSendableBox(self)
                let boxedEvent = UnsafeSendableBox(event)
                let shouldConsume: Bool = MainActor.assumeIsolated {
                    coordinator.value.consumeIfForbidden(boxedEvent.value)
                }
                return shouldConsume ? nil : event
            }
        }

        @MainActor
        private func consumeIfForbidden(_ event: NSEvent) -> Bool {
            guard let field,
                  let editor = field.currentEditor() as? NSTextView
            else { return false }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()
            if flags.contains(.command), key == "v",
               let pasted = NSPasteboard.general.string(forType: .string),
               pasted.components(separatedBy: .newlines).count > 1 {
                let sanitized = SingleCreatorInputPolicy.sanitize(pasted)
                if !sanitized.isEmpty {
                    editor.insertText(sanitized, replacementRange: editor.selectedRange())
                }
                return true
            }

            return event.keyCode == 36 || event.keyCode == 76
        }

        func removeKeyboardGuard() {
            if let keyboardMonitor {
                NSEvent.removeMonitor(keyboardMonitor)
                self.keyboardMonitor = nil
            }
        }

        deinit {
            removeKeyboardGuard()
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            let sanitized = SingleCreatorInputPolicy.sanitize(field.stringValue)
            if field.stringValue != sanitized {
                field.stringValue = sanitized
                field.currentEditor()?.selectedRange = NSRange(location: sanitized.utf16.count, length: 0)
            }
            if parent.text != sanitized {
                parent.text = sanitized
            }
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch NSStringFromSelector(commandSelector) {
            case "insertNewline:", "insertNewlineIgnoringFieldEditor:", "insertLineBreak:":
                return true
            case "paste:":
                guard let pasted = NSPasteboard.general.string(forType: .string) else { return false }
                let sanitized = SingleCreatorInputPolicy.sanitize(pasted)
                guard !sanitized.isEmpty else { return true }
                textView.insertText(sanitized, replacementRange: textView.selectedRange())
                return true
            default:
                return false
            }
        }
    }
}

private final class StrictSingleLineNSTextField: NSTextField {}

/// AppKit invokes local key monitors on the main thread, but the SDK callback
/// is not annotated `@MainActor`. This narrow wrapper lets us state that runtime
/// guarantee while keeping all AppKit access inside `MainActor.assumeIsolated`.
private struct UnsafeSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

struct ConnectionSetupView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            MarkXPaneHeader(title: "连接与存储", subtitle: "管理浏览器会话、归档位置，以及图片和视频的保存方式。")
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: MarkXInterface.spacing) {
                        MarkXSection(title: "归档位置", detail: "Markdown、原图、视频与资料库会一起保存。") {
                            ArchiveFolderRow()
                        }.id("archive-directory")
                        MarkXSection(title: "浏览器与 X 登录") { BrowserConnectionConfiguration() }.id("browser-session")
                        MarkXSection(title: "媒体存储") { MediaStorageConfiguration() }.id("image-host")
                        MarkXInfoLine(symbol: "lock.shield", text: "正文在本机转换，访问密钥仅保存在 macOS 钥匙串。")
                    }
                    .padding(MarkXInterface.inset)
                }
                .onAppear {
                    let target: String? = switch model.connectionSetupTarget {
                    case .overview: nil
                    case .browser: "browser-session"
                    case .imageHost: "image-host"
                    }
                    if let target {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(100))
                            proxy.scrollTo(target, anchor: .top)
                        }
                    }
                }
            }
            MarkXFooter(note: "配置保存在这台 Mac") {
                Button("完成") { dismiss() }
                    .buttonStyle(.markxPillProminent).keyboardShortcut(.defaultAction)
                    .help("关闭连接与存储配置")
            }
        }
        .background(MarkXInterface.canvas)
        .font(MarkXFont.body)
        .frame(width: 680, height: MarkXInterface.sheetHeight(660))
        .onExitCommand { dismiss() }
    }
}

private struct BrowserConnectionConfiguration: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isChecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: MarkXSpace.l) {
            Picker("使用浏览器", selection: $model.preferredBrowserID) {
                Text("自动查找已登录的配置").tag("automatic")
                ForEach(BrowserSessionDefinition.supported, id: \.id) { Text($0.name).tag($0.id) }
            }
            .disabled(isChecking)
            MarkXInfoLine(symbol: model.hasBrowserSessionData ? "checkmark.circle" : "exclamationmark.circle",
                text: model.isRefreshingBrowserStatus ? "正在检查本机浏览器的 X 登录记录…" : model.browserSessionProbe.summary,
                color: model.hasBrowserSessionData ? .green : .orange)
            if let browser = model.browserNameNeedingAccess {
                VStack(alignment: .leading, spacing: MarkXSpace.m) {
                    Text("macOS 默认不允许其他应用读取 \(browser) 的数据。点下面的按钮，在弹出的窗口里直接点「允许读取」即可，只需授权一次。")
                        .font(MarkXFont.meta).foregroundStyle(MarkXInterface.text2)
                        .lineSpacing(MarkXSpace.xxs)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("授权读取 \(browser)…") { model.chooseBrowserDataDirectory() }
                        .buttonStyle(.markxCompactProminent)
                        .disabled(isChecking)
                }
            }
            MarkXFlowLayout(spacing: MarkXSpace.m) {
                Button(isChecking ? "正在验证…" : "验证会话读取", systemImage: "checkmark.shield") {
                    isChecking = true
                    Task { await model.verifyBrowserSession(); isChecking = false }
                }
                .disabled(isChecking || model.isRefreshingBrowserStatus)
                .help("仅在本机解密并验证 X 登录数据，不发起下载或修改浏览器")
                Button("刷新状态", systemImage: "arrow.clockwise") { model.refreshBrowserStatus() }
                    .disabled(model.isRefreshingBrowserStatus || isChecking)
                    .help("重新检查全部受支持的浏览器与配置")
                Button("选择其他数据目录…", systemImage: "folder") { model.chooseBrowserDataDirectory() }
                    .disabled(isChecking)
                    .help("为自定义目录或 macOS 读取受限的目录保存访问授权")
                Button("在浏览器打开 X", systemImage: "arrow.up.right") { model.openBrowserXLogin() }
            }
            .buttonStyle(.markxCompact)
            if let message = model.browserSessionCheckMessage {
                Text(message).font(MarkXFont.meta).foregroundStyle(MarkXInterface.text2).textSelection(.enabled)
            }
            if !model.browserSessionProbe.profiles.isEmpty {
                DisclosureGroup("检测到的配置（\(model.browserSessionProbe.profiles.count)）") {
                    VStack(alignment: .leading, spacing: MarkXSpace.s) {
                        ForEach(model.browserSessionProbe.profiles) { profile in
                            Text(profile.description + (profile.hasLoginCookies ? " · 有 X 登录数据" : " · 未检测到 X 登录数据"))
                                .font(MarkXFont.meta).foregroundStyle(MarkXInterface.text2)
                        }
                    }.padding(.top, MarkXSpace.m)
                }.font(MarkXFont.detail)
            }
            Text("兼容 Chrome、Edge、Brave、Arc、Vivaldi、Opera、Chromium、夸克、豆包及 Firefox。仅读取 X 会话，不保存密码或 Cookie。Safari 暂不支持自动导入。")
                .font(MarkXFont.meta).foregroundStyle(MarkXInterface.text3)
                .lineSpacing(MarkXSpace.xxs)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.refreshBrowserStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshBrowserStatus() }
        }
    }
}

private struct ArchiveFolderRow: View {
    @EnvironmentObject private var model: AppViewModel
    var body: some View {
        HStack(alignment: .center, spacing: MarkXSpace.l) {
            MarkXIconTile(systemImage: "folder")
            VStack(alignment: .leading, spacing: MarkXSpace.xxs) {
                Text(model.archiveRoot?.lastPathComponent ?? "尚未选择归档目录").font(MarkXFont.headline)
                Text(model.archiveRoot?.path ?? "选择一个你方便管理和备份的文件夹")
                    .font(MarkXFont.meta).foregroundStyle(MarkXInterface.text2)
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(model.archiveRoot?.path ?? "尚未选择")
            Button(model.archiveRoot == nil ? "选择目录…" : "更换…") { model.chooseArchiveFolder() }
                .buttonStyle(.markxCompact)
                .disabled(model.isRunning || model.hasActiveDownloadProgress)
                .help("同步现有资料后切换归档位置，旧目录保留")
        }
    }
}

struct MediaStorageConfiguration: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var isTestingUPic = false
    @State private var isTestingS3 = false
    @State private var showsAdvanced = false
    @State private var confirmsRemovingKeys = false
    private var isTesting: Bool { isTestingUPic || isTestingS3 }

    var body: some View {
        VStack(alignment: .leading, spacing: MarkXSpace.xl) {
            Picker("存储方式", selection: Binding(get: { model.imageHostChoice }, set: { model.selectImageHost($0) })) {
                Text("本地存储").tag(AppViewModel.ImageHostChoice.local)
                Text("本地 + uPic").tag(AppViewModel.ImageHostChoice.uPic)
                Text("S3 / R2").tag(AppViewModel.ImageHostChoice.s3)
            }
            .labelsHidden().pickerStyle(.segmented).disabled(isTesting)
            .help("选择本地保存，或同时使用外部媒体存储")
            Group {
                switch model.imageHostChoice {
                case .local:
                    MarkXInfoLine(symbol: "internaldrive", text: "无需额外配置。原图和视频保存在归档目录内，整个目录可以一起移动或备份。")
                case .uPic:
                    VStack(alignment: .leading, spacing: MarkXSpace.l) {
                        Text("使用 uPic 当前选择的默认图床，原图和视频仍保留本地备份。")
                            .font(MarkXFont.detail).foregroundStyle(MarkXInterface.text2)
                        MarkXInfoLine(symbol: model.upicCapability.isAvailable ? "checkmark.circle" : "exclamationmark.circle",
                            text: model.upicCapability.detail, color: model.upicCapability.isAvailable ? .green : .orange)
                        Button(isTestingUPic ? "正在验证…" : "验证 uPic 连接") {
                            isTestingUPic = true
                            Task { _ = await model.testUPic(); isTestingUPic = false }
                        }
                        .buttonStyle(.markxCompact)
                        .disabled(!model.upicCapability.isAvailable || isTesting)
                        .help("上传一张无隐私测试图片，并检查返回的 HTTPS 地址")
                        Text("验证会上传一张无隐私测试图片；本应用不读取 uPic 密钥。")
                            .font(MarkXFont.meta).foregroundStyle(MarkXInterface.text2)
                    }
                case .s3: s3Fields
                }
            }
            Rectangle().fill(MarkXInterface.hairline).frame(height: 1)
            HStack(spacing: MarkXSpace.m) {
                if isTesting { ProgressView().controlSize(.mini) }
                else {
                    StatusDot(color: model.imageHostVerified ? .green : .orange)
                }
                Text(isTesting ? "正在检查媒体上传与公开访问…" : model.imageHostDetail)
                    .font(MarkXFont.meta).foregroundStyle(MarkXInterface.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("移除已保存的 S3 / R2 密钥？", isPresented: $confirmsRemovingKeys, titleVisibility: .visible) {
            Button("移除密钥", role: .destructive) { model.removeS3Credentials() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("之后需要重新填写密钥才能上传。已有文章、本地媒体和远程文件会保留。")
        }
    }

    private var s3Fields: some View {
        VStack(alignment: .leading, spacing: MarkXSpace.l) {
            field("Endpoint", placeholder: "https://<account>.r2.cloudflarestorage.com", text: $model.s3Endpoint)
            HStack(alignment: .top, spacing: MarkXSpace.l) {
                field("存储桶 · Bucket", placeholder: "my-bucket", text: $model.s3Bucket)
                field("公开访问地址", placeholder: "https://img.example.com", text: $model.s3PublicBaseURL)
            }
            HStack(alignment: .top, spacing: MarkXSpace.l) {
                VStack(alignment: .leading, spacing: MarkXSpace.s) {
                    Text("Access Key").font(MarkXFont.metaStrong).foregroundStyle(MarkXInterface.text2)
                    SecureField(model.hasS3Credentials ? "留空使用已保存值" : "输入 Access Key", text: $accessKey)
                        .markxField().accessibilityLabel("Access Key")
                }
                VStack(alignment: .leading, spacing: MarkXSpace.s) {
                    Text("Secret Key").font(MarkXFont.metaStrong).foregroundStyle(MarkXInterface.text2)
                    SecureField(model.hasS3Credentials ? "留空使用已保存值" : "输入 Secret Key", text: $secretKey)
                        .markxField().accessibilityLabel("Secret Key")
                }
            }
            DisclosureGroup("高级选项", isExpanded: $showsAdvanced) {
                HStack(alignment: .top, spacing: MarkXSpace.l) {
                    field("Region", placeholder: "R2 使用 auto", text: $model.s3Region)
                    field("对象路径前缀", placeholder: "x-archive", text: $model.s3KeyPrefix)
                }.padding(.top, MarkXSpace.m)
            }
            .font(MarkXFont.detail).help("查看区域和对象路径前缀")
            HStack(spacing: MarkXSpace.m) {
                Button(isTestingS3 ? "正在验证…" : "保存并验证连接") {
                    isTestingS3 = true
                    Task {
                        if await model.saveAndTestS3(accessKey: accessKey, secretKey: secretKey) { accessKey = ""; secretKey = "" }
                        isTestingS3 = false
                    }
                }
                .disabled(isTesting || model.s3Endpoint.isEmpty || model.s3PublicBaseURL.isEmpty)
                .buttonStyle(.markxCompactProminent)
                .help("将凭证保存到钥匙串，并上传测试图片验证公开访问")
                Spacer()
                if model.hasS3Credentials {
                    Button("移除密钥…", role: .destructive) { confirmsRemovingKeys = true }
                        .buttonStyle(.markxText)
                        .disabled(isTesting).help("移除本机保存的 S3 / R2 凭证")
                }
            }
        }
        .controlSize(.regular)
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: MarkXSpace.s) {
            Text(title).font(MarkXFont.metaStrong).foregroundStyle(MarkXInterface.text2)
            TextField(placeholder, text: text).markxField().accessibilityLabel(title)
                .onChange(of: text.wrappedValue) { _, _ in model.invalidateImageHostVerification() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var tab = 0

    // HIG settings: native toolbar tabs and grouped forms; the tab name is the
    // title, so panes don't repeat it in a custom header.
    var body: some View {
        TabView(selection: $tab) {
            Form {
                Section {
                    ArchiveFolderRow()
                } header: {
                    Text("本地资料库")
                } footer: {
                    Text("Markdown、原图、视频与资料库数据库都保存在这个文件夹。")
                        .font(MarkXFont.detail).foregroundStyle(MarkXInterface.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                SoftwareUpdateSettingsSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("通用", systemImage: "gearshape") }.tag(0)

            Form {
                Section {
                    BrowserConnectionConfiguration()
                } header: {
                    Text("浏览器与 X 登录")
                } footer: {
                    Text("下载在后台进行，文章只保存在你选择的位置。")
                        .font(MarkXFont.detail).foregroundStyle(MarkXInterface.text2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("X 登录", systemImage: "person.badge.key") }.tag(1)

            Form {
                Section("媒体存储") { MediaStorageConfiguration() }
                Section {
                    LabeledContent {
                        Button("整理…") { model.cleanVerifiedMediaCache() }
                            .buttonStyle(.markxCompact)
                            .disabled(model.isRunning || model.hasActiveDownloadProgress || model.archiveRoot == nil)
                            .help("核对内容后移除已有完整备份的重复缓存")
                    } label: {
                        Text("重复媒体缓存")
                        Text("保留完整媒体备份，只移除已经重复保存的隐藏缓存。")
                    }
                } header: {
                    Text("缓存管理")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("存储", systemImage: "externaldrive") }.tag(2)

            Form {
                Section("隐私") {
                    privacyRow("本机转换", detail: "正文在本机解析与保存，不交给 AI，也不上传诊断日志。", symbol: "desktopcomputer")
                    privacyRow("会话仅在内存使用", detail: "仅读取所选浏览器中必需的 X 会话，不读取其他网站的登录信息。", symbol: "key")
                    privacyRow("外部存储由你选择", detail: "只有选择并验证图床后，图片与视频才会发送到对应存储。", symbol: "externaldrive.badge.checkmark")
                }
                Section("关于 MarkX") {
                    LabeledContent("版本", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版本") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
                    LabeledContent("版权", value: "© 2026 得否")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("隐私与关于", systemImage: "hand.raised") }.tag(3)
        }
        .font(MarkXFont.body)
        .frame(width: 640, height: 520)
    }

    private func privacyRow(_ title: String, detail: String, symbol: String) -> some View {
        Label {
            Text(title)
            Text(detail)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }
}
