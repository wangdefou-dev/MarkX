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

    private var parsedHandles: [String] { HandleParser.parse(input) }
    private var parsedArticleLinks: [XArticleLink] { XArticleURLParser.parse(input) }

    private var validCreatorInput: Bool {
        switch entryMode {
        case .single: parsedHandles.count == 1
        case .batch: !parsedHandles.isEmpty
        case .articleLinks: false
        }
    }

    private var canDownload: Bool {
        if !parsedArticleLinks.isEmpty {
            return parsedArticleLinks.count <= 500
        }
        return validCreatorInput
    }

    private var downloadTitle: String {
        if !parsedArticleLinks.isEmpty { return "下载 \(parsedArticleLinks.count) 篇文章" }
        return mode == .recentWindow ? "下载最近 \(articleLimit) 篇" : "下载完整历史"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.downloadSheetPrefill.isEmpty ? "开始下载文章" : "重新拉取博主文章")
                    .font(.title2.bold())
                Text(entryMode == .articleLinks
                     ? "每行粘贴一条 x.com 或 twitter.com 的文章链接；在应用内打开真实页面并保留段落、列表、表格、代码、图片和视频顺序。"
                     : (model.downloadSheetPrefill.isEmpty
                        ? "粘贴 @handle 或 X 博主主页链接，选择数量后下载其官方 X Article。"
                        : "已带入这位博主。你可以再次选择数量并重新拉取；既有文章会校验更新，新文章会继续添加。"))
                    .foregroundStyle(.secondary)
            }

            Picker("添加方式", selection: $entryMode) {
                ForEach(EntryMode.allCases, id: \.self) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .help("选择输入单个博主、多个博主，或一个及多个 X Article 链接")

            entryInputSection

            downloadOptionsSection

            downloadFooter
        }
        .padding(24)
        .frame(width: 680)
        .onAppear {
            input = model.downloadSheetPrefill
            entryMode = model.downloadSheetUsesArticleLinks ? .articleLinks : .single
        }
        .onChange(of: input) { _, newValue in
            // The default tab is "single creator". Detect a pasted /status/
            // or /article/ URL immediately so it goes straight to full-page
            // capture instead of the creator Articles-list discovery flow.
            if !XArticleURLParser.parse(newValue).isEmpty {
                entryMode = .articleLinks
            }
        }
        .onChange(of: entryMode) { _, newMode in
            if newMode == .single {
                input = SingleCreatorInputPolicy.sanitize(input)
            }
        }
    }

    @ViewBuilder
    private var entryInputSection: some View {
        switch entryMode {
        case .single:
            VStack(alignment: .leading, spacing: 7) {
                Text("博主主页").font(.headline)
                StrictSingleLineTextField(
                    text: Binding(
                        get: { input },
                        set: { input = SingleCreatorInputPolicy.sanitize($0) }
                    ),
                    placeholder: "@username 或 https://x.com/username"
                )
                    .frame(height: 23)
                Text("仅支持一行；按回车不会换行，粘贴多行内容时只保留第一条非空内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if parsedHandles.count > 1 {
                    Label("单个模式一次只接受一个博主", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        case .batch:
            VStack(alignment: .leading, spacing: 7) {
                Text("博主列表").font(.headline)
                Text("每行一个 @handle 或 X 主页链接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                multilineInput(minHeight: 115)
            }
        case .articleLinks:
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("X Article 链接").font(.headline)
                    Spacer()
                    Text("已识别 \(parsedArticleLinks.count) 条")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(parsedArticleLinks.count > 500 ? .red : .secondary)
                }
                Text("每行一个，支持 /status/PostID 和 /article/PostID；一次 1–500 条并自动去重。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                multilineInput(minHeight: 150)
                Toggle("本地已存在时仍重新获取完整排版", isOn: $refreshExistingLinks)
                    .help("开启后，已完成的文章也会重新打开原页并校验排版")
                Text(refreshExistingLinks
                     ? "会在应用内重新打开页面，严格校验后再替换本地 Markdown。"
                     : "默认跳过已通过精确排版校验的文章。直接链接模式不调用 X API。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func multilineInput(minHeight: CGFloat) -> some View {
        TextEditor(text: $input)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: minHeight)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
    }

    @ViewBuilder
    private var downloadOptionsSection: some View {
        if entryMode == .articleLinks {
            GroupBox {
                Label("链接模式的正文、图片和视频全部来自当前展示的 X Article 页面；X API 调用为 0。多条链接会进入队列，逐篇确认并保存。", systemImage: "safari")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            creatorDownloadOptions
        }
    }

    @ViewBuilder
    private var creatorDownloadOptions: some View {
        Picker("归档范围", selection: $mode) {
            ForEach(ArchiveMode.allCases, id: \.self) { archiveMode in
                Text(archiveMode.displayName).tag(archiveMode)
            }
        }
        .pickerStyle(.segmented)
        .help("选择只下载最近指定数量，或自动滚动 Articles 列表获取完整历史")

        if mode == .recentWindow {
            recentRangeControls
        }

        creatorModeExplanation
    }

    private var recentRangeControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("每位博主下载数量").font(.headline)
                        Text("默认保存最近 10 篇 X Article。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    articleLimitMenu
                    Stepper(value: $articleLimit, in: 1...100) {
                        Text("\(articleLimit) 篇")
                    }
                    .fixedSize()
                    .help("调整每位博主要下载的最近 X Article 数量，范围 1–100 篇")
                }
                Label(
                    "数量只针对 Articles 专属列表中的文章，不会读取或扫描普通 Post。",
                    systemImage: "checkmark.shield"
                )
                .font(.caption)
                .foregroundStyle(.green)
            }
        }
    }

    private var articleLimitMenu: some View {
        Menu("快捷选择") {
            Button("5 篇") { articleLimit = 5 }
                .help("将每位博主的下载数量设为最近 5 篇")
            Button("10 篇") { articleLimit = 10 }
                .help("将每位博主的下载数量设为默认的最近 10 篇")
            Button("20 篇") { articleLimit = 20 }
                .help("将每位博主的下载数量设为最近 20 篇")
            Button("50 篇") { articleLimit = 50 }
                .help("将每位博主的下载数量设为最近 50 篇")
            Button("100 篇") { articleLimit = 100 }
                .help("将每位博主的下载数量设为最近 100 篇")
        }
        .help("快速设置每位博主要下载的文章数量")
    }

    private var creatorModeExplanation: some View {
        GroupBox {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "safari")
                    .foregroundStyle(.blue)
                Text(mode == .recentWindow
                     ? "应用会直接打开 x.com/<博主>/articles，只收集前 \(articleLimit) 个官方 Article 链接，再逐篇保存完整排版。发现和正文下载的 X API 调用都为 0。"
                     : "应用会自动滚动 x.com/<博主>/articles 直到列表底部，再逐篇保存。不会调用 Full-Archive Search，也不会扫描普通 Post，X API 调用为 0。")
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var downloadFooter: some View {
        HStack {
            Button("取消") { dismiss() }
                .help("关闭下载窗口，不创建任务")
            Spacer()
            Button(downloadTitle, action: startDownload)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canDownload)
                .help(parsedArticleLinks.isEmpty
                      ? "进入博主 Articles 列表，发现标题和链接后逐篇下载"
                      : "把已识别的 \(parsedArticleLinks.count) 条链接加入精确排版下载队列")
        }
    }

    private func startDownload() {
        // Direct Article URLs always take the zero-API path even if the
        // segmented control has not visually updated yet.
        if !parsedArticleLinks.isEmpty {
            model.archiveArticleLinks(input: input, refreshExisting: refreshExistingLinks)
        } else {
            model.addAndArchiveCreators(input: input, mode: mode, articleLimit: articleLimit)
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
        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.drawsBackground = true
        field.focusRingType = .default
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
    @State private var accessKey = ""
    @State private var secretKey = ""
    @State private var isTestingUPic = false
    @State private var isTestingS3 = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(connectionTitle).font(.title2.bold())
                    Text("所有正文在本地转换；S3/R2 凭证仅保存在这台 Mac 的钥匙串。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .help("关闭连接设置")
            }
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        setupSection(number: "1", title: "选择本地归档目录") {
                            HStack {
                                Text(model.archiveRoot?.path ?? "尚未选择")
                                    .font(.callout.monospaced())
                                    .lineLimit(2)
                                    .foregroundStyle(model.archiveRoot == nil ? .secondary : .primary)
                                Spacer()
                                Button(model.archiveRoot == nil ? "选择目录" : "更换") { model.chooseArchiveFolder() }
                                    .help(model.archiveRoot == nil
                                          ? "选择 Markdown、快照和资料库的本地保存目录"
                                          : "同步现有文章后切换到新的本地保存目录")
                            }
                        }
                        .id("archive-directory")

                        setupSection(number: "2", title: "选择图片和视频存储") {
                            imageHostConfiguration
                        }
                        .id("image-host")
                    }
                    .padding(.trailing, 8)
                }
                .onAppear {
                    if case .imageHost = model.connectionSetupTarget {
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(120))
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("image-host", anchor: .top)
                            }
                        }
                    }
                }
            }

            Divider()
            HStack {
                Image(systemName: "lock.shield")
                Text("零遥测；Chrome 的 X 会话只复制到当前内存采集窗口；不把文章交给 AI。")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 720, height: 640)
    }

    private var connectionTitle: String {
        if case .imageHost = model.connectionSetupTarget { return "媒体存储设置" }
        return "开始前配置"
    }

    @ViewBuilder
    private var imageHostConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("存储方式", selection: Binding(
                get: { model.imageHostChoice },
                set: { model.selectImageHost($0) }
            )) {
                ForEach(AppViewModel.ImageHostChoice.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .help("默认只保存在归档目录；选择 uPic 时会同时保存本地备份与远程副本")

            if model.imageHostChoice == .local {
                Label("无需额外配置，已可用", systemImage: "externaldrive.fill.badge.checkmark")
                    .foregroundStyle(.green)
                Text("图片保存到归档目录的 media/images，视频保存到 media/videos；Markdown 使用可随整个归档目录移动的相对路径。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.imageHostChoice == .uPic {
                Label(model.upicCapability.detail, systemImage: model.upicCapability.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(model.upicCapability.isAvailable ? .green : .orange)
                Text("会让 uPic 使用当前默认图床上传一张 1×1 无隐私测试图，再由本应用验证返回的 HTTPS 图片。验证后，每张图片和视频都会先保存到本地 media，再上传 uPic。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(isTestingUPic ? "正在测试…" : "验证 uPic 默认图床") {
                    isTestingUPic = true
                    Task {
                        _ = await model.testUPic()
                        isTestingUPic = false
                    }
                }
                .disabled(!model.upicCapability.isAvailable || isTestingUPic || isTestingS3)
                .help("上传一张无隐私测试图，验证 uPic 当前默认图床能返回可访问的 HTTPS 地址")
                Text("Markdown 默认写入 uPic 的 HTTPS 链接，本地 media 文件作为备份和应用内预览来源。本应用不读取、复制或记录 uPic 的密钥。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                nativeS3Fields
            }

            Label(model.imageHostDetail, systemImage: model.imageHostVerified ? "checkmark.seal.fill" : "exclamationmark.triangle")
                .foregroundStyle(model.imageHostVerified ? .green : .orange)
        }
    }

    @ViewBuilder
    private var nativeS3Fields: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("Endpoint，例如 https://<account>.r2.cloudflarestorage.com", text: $model.s3Endpoint)
                .textFieldStyle(.roundedBorder)
                .onChange(of: model.s3Endpoint) { _, _ in model.invalidateImageHostVerification() }
            HStack {
                TextField("Bucket", text: $model.s3Bucket)
                TextField("Region（R2 填 auto）", text: $model.s3Region)
            }
            .textFieldStyle(.roundedBorder)
            .onChange(of: model.s3Bucket) { _, _ in model.invalidateImageHostVerification() }
            .onChange(of: model.s3Region) { _, _ in model.invalidateImageHostVerification() }
            TextField("图片公开访问根地址，例如 https://img.example.com", text: $model.s3PublicBaseURL)
                .textFieldStyle(.roundedBorder)
                .onChange(of: model.s3PublicBaseURL) { _, _ in model.invalidateImageHostVerification() }
            TextField("对象路径前缀", text: $model.s3KeyPrefix)
                .textFieldStyle(.roundedBorder)
                .onChange(of: model.s3KeyPrefix) { _, _ in model.invalidateImageHostVerification() }
            HStack {
                SecureField(model.hasS3Credentials ? "Access Key（留空使用已保存值）" : "Access Key", text: $accessKey)
                SecureField(model.hasS3Credentials ? "Secret Key（留空使用已保存值）" : "Secret Key", text: $secretKey)
            }
            .textFieldStyle(.roundedBorder)
            Text("密钥仅保存在 macOS 钥匙串；非敏感的 endpoint、bucket 和公开域名保存在本机设置。")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Button(isTestingS3 ? "正在上传测试图…" : "保存并测试 S3/R2") {
                    isTestingS3 = true
                    Task {
                        let success = await model.saveAndTestS3(accessKey: accessKey, secretKey: secretKey)
                        if success { accessKey = ""; secretKey = "" }
                        isTestingS3 = false
                    }
                }
                .disabled(isTestingS3 || model.s3Endpoint.isEmpty || model.s3PublicBaseURL.isEmpty)
                .help("将 S3/R2 密钥安全保存到钥匙串，并上传测试图验证公开访问")
                if model.hasS3Credentials {
                    Button("移除已保存密钥", role: .destructive) { model.removeS3Credentials() }
                        .help("从 macOS 钥匙串删除已保存的 S3/R2 Access Key 和 Secret Key")
                }
            }
        }
    }

    private func setupSection<Content: View>(number: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number)
                .font(.headline)
                .frame(width: 30, height: 30)
                .background(.tint, in: Circle())
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppViewModel

    var body: some View {
        Form {
            Section("本地归档") {
                LabeledContent("目录", value: model.archiveRoot?.path ?? "未选择")
                Button("选择或更换目录") { model.chooseArchiveFolder() }
                    .help("同步现有文章后选择新的本地归档目录")
            }
            Section("X 页面登录") {
                LabeledContent("Chrome", value: ChromeXSessionReader.hasLocalChromeProfile() ? "可自动导入" : "未找到本地配置")
                Text("博主发现直接读取 /articles 专属列表，完整历史通过自动滚动列表获取；不需要 X Developer API。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("媒体存储") {
                LabeledContent("当前方式", value: model.imageHostChoice.displayName)
                LabeledContent("状态", value: model.imageHostDetail)
                Button("打开连接配置") { model.showingConnectionSetup = true }
                    .help("打开归档目录与媒体存储设置")
            }
            Section("隐私") {
                Text("软件不收集遥测，不上传诊断日志。文章链接与正文仅从你在应用内打开的 X 页面读取并在本机转换，不调用 X API；图片和视频只发送到你明确选择并测试通过的存储。")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
