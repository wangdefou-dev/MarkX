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
    // Nothing is preselected: the user picks a source and a range first.
    @State private var mode: ArchiveMode?
    @State private var entryMode: EntryMode?
    @State private var articleLimit = 10
    @State private var refreshExistingLinks = false
    @State private var resolveTotalCount = false

    private var parsedHandles: [String] { HandleParser.parse(input) }
    private var parsedArticleLinks: [XArticleLink] { XArticleURLParser.parse(input) }
    private var canDownload: Bool {
        if !parsedArticleLinks.isEmpty { return parsedArticleLinks.count <= 500 }
        guard mode != nil else { return false }
        return entryMode == .single ? parsedHandles.count == 1 : entryMode == .batch && !parsedHandles.isEmpty
    }
    private var downloadTitle: String {
        if entryMode == .articleLinks && parsedArticleLinks.isEmpty { return "下载文章" }
        if !parsedArticleLinks.isEmpty { return "下载 \(parsedArticleLinks.count) 篇文章" }
        switch mode {
        case .recentWindow: return "下载最近 \(articleLimit) 篇"
        case .fullArchive: return "下载全部文章"
        default: return "下载文章"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            MarkXPaneHeader(title: model.downloadSheetPrefill.isEmpty ? "下载文章" : "重新拉取文章",
                            onClose: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: MarkXSpace.x3) {
                    sourceSection
                    inputSection
                    if entryMode == .single || entryMode == .batch { rangeSection }
                }
                .padding(.horizontal, MarkXInterface.inset)
                .padding(.bottom, MarkXInterface.inset)
            }
            MarkXFooter {
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
        .frame(width: 660, height: MarkXInterface.sheetHeight(660))
        .onAppear {
            input = model.downloadSheetPrefill
            // A prefilled sheet (re-pull a creator, pasted links) already
            // implies its source; a fresh one starts with nothing chosen.
            if model.downloadSheetUsesArticleLinks {
                entryMode = .articleLinks
            } else if !model.downloadSheetPrefill.isEmpty {
                entryMode = .single
            }
        }
        .onChange(of: input) { _, value in
            if !XArticleURLParser.parse(value).isEmpty { entryMode = .articleLinks }
        }
        .onChange(of: entryMode) { _, value in
            if value == .single { input = SingleCreatorInputPolicy.sanitize(input) }
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(MarkXFont.detailStrong)
            .foregroundStyle(MarkXInterface.text2)
            .padding(.horizontal, MarkXSpace.xs)
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: MarkXSpace.m) {
            sectionLabel("下载来源")
            HStack(alignment: .top, spacing: MarkXSpace.m) {
                MarkXChoiceCard(title: "单个博主", systemImage: "person",
                                isSelected: entryMode == .single) { entryMode = .single }
                MarkXChoiceCard(title: "批量博主", systemImage: "person.2",
                                isSelected: entryMode == .batch) { entryMode = .batch }
                MarkXChoiceCard(title: "文章链接", systemImage: "link",
                                isSelected: entryMode == .articleLinks) { entryMode = .articleLinks }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var inputSection: some View {
        switch entryMode {
        case nil:
            EmptyView()
        case .single:
            MarkXGroup(title: "博主主页") {
                MarkXRowContent {
                    StrictSingleLineTextField(text: Binding(get: { input }, set: { input = SingleCreatorInputPolicy.sanitize($0) }),
                        placeholder: "@username 或 https://x.com/username")
                        .frame(height: 20)
                        .padding(.horizontal, MarkXSpace.m + MarkXSpace.xxs)
                        .frame(height: 34)
                        .background(MarkXInterface.wash, in: RoundedRectangle(cornerRadius: MarkXRadius.control))
                        .help("只接受一行；粘贴多行时保留第一条非空内容")
                    recognizedLine(parsedHandles.first.map { "已识别 @\($0)" } ?? "等待输入博主",
                                   ok: parsedHandles.count == 1)
                }
            }
        case .batch:
            MarkXGroup(title: "博主列表（每行一位）") {
                MarkXRowContent {
                    multilineInput(placeholder: "@username\nhttps://x.com/another_creator")
                    recognizedLine("已识别 \(parsedHandles.count) 位博主", ok: !parsedHandles.isEmpty)
                }
            }
        case .articleLinks:
            MarkXGroup(title: "文章链接（每行一条，最多 500 条）") {
                MarkXRowContent {
                    multilineInput(placeholder: "https://x.com/username/status/…")
                    recognizedLine("已识别 \(parsedArticleLinks.count) 条链接",
                                   ok: !parsedArticleLinks.isEmpty && parsedArticleLinks.count <= 500,
                                   warning: parsedArticleLinks.count > 500)
                }
                MarkXRow(title: "重新获取已归档文章") {
                    Toggle("重新获取已归档文章", isOn: $refreshExistingLinks)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .help("重新打开原页并校验完整排版，手工修改的 Markdown 受到保护")
            }
        }
    }

    private func recognizedLine(_ text: String, ok: Bool, warning: Bool = false) -> some View {
        HStack(spacing: MarkXSpace.s) {
            StatusDot(color: warning ? .red : ok ? .green : MarkXInterface.text3)
            Text(text).monospacedDigit()
        }
        .font(MarkXFont.meta)
        .foregroundStyle(warning ? Color.red : MarkXInterface.text2)
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
        VStack(alignment: .leading, spacing: MarkXSpace.m) {
            sectionLabel("下载范围")
            HStack(alignment: .top, spacing: MarkXSpace.m) {
                MarkXChoiceCard(title: "最近文章", systemImage: "clock",
                                isSelected: mode == .recentWindow) { mode = .recentWindow }
                MarkXChoiceCard(title: "全部文章", systemImage: "square.stack",
                                isSelected: mode == .fullArchive) { mode = .fullArchive }
            }
            .fixedSize(horizontal: false, vertical: true)
            if mode == .recentWindow {
                MarkXGroup {
                    MarkXRow(title: "每位博主") {
                        HStack(spacing: MarkXSpace.s) {
                            ForEach([5, 10, 20, 50, 100], id: \.self) { value in
                                Button("\(value)") { articleLimit = value }
                                    .buttonStyle(MarkXCompactButtonStyle(prominent: articleLimit == value))
                                    .monospacedDigit()
                                    .help("最近 \(value) 篇")
                            }
                            Stepper(value: $articleLimit, in: 1...100) {
                                Text("\(articleLimit) 篇").monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                            }
                            .fixedSize().help("每位博主下载最近 1–100 篇文章")
                            .padding(.leading, MarkXSpace.xs)
                        }
                    }
                    MarkXRow(title: "同时刷新线上文章总数") {
                        Toggle("同时刷新线上文章总数", isOn: $resolveTotalCount)
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    }
                    .help("扫描完整列表来更新总数，下载范围仍为最近指定数量")
                }
            }
        }
    }

    private func startDownload() {
        if !parsedArticleLinks.isEmpty {
            model.archiveArticleLinks(input: input, refreshExisting: refreshExistingLinks)
        } else {
            guard let mode else { return }
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
            MarkXPaneHeader(title: "连接与存储")
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: MarkXSpace.x3) {
                        MediaStorageConfiguration().id("image-host")
                        MarkXGroup(title: "本地文件夹") {
                            ArchiveFolderRow()
                        }.id("archive-directory")
                        BrowserConnectionConfiguration().id("browser-session")
                    }
                    .padding(.horizontal, MarkXInterface.inset)
                    .padding(.bottom, MarkXInterface.inset)
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
            MarkXFooter {
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

/// Browser session settings as one group of rows: which browser, its state,
/// and one action per row.
private struct BrowserConnectionConfiguration: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isChecking = false

    var body: some View {
        MarkXGroup(title: "浏览器与 X 登录",
                   footer: "支持 Chrome、Edge、Arc、Brave、Firefox 等，暂不支持 Safari。") {
            MarkXRow(title: "使用浏览器", symbol: "globe") {
                Picker("使用浏览器", selection: $model.preferredBrowserID) {
                    Text("自动查找（最近使用的登录）").tag(BrowserSessionSelection.automaticID)
                    let logins = model.browserSessionProbe.loggedInProfiles
                    if !logins.isEmpty {
                        Section("检测到的 X 登录") {
                            ForEach(logins) { Text($0.description).tag($0.selectionID) }
                        }
                    }
                    if let missing = missingSelectionLabel(logins: logins) {
                        Text(missing).tag(model.preferredBrowserID)
                    }
                    let browsers = detectedBrowsers
                    if !browsers.isEmpty {
                        Section("按浏览器") {
                            ForEach(browsers, id: \.id) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                .labelsHidden().fixedSize()
                .disabled(isChecking)
            }
            MarkXRow(title: model.hasBrowserSessionData ? "已找到 X 登录" : "未找到 X 登录",
                     detail: model.isRefreshingBrowserStatus ? "正在检查本机浏览器的 X 登录记录…" : model.browserSessionProbe.summary,
                     symbol: model.hasBrowserSessionData ? "checkmark.circle" : "exclamationmark.circle",
                     symbolColor: model.hasBrowserSessionData ? .green : .orange) {
                Button("刷新", systemImage: "arrow.clockwise") { model.refreshBrowserStatus() }
                    .buttonStyle(.markxCompact)
                    .disabled(model.isRefreshingBrowserStatus || isChecking)
                    .help("重新检查全部受支持的浏览器与配置")
            }
            if let browser = model.browserNameNeedingAccess {
                MarkXRow(title: "授权读取 \(browser)",
                         detail: "在弹出窗口中选择「允许读取」，只需一次。",
                         symbol: "key", symbolColor: .orange) {
                    Button("授权…") { model.chooseBrowserDataDirectory() }
                        .buttonStyle(.markxCompactProminent)
                        .disabled(isChecking)
                }
            }
            MarkXRow(title: "验证会话读取",
                     detail: model.browserSessionCheckMessage,
                     symbol: "checkmark.shield") {
                Button(isChecking ? "正在验证…" : "验证") {
                    isChecking = true
                    Task { await model.verifyBrowserSession(); isChecking = false }
                }
                .buttonStyle(.markxCompact)
                .disabled(isChecking || model.isRefreshingBrowserStatus)
            }
            .textSelection(.enabled)
            MarkXRow(title: "其他数据目录", symbol: "folder") {
                Button("选择…") { model.chooseBrowserDataDirectory() }
                    .buttonStyle(.markxCompact)
                    .disabled(isChecking)
            }
            MarkXRow(title: "登录 X", symbol: "person.crop.circle") {
                Button("打开 X", systemImage: "arrow.up.right") { model.openBrowserXLogin() }
                    .buttonStyle(.markxCompact)
            }
            if !model.browserSessionProbe.profiles.isEmpty {
                MarkXRowContent {
                    DisclosureGroup("检测到的配置（\(model.browserSessionProbe.profiles.count)）") {
                        VStack(alignment: .leading, spacing: MarkXSpace.s) {
                            ForEach(model.browserSessionProbe.profiles) { profile in
                                HStack(spacing: MarkXSpace.s) {
                                    StatusDot(color: profile.hasLoginCookies ? .green : MarkXInterface.text3)
                                    Text(profile.description + (profile.hasLoginCookies ? " · 有 X 登录数据" : " · 未检测到 X 登录数据"))
                                }
                                .font(MarkXFont.meta).foregroundStyle(MarkXInterface.text2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, MarkXSpace.m)
                    }
                    .font(MarkXFont.detail)
                }
            }
        }
        .onAppear { model.refreshBrowserStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshBrowserStatus() }
        }
    }

    /// Browsers found on this Mac, plus the chosen one if it is not found.
    private var detectedBrowsers: [BrowserSessionDefinition] {
        var result: [BrowserSessionDefinition] = []
        for profile in model.browserSessionProbe.profiles where !result.contains(where: { $0.id == profile.browser.id }) {
            result.append(profile.browser)
        }
        let selection = BrowserSessionSelection(model.preferredBrowserID)
        if let id = selection.browserID, !result.contains(where: { $0.id == id }),
           let chosen = BrowserSessionDefinition.supported.first(where: { $0.id == id }) {
            result.append(chosen)
        }
        return result
    }

    /// A pinned profile that no longer has a login still needs a menu item,
    /// or the picker would show an empty selection.
    private func missingSelectionLabel(logins: [BrowserSessionProfile]) -> String? {
        let selection = BrowserSessionSelection(model.preferredBrowserID)
        guard let browserID = selection.browserID, selection.profileDirectory != nil,
              !logins.contains(where: { $0.selectionID == model.preferredBrowserID }) else { return nil }
        let browser = BrowserSessionDefinition.supported.first { $0.id == browserID }?.name ?? browserID
        return "\(browser) · \(selection.profileDirectory ?? "")（未检测到登录）"
    }
}

private struct ArchiveFolderRow: View {
    @EnvironmentObject private var model: AppViewModel
    var body: some View {
        HStack(alignment: .center, spacing: MarkXSpace.l) {
            MarkXIconTile(systemImage: "folder")
            VStack(alignment: .leading, spacing: MarkXSpace.xxs + 1) {
                Text(model.archiveRoot?.lastPathComponent ?? "尚未选择").font(MarkXFont.body)
                    .lineLimit(1).truncationMode(.middle)
                Text(model.archiveRoot.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "—")
                    .font(MarkXFont.detail).foregroundStyle(MarkXInterface.text2)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(model.archiveRoot?.path ?? "尚未选择")
            HStack(spacing: MarkXSpace.s) {
                if let root = model.archiveRoot {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([root]) }
                        .buttonStyle(.markxCompact)
                }
                Button(model.archiveRoot == nil ? "选择…" : "移动…") { model.chooseArchiveFolder() }
                    .buttonStyle(.markxCompact)
                    .disabled(model.isRunning || model.hasActiveDownloadProgress)
                    .help(model.archiveRoot == nil ? "选择保存文章的文件夹" : "把资料移动到另一个文件夹")
            }
        }
        .padding(.horizontal, MarkXSpace.xl)
        .padding(.vertical, MarkXSpace.l)
    }
}

/// Media storage as one group: the choice, its configuration, its state.
struct MediaStorageConfiguration: View {
    @EnvironmentObject private var model: AppViewModel
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var isTestingUPic = false
    @State private var isTestingS3 = false
    @State private var showsAdvanced = false
    @State private var confirmsRemovingKeys = false
    /// A different storage method waiting for the user's confirmation.
    @State private var pendingChoice: AppViewModel.ImageHostChoice?
    /// The choices are open after “更换…”.
    @State private var isChoosing = false
    private static let choices: [AppViewModel.ImageHostChoice] = [.local, .uPic, .s3]
    private var isTesting: Bool { isTestingUPic || isTestingS3 }

    private static func name(_ choice: AppViewModel.ImageHostChoice) -> String {
        switch choice {
        case .local: "本地"
        case .uPic: "uPic"
        case .s3: "S3 / R2"
        }
    }

    private static func symbol(_ choice: AppViewModel.ImageHostChoice) -> String {
        switch choice {
        case .local: "internaldrive"
        case .uPic: "icloud.and.arrow.up"
        case .s3: "server.rack"
        }
    }

    private func pick(_ choice: AppViewModel.ImageHostChoice) {
        if !model.isImageHostConfigured {
            model.selectImageHost(choice)
        } else if choice == model.imageHostChoice {
            isChoosing = false
        } else {
            pendingChoice = choice
        }
    }

    private var choiceCards: some View {
        MarkXRowContent {
            HStack(alignment: .top, spacing: MarkXSpace.m) {
                ForEach(Self.choices, id: \.self) { choice in
                    MarkXChoiceCard(title: Self.name(choice), systemImage: Self.symbol(choice),
                                    isSelected: model.isImageHostConfigured && model.imageHostChoice == choice) { pick(choice) }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .disabled(isTesting)
            if isChoosing {
                Button("取消") { isChoosing = false }
                    .buttonStyle(.markxText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    var body: some View {
        MarkXGroup(title: "存储方式") {
            if !model.isImageHostConfigured || isChoosing {
                choiceCards
            } else {
                MarkXRow(title: Self.name(model.imageHostChoice), symbol: Self.symbol(model.imageHostChoice)) {
                    Button("更换…") { isChoosing = true }
                        .buttonStyle(.markxCompact)
                        .disabled(isTesting)
                }
            }
            if model.isImageHostConfigured && !isChoosing {
                configuration
            }
        }
        .confirmationDialog(
            pendingChoice.map { $0 == .local ? "改为本地存储？" : "改用 \(Self.name($0)) 存储？" } ?? "",
            isPresented: Binding(get: { pendingChoice != nil }, set: { if !$0 { pendingChoice = nil } }),
            titleVisibility: .visible,
            presenting: pendingChoice
        ) { choice in
            Button("切换") { model.selectImageHost(choice); pendingChoice = nil; isChoosing = false }
            Button("取消", role: .cancel) { pendingChoice = nil }
        } message: { _ in
            Text("之后的新文章按新方式保存，已保存的不变。")
        }
        .confirmationDialog("移除已保存的 S3 / R2 密钥？", isPresented: $confirmsRemovingKeys, titleVisibility: .visible) {
            Button("移除密钥", role: .destructive) { model.removeS3Credentials() }
            Button("取消", role: .cancel) { }
        }
    }

    @ViewBuilder private var configuration: some View {
        switch model.imageHostChoice {
        case .local:
            EmptyView()
        case .uPic:
            MarkXRow(title: model.upicCapability.isAvailable ? "已找到 uPic" : "未找到 uPic",
                     detail: model.upicCapability.isAvailable ? nil : model.upicCapability.detail,
                     symbol: model.upicCapability.isAvailable ? "checkmark.circle" : "exclamationmark.circle",
                     symbolColor: model.upicCapability.isAvailable ? .green : .orange) {
                Button(isTestingUPic ? "正在验证…" : "验证连接") {
                    isTestingUPic = true
                    Task { _ = await model.testUPic(); isTestingUPic = false }
                }
                .buttonStyle(.markxCompact)
                .disabled(!model.upicCapability.isAvailable || isTesting)
                .help("上传一张无隐私测试图片，并检查返回的 HTTPS 地址")
            }
        case .s3:
            MarkXRowContent { s3Fields }
        }
        HStack(spacing: MarkXSpace.m) {
            if isTesting { ProgressView().controlSize(.mini) }
            else { StatusDot(color: model.imageHostVerified ? .green : .orange) }
            Text(isTesting ? "正在检查媒体上传与公开访问…" : model.imageHostDetail)
                .font(MarkXFont.detail).foregroundStyle(MarkXInterface.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, MarkXSpace.xl)
        .padding(.vertical, MarkXSpace.l)
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

/// Settings window: a quiet navigation column on the left (Fog / System
/// Settings layout) and grouped cards of rows on the right.
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, x, storage, about
        var id: Self { self }

        var title: String {
            switch self {
            case .general: "通用"
            case .x: "X 登录"
            case .storage: "存储"
            case .about: "隐私与关于"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .x: "person.badge.key"
            case .storage: "externaldrive"
            case .about: "hand.raised"
            }
        }
    }

    @EnvironmentObject private var model: AppViewModel
    @State private var pane: Pane = .general

    var body: some View {
        HStack(spacing: 0) {
            navigation
            ScrollView {
                VStack(alignment: .leading, spacing: MarkXSpace.x3) {
                    content
                }
                .padding(.horizontal, MarkXSpace.x3)
                .padding(.top, MarkXSpace.x3)
                .padding(.bottom, MarkXSpace.x3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(pane)
            .background(MarkXInterface.canvas)
        }
        .font(MarkXFont.body)
        .frame(width: 680, height: 500)
        .navigationTitle(pane.title)
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: MarkXSpace.xxs) {
            ForEach(Pane.allCases) { item in
                Button { pane = item } label: {
                    HStack(spacing: MarkXSpace.m + MarkXSpace.xxs) {
                        Image(systemName: item.symbol)
                            .foregroundStyle(MarkXInterface.text2)
                            .frame(width: MarkXIcon.rowWidth)
                        Text(item.title)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .font(pane == item ? MarkXFont.headline : MarkXFont.body)
                    .padding(.horizontal, MarkXSpace.m + MarkXSpace.xxs)
                    .frame(height: 34)
                    .markxHover(isSelected: pane == item)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(pane == item ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MarkXSpace.m + MarkXSpace.xxs)
        .padding(.top, MarkXSpace.l)
        .frame(width: 168)
        // Darker than the content pane, like the main window's sidebar;
        // the two panes are told apart by tone, not a divider line.
        .background(MarkXInterface.sidebarGradient)
    }

    @ViewBuilder private var content: some View {
        switch pane {
        case .general:
            SoftwareUpdateSettingsSection()
            MarkXGroup(title: "诊断与反馈", footer: "日志只存在本机；报告不含登录信息、密钥和正文。") {
                MarkXRow(title: "导出诊断报告", symbol: "stethoscope") {
                    Button("导出…") { Task { await DiagnosticReport.export(model: model) } }
                        .buttonStyle(.markxCompact)
                }
                MarkXRow(title: "反馈问题", symbol: "exclamationmark.bubble") {
                    Button("反馈…") { Task { await DiagnosticReport.reportProblem(model: model) } }
                        .buttonStyle(.markxCompact)
                }
                MarkXRow(title: "运行日志", symbol: "doc.text.magnifyingglass") {
                    Button("显示") { DiagnosticReport.revealLogs() }
                        .buttonStyle(.markxCompact)
                }
            }
        case .x:
            BrowserConnectionConfiguration()
        case .storage:
            MediaStorageConfiguration()
            MarkXGroup(title: "本地文件夹") {
                ArchiveFolderRow()
            }
            MarkXGroup(title: "缓存") {
                MarkXRow(title: "整理重复媒体缓存", symbol: "trash") {
                    Button("整理…") { model.cleanVerifiedMediaCache() }
                        .buttonStyle(.markxCompact)
                        .disabled(model.isRunning || model.hasActiveDownloadProgress || model.archiveRoot == nil)
                        .help("核对内容后移除已有完整备份的重复缓存")
                }
            }
        case .about:
            MarkXGroup {
                HStack(spacing: MarkXSpace.l + MarkXSpace.xs) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 56, height: 56)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: MarkXSpace.xs) {
                        Text("MarkX").font(MarkXFont.title)
                        Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版本")（\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—")）")
                            .font(MarkXFont.detail).foregroundStyle(MarkXInterface.text2)
                            .textSelection(.enabled)
                        Text("© 2026 得否").font(MarkXFont.meta).foregroundStyle(MarkXInterface.text3)
                    }
                    Spacer(minLength: 0)
                }
                .padding(MarkXSpace.xl)
            }
            MarkXGroup(title: "隐私") {
                MarkXRow(title: "本机转换", detail: "正文不交给 AI，日志不自动上传。", symbol: "desktopcomputer")
                MarkXRow(title: "会话仅在内存使用", detail: "只读取 X 的登录信息。", symbol: "key")
                MarkXRow(title: "外部存储由你选择", detail: "验证图床后才会上传。", symbol: "externaldrive.badge.checkmark")
            }
        }
    }
}
