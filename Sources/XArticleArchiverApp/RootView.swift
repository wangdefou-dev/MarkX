import AppKit
import AVKit
import SwiftUI
import XArticleArchiverCore

struct RootView: View {
    @EnvironmentObject private var model: AppViewModel
    @AppStorage("articlePreviewTextScale") private var articlePreviewTextScale = 1.0

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 235)
        } content: {
            articleList
                .navigationSplitViewColumnWidth(min: 360, ideal: 430)
        } detail: {
            detail
        }
        .toolbar { toolbar }
        .onOpenURL { model.handleOpenURL($0) }
        .sheet(isPresented: $model.showingAddCreators) {
            AddCreatorsView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showingSyncAllConfiguration) {
            SyncAllCreatorsView()
                .environmentObject(model)
        }
        .sheet(isPresented: $model.showingConnectionSetup) {
            ConnectionSetupView()
                .environmentObject(model)
        }
        .alert("需要处理", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("知道了", role: .cancel) { model.errorMessage = nil }
                .help("关闭这条错误提示")
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert(
            model.downloadResultNotice?.title ?? "下载结果",
            isPresented: Binding(
                get: { model.downloadResultNotice != nil },
                set: { if !$0 { model.downloadResultNotice = nil } }
            )
        ) {
            Button("完成", role: .cancel) { model.downloadResultNotice = nil }
                .help("关闭下载结果")
        } message: {
            Text(model.downloadResultNotice?.message ?? "")
        }
        .alert(
            model.syncResultNotice?.title ?? "同步结果",
            isPresented: Binding(
                get: { model.syncResultNotice != nil },
                set: { if !$0 { model.syncResultNotice = nil } }
            )
        ) {
            Button("完成", role: .cancel) { model.syncResultNotice = nil }
                .help("关闭本次同步结果")
        } message: {
            Text(model.syncResultNotice?.message ?? "")
        }
        .confirmationDialog(
            model.articlePendingDeletion.map { "删除《\($0.title)》？" } ?? "删除文章？",
            isPresented: Binding(
                get: { model.articlePendingDeletion != nil },
                set: { if !$0 { model.articlePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) { model.deletePendingArticle() }
                .help("删除这篇文章的本地文件、快照和资料库记录")
            Button("取消", role: .cancel) { model.articlePendingDeletion = nil }
                .help("取消删除，保留这篇文章")
        } message: {
            Text("会删除本地 Markdown、全文快照和资料库记录，但不会删除远程图片或视频。本地文件可从废纸篓恢复。")
        }
        .confirmationDialog(
            model.exactCaptureTaskPendingDeletion.map { "删除《\($0.title)》的精确采集任务？" } ?? "删除精确采集任务？",
            isPresented: Binding(
                get: { model.exactCaptureTaskPendingDeletion != nil },
                set: { if !$0 { model.exactCaptureTaskPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除待采集任务", role: .destructive) { model.deletePendingExactCaptureTask() }
                .help("从继续精确采集队列移除该任务")
            Button("取消", role: .cancel) { model.exactCaptureTaskPendingDeletion = nil }
                .help("取消删除，保留该采集任务")
        } message: {
            Text("已有 Markdown 归档会完整保留，只取消后续精确采集；尚未产生归档的临时记录会从资料库删除。")
        }
        .confirmationDialog(
            "删除全部待精确采集任务？",
            isPresented: $model.showingDeleteAllExactCaptureTasksConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除全部待采集任务", role: .destructive) { model.deleteAllPendingExactCaptureTasks() }
                .help("清空继续精确采集队列，但保留已有归档")
            Button("取消", role: .cancel) { model.showingDeleteAllExactCaptureTasksConfirmation = false }
                .help("取消清空，保留全部采集任务")
        } message: {
            Text("将清理 \(model.pendingExactCaptureCount) 个任务。已存在的 Markdown、全文快照和媒体不会被删除；只会删除未归档的临时记录。")
        }
        .confirmationDialog(
            model.creatorPendingDeletion.map { "删除博主 @\($0.username)？" } ?? "删除博主？",
            isPresented: Binding(
                get: { model.creatorPendingDeletion != nil },
                set: { if !$0 { model.creatorPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("从博主列表删除", role: .destructive) { model.deletePendingCreator() }
                .help("停止跟踪并从侧边栏移除该博主")
            Button("取消", role: .cancel) { model.creatorPendingDeletion = nil }
                .help("取消删除，继续跟踪该博主")
        } message: {
            Text("只会停止跟踪并从侧边栏移除该博主。已经下载的文章、本地媒体缓存和远程图片/视频全部保留；以后再次添加该博主即可继续拉取。")
        }
    }

    private var sidebar: some View {
        let statistics = model.sidebarStatistics
        return List(selection: $model.sidebarSelection) {
            Section {
                Button {
                    model.presentDownloadSheet()
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("开始下载文章")
                                .fontWeight(.semibold)
                            Text("博主主页或文章链接")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "square.and.arrow.down.fill")
                            .foregroundStyle(.tint)
                    }
                }
                .buttonStyle(.plain)
                .disabled(model.isRunning || model.hasActiveDownloadProgress)
                .help("输入博主主页或一个及多个 X Article 链接开始下载")
            }
            Section("资料库") {
                SidebarCountRow(
                    title: "全部文章",
                    systemImage: "doc.text",
                    count: statistics.allArticleCount
                )
                .tag(AppViewModel.SidebarSelection.all)
                .contextMenu {
                    Button {
                        model.presentDownloadSheet()
                    } label: {
                        Label("开始下载文章…", systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.isRunning || model.hasActiveDownloadProgress)
                    Button {
                        model.requestSyncAll()
                    } label: {
                        Label("同步所有博主文章…", systemImage: SyncVisualStyle.symbolName)
                    }
                    .disabled(model.isRunning || model.hasActiveDownloadProgress || model.enabledCreatorCount == 0)
                }

                SidebarCountRow(
                    title: "等待继续",
                    systemImage: "clock.arrow.circlepath",
                    count: statistics.waitingArticleCount
                )
                .tag(AppViewModel.SidebarSelection.pending)
                .contextMenu {
                    Button {
                        model.showDownloadProgressWindow()
                    } label: {
                        Label("显示下载进度", systemImage: "arrow.down.circle")
                    }
                    .disabled(!model.hasActiveDownloadProgress)
                    Button(role: .cancel) {
                        model.cancelCurrentTask()
                    } label: {
                        Label("安全停止", systemImage: "stop.circle")
                    }
                    .disabled(!model.hasActiveDownloadProgress)
                    Button {
                        model.resumePendingBrowserCaptures()
                    } label: {
                        Label("重新开始未完成文章", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.hasActiveDownloadProgress || model.pendingExactCaptureCount == 0)
                }

                SidebarCountRow(
                    title: "需要处理",
                    systemImage: "exclamationmark.triangle",
                    count: statistics.needsAttentionArticleCount
                )
                .tag(AppViewModel.SidebarSelection.failed)
                .contextMenu {
                    Button {
                        model.resumePendingBrowserCaptures()
                    } label: {
                        Label("重新处理", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRunning || model.hasActiveDownloadProgress || model.pendingExactCaptureCount == 0)
                    Divider()
                    Button(role: .destructive) {
                        model.requestDeleteAllExactCaptureTasks()
                    } label: {
                        Label("删除全部待处理任务…", systemImage: "trash")
                    }
                    .disabled(model.pendingExactCaptureCount == 0)
                }
            }
            Section("博主") {
                ForEach(model.creators) { creator in
                    HStack(spacing: 8) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(creator.displayName).lineLimit(1)
                                Text("@\(creator.username)").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: creator.isProtected ? "lock.circle" : "person.crop.circle")
                        }
                        Spacer(minLength: 4)
                        SidebarCountBadge(count: statistics.articleCount(for: creator.id))
                    }
                    .tag(AppViewModel.SidebarSelection.creator(creator.id))
                    .contextMenu {
                        Button {
                            model.openCreatorProfile(creator)
                        } label: {
                            Label("查看 X 主页", systemImage: "arrow.up.right.square")
                        }
                        .help("在默认浏览器打开 @\(creator.username) 的 X 主页")
                        Button {
                            model.presentDownloadSheet(for: creator)
                        } label: {
                            Label("重新拉取文章…", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isRunning || model.hasActiveDownloadProgress)
                        .help("重新选择数量并拉取 @\(creator.username) 的 X Article")
                        Divider()
                        Button(role: .destructive) {
                            model.requestDeleteCreator(creator)
                        } label: {
                            Label("删除博主…", systemImage: "trash")
                        }
                        .disabled(model.isRunning || model.hasActiveDownloadProgress)
                        .help("从博主列表移除 @\(creator.username)，已归档文章保留")
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            SidebarStatusCard(
                isRunning: model.isRunning,
                statusText: model.isRunning ? model.progress.stage : model.statusMessage,
                archiveName: model.archiveRoot?.lastPathComponent ?? "未选择归档目录",
                hasChromeSession: ChromeXSessionReader.hasLocalChromeProfile(),
                hasImageHost: model.imageHostVerified,
                configureImageHost: { model.presentConnectionSetup(focusing: .imageHost) },
                switchDirectory: { model.chooseArchiveFolder() }
            )
            .padding(.horizontal, 8)
            .padding(.top, 5)
            .padding(.bottom, 8)
            .background(.bar)
        }
    }

    private var articleList: some View {
        VStack(spacing: 0) {
            Group {
                if !model.filteredArticles.isEmpty {
                    List(selection: $model.selectedArticleID) {
                        ForEach(model.filteredArticles) { article in
                            ArticleRow(article: article)
                                .tag(article.id)
                                .contextMenu {
                                    if article.pipelineState == .subscriptionRequired {
                                        Button {
                                            model.openSubscriptionPage(for: article)
                                        } label: {
                                            Label("在 Chrome 订阅 @\(article.authorHandle)", systemImage: "lock.open")
                                        }
                                    }
                                    if model.isArticleActivelyProcessing(article) {
                                        Button(role: .cancel) {
                                            model.stopProcessing(article)
                                        } label: {
                                            Label("停止处理", systemImage: "stop.circle")
                                        }
                                    } else {
                                        Button {
                                            model.restartProcessing(article)
                                        } label: {
                                            Label("重新处理", systemImage: "arrow.clockwise")
                                        }
                                        .disabled(model.isRunning || model.hasActiveDownloadProgress)
                                        .help("重新打开 X Article 页面并严格校验完整排版")
                                    }
                                    if ExactCaptureQueuePolicy.needsCapture(article) {
                                        Button(role: .destructive) {
                                            model.requestDeleteExactCaptureTask(article)
                                        } label: {
                                            Label("删除精确采集任务…", systemImage: "xmark.circle")
                                        }
                                        .help("只从待采集队列移除；已有本地归档保留")
                                    }
                                    Divider()
                                    Button(role: .destructive) {
                                        model.requestDeleteArticle(article)
                                    } label: {
                                        Label("删除文章…", systemImage: "trash")
                                    }
                                    .disabled(model.isRunning || model.hasActiveDownloadProgress)
                                    .help("删除这篇文章的本地归档；远程图片和视频不删除")
                                }
                        }
                    }
                    .listStyle(.inset)
                } else if model.archiveRoot == nil || !model.imageHostVerified {
                    setupCard
                } else {
                    ContentUnavailableView {
                        Label("还没有归档 X Article", systemImage: "tray")
                    } description: {
                        Text("添加一个或多个 X 博主，程序只会保存官方 X Article，不会再把普通帖子或线程当成文章。")
                    } actions: {
                        Button("开始下载文章") { model.presentDownloadSheet() }
                            .buttonStyle(.borderedProminent)
                            .help("输入博主主页或 X Article 链接开始下载")
                        Button("生成体验样例") { model.installDemo() }
                            .help("在本地归档目录生成一篇可预览的演示文章")
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(selectedSidebarCreator == nil ? listTitle : "")
        .safeAreaInset(edge: .bottom) {
            if model.isRunning || model.progress.scannedPosts > 0 {
                TaskProgressBar(progress: model.progress, isRunning: model.isRunning)
            }
        }
    }

    private var setupCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "square.and.arrow.down.on.square")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(.tint)
                Text("把 X Article 全文收进自己的 Mac")
                    .font(.largeTitle.bold())
                Text("按博主下载时直接读取其 X Articles 专属列表，再逐篇打开真实页面，保留标题、段落、列表、表格、代码、图片和视频顺序。整个下载流程不调用 X API。")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    SetupStatusRow(title: "本地归档目录", isReady: model.archiveRoot != nil, detail: model.archiveRoot?.path ?? "尚未选择")
                    SetupStatusRow(title: "Chrome X 登录状态", isReady: ChromeXSessionReader.hasLocalChromeProfile(), detail: ChromeXSessionReader.hasLocalChromeProfile() ? "自动复用本机 Chrome 登录态，无需重复输入密码" : "请先在 Chrome 登录 x.com")
                    SetupStatusRow(title: "媒体存储", isReady: model.imageHostVerified, detail: model.imageHostDetail)
                }
                HStack {
                    Button("开始配置") { model.showingConnectionSetup = true }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .help("设置本地归档目录和图片、视频存储方式")
                    if model.archiveRoot != nil {
                        Button("先生成本地体验样例") { model.installDemo() }
                            .controlSize(.large)
                            .help("在已选目录生成一篇不需要网络的演示文章")
                    }
                }
            }
            .padding(40)
            .frame(maxWidth: 620, alignment: .leading)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let article = model.selectedArticle {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(article.title).font(.title2.bold()).textSelection(.enabled)
                        HStack(spacing: 8) {
                            Button {
                                model.openCreatorProfile(handle: article.authorHandle)
                            } label: {
                                HStack(spacing: 4) {
                                    Text("@\(article.authorHandle)")
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption2.weight(.semibold))
                                }
                            }
                            .buttonStyle(.plain)
                            .help("查看 @\(article.authorHandle) 的 X 主页")
                            Text("·")
                            Text(article.contentType.displayName)
                            Text("·")
                            Text(article.publishedAt, style: .date)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        HStack {
                            StatusPill(
                                article.pipelineState.displayName,
                                color: article.pipelineState == .committed
                                    ? .green
                                    : article.pipelineState == .subscriptionRequired ? .purple : .orange
                            )
                            StatusPill("\(article.imageCount) 张图片", color: .blue)
                            if article.videoCount > 0 {
                                StatusPill("\(article.videoCount) 个视频", color: .purple)
                            }
                            Button {
                                model.openSource()
                            } label: {
                                Label("查看文章原文", systemImage: "arrow.up.right.square")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help("在默认浏览器打开当前 X Article 原页")
                            if article.warnings.contains(where: { $0.contains("精确插入位置") || $0.contains("段落级富文本") }) {
                                FixedReprocessButton(
                                    isDisabled: model.isRunning || model.hasActiveDownloadProgress,
                                    help: "重新打开原页并保存段落、列表、代码、引用和图片的真实顺序"
                                ) {
                                    model.captureSelectedArticleExactly()
                                }
                            }
                        }
                    }
                    Spacer()
                    HStack(spacing: 9) {
                        HStack(spacing: 3) {
                            Button {
                                adjustArticleTextScale(by: -0.1)
                            } label: {
                                Text("A−")
                                    .font(.callout.weight(.semibold))
                                    .frame(minWidth: 25)
                            }
                            .buttonStyle(.borderless)
                            .help("缩小文章文字")
                            .disabled(previewTextScale <= 0.8)

                            Button {
                                articlePreviewTextScale = 1.0
                            } label: {
                                Text("\(Int((previewTextScale * 100).rounded()))%")
                                    .font(.caption.monospacedDigit())
                                    .frame(minWidth: 38)
                            }
                            .buttonStyle(.borderless)
                            .help("恢复 100% 字号")
                            .disabled(previewTextScale == 1.0)

                            Button {
                                adjustArticleTextScale(by: 0.1)
                            } label: {
                                Text("A+")
                                    .font(.callout.weight(.semibold))
                                    .frame(minWidth: 25)
                            }
                            .buttonStyle(.borderless)
                            .help("放大文章文字")
                            .disabled(previewTextScale >= 1.6)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))

                        Menu {
                            Button("打开 Markdown") { model.openSelectedArticle() }
                                .help("用默认的 Markdown 应用打开本地文件")
                            Button("在 Finder 中显示") { model.revealSelectedArticle() }
                                .help("在 Finder 中定位当前文章的 Markdown 文件")
                            Divider()
                            Button("访问原文") { model.openSource() }
                                .help("在默认浏览器打开当前 X Article 原页")
                            if article.pipelineState == .subscriptionRequired {
                                Button("在 Chrome 订阅 @\(article.authorHandle)") {
                                    model.openSubscriptionPage(for: article)
                                }
                                .help("使用 MarkX 会读取登录状态的同一个 Chrome 完成订阅")
                            }
                            if model.isArticleActivelyProcessing(article) {
                                Button("停止处理", role: .cancel) { model.stopProcessing(article) }
                            } else {
                                Button("重新处理") { model.restartProcessing(article) }
                                    .disabled(model.isRunning || model.hasActiveDownloadProgress)
                                    .help("重新打开原页并严格校验完整排版")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.title2)
                        }
                        .menuStyle(.borderlessButton)
                        .help("更多文章操作：打开文件、定位、访问原文或重新采集")
                    }
                }
                .padding(22)
                Divider()
                if article.pipelineState != .committed || article.lastError != nil {
                    ArticleProcessingPanel(
                        article: article,
                        isActive: model.isArticleActivelyProcessing(article),
                        isActionDisabled: model.isRunning || model.hasActiveDownloadProgress,
                        stop: { model.stopProcessing(article) },
                        restart: { model.restartProcessing(article) },
                        openSubscription: { model.openSubscriptionPage(for: article) }
                    )
                    Divider()
                }
                ScrollView {
                    if let document = model.previewDocument(for: article) {
                        ArticleDocumentPreview(document: document, textScale: previewTextScale)
                            .padding(.horizontal, 30)
                            .padding(.vertical, 26 * previewTextScale)
                    } else if article.pipelineState != .committed || article.lastError != nil {
                        if article.markdownPath != nil {
                            Text(model.markdownPreview(for: article))
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                                .padding(24)
                        } else {
                            ContentUnavailableView(
                                "正文尚未生成",
                                systemImage: "doc.badge.clock",
                                description: Text("当前状态、错误原因和处理日志已显示在上方。")
                            )
                            .frame(maxWidth: .infinity, minHeight: 240)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("文章预览不可用", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                            Text("当前记录缺少可用于应用内预览的完整来源快照；本地 Markdown 仍显示在下方，可以重新处理以恢复预览。")
                                .foregroundStyle(.secondary)
                            FixedReprocessButton(
                                isDisabled: model.isRunning || model.hasActiveDownloadProgress,
                                help: "重新打开这篇 X Article 并恢复完整预览"
                            ) {
                                model.restartProcessing(article)
                            }
                            Text(model.markdownPreview(for: article))
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(24)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        } else {
            ContentUnavailableView("选择一篇 X Article", systemImage: "doc.richtext", description: Text("这里会按文章排版展示完整正文、图片和视频。"))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if let creator = selectedSidebarCreator {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) {
                    CreatorProfileToolbarHeader(
                        creator: creator,
                        openProfile: { model.openCreatorProfile(creator) }
                    )
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    CreatorProfileToolbarHeader(
                        creator: creator,
                        openProfile: { model.openCreatorProfile(creator) }
                    )
                }
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.presentDownloadSheet()
            } label: {
                Label("开始下载文章", systemImage: "square.and.arrow.down")
            }
            .disabled(model.isRunning || model.hasActiveDownloadProgress)
            .help("输入博主主页或 X Article 链接开始下载")

            Button {
                model.requestSyncAll()
            } label: {
                Label("同步所有博主文章", systemImage: SyncVisualStyle.symbolName)
            }
            .disabled(model.isRunning || model.hasActiveDownloadProgress || model.enabledCreatorCount == 0)
            .help("选择每位博主要检查的最近文章数量，并在后台同步所有已跟踪博主")

            if model.isRunning || model.hasActiveDownloadProgress {
                Button(role: .cancel) { model.cancelCurrentTask() } label: {
                    Label("安全停止", systemImage: "stop.circle")
                }
                .help("停止当前发现或精确采集流程，已完成内容保留")
            }

            if model.hasActiveDownloadProgress {
                Button {
                    model.showDownloadProgressWindow()
                } label: {
                    Label(
                        model.isDownloadProgressWindowVisible ? "下载进度" : "显示下载进度",
                        systemImage: "arrow.down.circle"
                    )
                }
                .help("重新打开后台下载队列和当前进度")
            }

            Button {
                model.presentConnectionSetup()
            } label: {
                Label("连接设置", systemImage: "gearshape")
            }
            .help("配置归档目录以及图片、视频存储方式")
        }
    }

    private var listTitle: String {
        switch model.sidebarSelection {
        case .all, .none: "全部文章"
        case .pending: "等待继续"
        case .failed: "需要处理"
        case .creator(let id): model.creators.first(where: { $0.id == id })?.displayName ?? "博主"
        }
    }

    private var selectedSidebarCreator: Creator? {
        guard case .creator(let id) = model.sidebarSelection else { return nil }
        return model.creators.first { $0.id == id }
    }

    private var previewTextScale: Double {
        min(max(articlePreviewTextScale, 0.8), 1.6)
    }

    private func adjustArticleTextScale(by delta: Double) {
        articlePreviewTextScale = min(max((previewTextScale + delta) * 10, 8), 16).rounded() / 10
    }
}

private struct CreatorProfileToolbarHeader: View {
    let creator: Creator
    let openProfile: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(creator.displayName)
                .font(.title2.weight(.semibold))
                .lineLimit(1)

            Button(action: openProfile) {
                HStack(alignment: .center, spacing: 4) {
                    Text("查看主页")
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                }
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("查看 @\(creator.username) 的 X 主页")
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 36, alignment: .center)
        .padding(.leading, 12)
    }
}

private struct SidebarStatusCard: View {
    let isRunning: Bool
    let statusText: String
    let archiveName: String
    let hasChromeSession: Bool
    let hasImageHost: Bool
    let configureImageHost: () -> Void
    let switchDirectory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill((isRunning ? Color.orange : Color.green).opacity(0.16))
                        .frame(width: 22, height: 22)
                    Image(systemName: isRunning ? SyncVisualStyle.symbolName : "checkmark")
                        .font(.caption2.bold())
                        .foregroundStyle(isRunning ? .orange : .green)
                }
                Text(isRunning ? "正在处理" : "归档器已就绪")
                    .font(.caption.weight(.semibold))
                Spacer()
                if isRunning {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack(spacing: 6) {
                SidebarConnectionBadge(title: "Chrome", isReady: hasChromeSession)
                if hasImageHost {
                    SidebarConnectionBadge(title: "存储", isReady: true)
                } else {
                    Button(action: configureImageHost) {
                        SidebarConnectionBadge(title: "存储", isReady: false, showsDisclosure: true)
                    }
                    .buttonStyle(.plain)
                    .help("媒体存储未就绪，点击直接打开存储配置")
                    .disabled(isRunning)
                }
            }

            Button(action: switchDirectory) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.tint)
                    Text(archiveName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.caption2.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .help("同步现有文章并切换保存目录")
            .disabled(isRunning)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.55), lineWidth: 0.7)
        }
    }
}

private struct SidebarConnectionBadge: View {
    let title: String
    let isReady: Bool
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isReady ? Color.green : Color.orange)
                .frame(width: 5, height: 5)
            Text("\(title)\(isReady ? "已连接" : "待配置")")
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
            }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.045), in: Capsule())
    }
}

private struct ArticleTypography {
    let scale: CGFloat

    init(_ scale: Double) {
        self.scale = CGFloat(scale)
    }

    var bodySize: CGFloat { 13 * scale }
    var bodyLineSpacing: CGFloat { 6.5 * scale }
    var paragraphSpacing: CGFloat { 16 * scale }
    var headingTopSpacing: CGFloat { 20 * scale }
    var headingBottomSpacing: CGFloat { 10 * scale }
    var listItemSpacing: CGFloat { 6 * scale }
    var listGroupSpacing: CGFloat { 16 * scale }
    var listIndent: CGFloat { 26 * scale }
    var listMarkerGap: CGFloat { 10 * scale }
    var listMarkerWidth: CGFloat { 28 * scale }
    var quoteSpacing: CGFloat { 16 * scale }
    var blockSpacing: CGFloat { 18 * scale }
    var explicitBlankLineHeight: CGFloat { 12 * scale }
}

private struct ArticleDocumentPreview: View {
    let document: CanonicalDocument
    let textScale: Double

    private var mediaByID: [String: MediaAsset] {
        Dictionary(uniqueKeysWithValues: document.media.map { ($0.id, $0) })
    }

    private var videoByID: [String: VideoAsset] {
        Dictionary(uniqueKeysWithValues: (document.videos ?? []).map { ($0.id, $0) })
    }

    private var characterCount: Int {
        document.blocks
            .filter { $0.kind != .image && $0.kind != .video && $0.kind != .divider }
            .reduce(0) { $0 + $1.text.count }
    }

    private var typography: ArticleTypography { ArticleTypography(textScale) }

    var body: some View {
        let orderedMarkers = ArticleListMarkerResolver.orderedMarkers(for: document.blocks)
        LazyVStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: fidelityIcon)
                    .foregroundStyle(fidelityColor)
                Text(fidelityTitle)
                    .fontWeight(.semibold)
                Text("· \(characterCount) 字")
                Text("· \(document.media.count) 张图片")
                if let videoCount = document.videos?.count, videoCount > 0 {
                    Text("· \(videoCount) 个视频")
                }
            }
            .font(.system(size: 12.5 * textScale))
            .foregroundStyle(.secondary)
            .padding(.bottom, typography.blockSpacing)

            ForEach(Array(document.blocks.enumerated()), id: \.element.id) { index, block in
                ArticleBlockView(
                    block: block,
                    media: block.mediaID.flatMap { mediaByID[$0] },
                    video: block.mediaID.flatMap { videoByID[$0] },
                    textScale: textScale,
                    resolvedOrderedMarker: orderedMarkers[index]
                )
                .padding(.bottom, spacingAfterBlock(at: index))
            }

            if !document.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 6 * typography.scale) {
                    Label("原始排版说明", systemImage: "info.circle")
                        .font(.system(size: 12.5 * textScale, weight: .semibold))
                    ForEach(document.warnings, id: \.self) { warning in
                        Text("• \(warning)")
                    }
                }
                .font(.system(size: 11 * textScale))
                .foregroundStyle(.secondary)
                .padding(12 * typography.scale)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 8 * typography.scale)
            }
        }
        .frame(maxWidth: 860, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .top)
        .textSelection(.enabled)
    }

    private var fidelityTitle: String {
        document.layoutFidelity?.displayName ?? "旧快照 · 待重新下载校验"
    }

    private var fidelityIcon: String {
        document.layoutFidelity == .textAndMediaOnly || document.layoutFidelity == nil
            ? "exclamationmark.triangle.fill"
            : "checkmark.seal.fill"
    }

    private var fidelityColor: Color {
        document.layoutFidelity == .textAndMediaOnly || document.layoutFidelity == nil ? .orange : .green
    }

    private func spacingAfterBlock(at index: Int) -> CGFloat {
        let block = document.blocks[index]
        guard index + 1 < document.blocks.count else { return 0 }
        let next = document.blocks[index + 1]

        if next.kind == .blankLine || block.kind == .blankLine { return 0 }
        if next.kind == .heading { return typography.headingTopSpacing }
        if block.kind == .heading { return typography.headingBottomSpacing }
        if isList(block), isList(next) { return typography.listItemSpacing }
        if isList(block) { return typography.listGroupSpacing }

        switch block.kind {
        case .paragraph, .unsupported: return typography.paragraphSpacing
        case .quote: return typography.quoteSpacing
        default: return typography.blockSpacing
        }
    }

    private func isList(_ block: CanonicalBlock) -> Bool {
        block.kind == .orderedListItem || block.kind == .unorderedListItem
    }
}

private struct ArticleBlockView: View {
    let block: CanonicalBlock
    let media: MediaAsset?
    let video: VideoAsset?
    let textScale: Double
    let resolvedOrderedMarker: String?

    private var typography: ArticleTypography { ArticleTypography(textScale) }

    private var preferredVideoURL: URL? {
        if let localPath = video?.localCachePath,
           FileManager.default.fileExists(atPath: localPath) {
            return URL(fileURLWithPath: localPath)
        }
        return video?.remoteURL
    }

    @ViewBuilder
    var body: some View {
        switch block.kind {
        case .paragraph:
            inlineText
                .font(bodyFont)
                .lineSpacing(typography.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        case .blankLine:
            Color.clear.frame(height: typography.explicitBlankLineHeight)
        case .heading:
            inlineText
                .font(headingFont)
                .lineSpacing(3 * typography.scale)
                .fixedSize(horizontal: false, vertical: true)
        case .unorderedListItem:
            listRow(marker: unorderedListMarker)
        case .orderedListItem:
            listRow(marker: resolvedOrderedMarker ?? "1.")
        case .quote:
            HStack(alignment: .top, spacing: 12 * typography.scale) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: max(3, 4 * typography.scale))
                inlineText
                    .font(bodyFont)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineSpacing(typography.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4 * typography.scale)
        case .code:
            ScrollView(.horizontal) {
                Text(block.text)
                    .font(.system(size: 13 * textScale, design: .monospaced))
                    .lineSpacing(4 * typography.scale)
                    .padding(14 * typography.scale)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.secondary.opacity(0.16)))
        case .divider:
            Divider().padding(.vertical, 8)
        case .table:
            if let rows = block.tableRows, !rows.isEmpty {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    tableCellText(cell)
                                        .font(.system(size: 12.5 * textScale, weight: cell.isHeader ? .semibold : .regular))
                                        .lineSpacing(4.5 * typography.scale)
                                        .padding(.horizontal, 12 * typography.scale)
                                        .padding(.vertical, 9 * typography.scale)
                                        .frame(
                                            minWidth: CGFloat(140 * max(1, cell.columnSpan)),
                                            maxWidth: CGFloat(340 * max(1, cell.columnSpan)),
                                            alignment: .leading
                                        )
                                        .background(cell.isHeader ? Color.secondary.opacity(0.12) : Color.clear)
                                        .overlay(Rectangle().stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
                                }
                            }
                        }
                    }
                    .padding(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ScrollView(.horizontal) {
                    Text(block.text)
                        .font(.system(size: 12.5 * textScale, design: .monospaced))
                        .lineSpacing(4 * typography.scale)
                        .padding(12 * typography.scale)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
        case .image:
            articleImage
        case .video:
            if let playbackURL = preferredVideoURL {
                ArchivedVideoPlayer(url: playbackURL)
            } else {
                Label("视频尚未下载并验证", systemImage: "exclamationmark.triangle")
                    .font(bodyFont)
                    .foregroundStyle(.orange)
            }
        case .embeddedPost:
            Group {
                if let referenceURL = block.links.first?.url {
                    Link(destination: referenceURL) {
                        Label("引用文章：\(referenceURL.absoluteString)", systemImage: "link")
                            .lineLimit(2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .help("打开引用的 X Article")
                } else {
                    Label {
                        block.text.isEmpty ? Text("在 X 查看嵌入内容") : inlineText
                    } icon: {
                        Image(systemName: "quote.bubble")
                    }
                }
            }
            .font(bodyFont)
            .padding(14 * typography.scale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        case .unsupported:
            if !block.text.isEmpty {
                inlineText
                    .font(bodyFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headingFont: Font {
        switch block.level {
        case 0...1: .system(size: 22 * textScale, weight: .bold)
        case 2: .system(size: 18 * textScale, weight: .bold)
        default: .system(size: 14 * textScale, weight: .semibold)
        }
    }

    private var bodyFont: Font {
        .system(size: typography.bodySize)
    }

    private func listRow(marker: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: typography.listMarkerGap) {
            Text(marker)
                .fontWeight(.semibold)
                .monospacedDigit()
                .frame(
                    width: max(typography.listMarkerWidth, CGFloat(marker.count) * typography.bodySize * 0.72),
                    alignment: .trailing
                )
            inlineText
                .lineSpacing(typography.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(bodyFont)
        .padding(.leading, CGFloat(max(0, block.depth)) * typography.listIndent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var unorderedListMarker: String {
        let markers = ["•", "◦", "▪"]
        return markers[max(0, block.depth) % markers.count]
    }

    private var inlineText: Text {
        let markdown = MarkdownRenderer.renderInlineText(
            block.text,
            styles: block.inlineStyles,
            links: block.links
        )
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: markdown, options: options) {
            return Text(attributed)
        }
        return Text(block.text)
    }

    private func tableCellText(_ cell: CanonicalTableCell) -> Text {
        let markdown = MarkdownRenderer.renderInlineText(
            cell.text,
            styles: cell.inlineStyles,
            links: cell.links
        )
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: markdown, options: options) {
            return Text(attributed)
        }
        return Text(cell.text)
    }

    @ViewBuilder
    private var articleImage: some View {
        if let media, let url = media.remoteURL ?? Optional(media.sourceURL) {
            VStack(alignment: .leading, spacing: 7) {
                Group {
                    if let localPath = media.localCachePath,
                       let localImage = NSImage(contentsOfFile: localPath) {
                        Image(nsImage: localImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                    } else {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                ZStack {
                                    Color.secondary.opacity(0.06)
                                    ProgressView("正在加载文章图片…")
                                }
                                .frame(height: 220)
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity)
                            case .failure:
                                Label("图片暂时无法加载", systemImage: "photo.badge.exclamationmark")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, minHeight: 150)
                            @unknown default:
                                EmptyView()
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15)))

                if let altText = media.altText, !altText.isEmpty {
                    Text(altText)
                        .font(.system(size: 11 * textScale))
                        .lineSpacing(3 * typography.scale)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3 * typography.scale)
        } else {
            Label("文章图片记录缺失", systemImage: "photo.badge.exclamationmark")
                .foregroundStyle(.orange)
        }
    }
}

private struct ArchivedVideoPlayer: View {
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ArchivedAVPlayerView(url: url)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15)))
            Link(destination: url) {
                Label("在默认播放器中打开视频", systemImage: "arrow.up.right.square")
            }
            .font(.caption)
        }
    }
}

/// AVKit's SwiftUI `VideoPlayer` currently aborts while initializing its
/// private generic NSViewRepresentable metadata on some macOS 26 builds.
/// Hosting the stable AppKit AVPlayerView directly keeps playback native while
/// avoiding that runtime-only crash in the installed app.
private struct ArchivedAVPlayerView: NSViewRepresentable {
    let url: URL

    final class Coordinator {
        var currentURL: URL?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        playerView.videoGravity = .resizeAspect
        playerView.player = AVPlayer(url: url)
        context.coordinator.currentURL = url
        return playerView
    }

    func updateNSView(_ playerView: AVPlayerView, context: Context) {
        guard context.coordinator.currentURL != url else { return }
        playerView.player?.pause()
        playerView.player = AVPlayer(url: url)
        context.coordinator.currentURL = url
    }

    static func dismantleNSView(_ playerView: AVPlayerView, coordinator: Coordinator) {
        playerView.player?.pause()
        playerView.player = nil
        coordinator.currentURL = nil
    }
}

private struct ArticleRow: View {
    let article: ArchivedArticle

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(article.title).font(.headline).lineLimit(2)
            HStack(spacing: 6) {
                Text("@\(article.authorHandle)")
                Text("·")
                Text(article.contentType.displayName)
                Spacer()
                Text(article.publishedAt, style: .date)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(statusTitle)
                if article.imageCount > 0 { Text("· \(article.imageCount) 张图") }
                if article.videoCount > 0 { Text("· \(article.videoCount) 个视频") }
            }
            .font(.caption)
        }
        .padding(.vertical, 6)
    }

    private var hasLayoutLimit: Bool {
        article.warnings.contains {
            $0.contains("未提供段落级富文本块") || $0.contains("精确插入位置") || $0.contains("富文本样式可能不完整")
        }
    }

    private var statusTitle: String {
        if article.pipelineState == .committed, hasLayoutLimit { return "文字图片完整 · 排版受限" }
        return article.pipelineState.displayName
    }

    private var statusIcon: String {
        if article.pipelineState == .subscriptionRequired { return "lock.fill" }
        return article.pipelineState == .committed && !hasLayoutLimit
            ? "checkmark.circle.fill"
            : "exclamationmark.circle.fill"
    }

    private var statusColor: Color {
        if article.pipelineState == .subscriptionRequired { return .purple }
        return article.pipelineState == .committed && !hasLayoutLimit ? .green : .orange
    }
}

private struct SidebarCountRow: View {
    let title: String
    let systemImage: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 4)
            SidebarCountBadge(count: count)
        }
        .contentShape(Rectangle())
    }
}

private struct SidebarCountBadge: View {
    let count: Int

    var body: some View {
        Text(count, format: .number.grouping(.never))
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .frame(minWidth: 28)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("\(count) 篇文章")
    }
}

private struct FixedReprocessButton: View {
    let isDisabled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("重新处理")
                .lineLimit(1)
                .frame(width: 64)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(10)
        .disabled(isDisabled)
        .help(help)
        .accessibilityLabel("重新处理")
    }
}

private struct ArticleProcessingPanel: View {
    let article: ArchivedArticle
    let isActive: Bool
    let isActionDisabled: Bool
    let stop: () -> Void
    let restart: () -> Void
    let openSubscription: () -> Void

    private var requiresSubscription: Bool {
        article.pipelineState == .subscriptionRequired
    }

    private var title: String {
        if requiresSubscription { return "需要订阅 @\(article.authorHandle)" }
        if article.pipelineState == .failed || article.lastError != nil { return "文章处理失败" }
        if article.pipelineState == .cancelled { return "文章处理已停止" }
        if isActive { return "文章正在处理中" }
        return "文章等待继续处理"
    }

    private var detail: String {
        if requiresSubscription {
            return "MarkX 不会绕过 X 的订阅权限。请在 Chrome 中订阅，或切换到已订阅账号，然后重新处理；任务会一直保留。"
        }
        if article.pipelineState == .failed || article.lastError != nil {
            return "错误原因和处理日志已保存在资料库；本地已完成的媒体不会被删除。"
        }
        if article.pipelineState == .cancelled {
            return "已安全停止；已完成步骤和本地媒体均保留，可以从当前文章重新开始。"
        }
        if isActive { return "正在读取 X 页面并保存正文、图片和视频。" }
        return "任务尚未完成，可以重新开始处理。"
    }

    private var color: Color {
        requiresSubscription ? .purple : article.pipelineState == .failed || article.lastError != nil ? .red : .orange
    }

    private var icon: String {
        requiresSubscription
            ? "lock.fill"
            : article.pipelineState == .failed || article.lastError != nil
            ? "xmark.octagon.fill"
            : article.pipelineState == .cancelled ? "stop.circle.fill" : "clock.arrow.circlepath"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Button("停止处理", role: .cancel, action: stop)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if requiresSubscription {
                    Button("在 Chrome 订阅", action: openSubscription)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("订阅后重新处理", action: restart)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isActionDisabled)
                } else {
                    FixedReprocessButton(
                        isDisabled: isActionDisabled,
                        help: "从当前文章重新开始读取、存储和校验"
                    ) {
                        restart()
                    }
                }
            }

            if let lastError = article.lastError, !lastError.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(requiresSubscription ? "访问说明" : "错误原因")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color)
                    Text(lastError)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("处理日志").font(.caption.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        if article.processingLog.isEmpty {
                            Text("尚无详细日志；当前状态：\(article.pipelineState.displayName)")
                        } else {
                            ForEach(Array(article.processingLog.suffix(30).enumerated()), id: \.offset) { _, line in
                                Text(line)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            .padding(10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(color.opacity(0.035))
        .contextMenu {
            if isActive {
                Button("停止处理", role: .cancel, action: stop)
            } else {
                if requiresSubscription {
                    Button("在 Chrome 订阅", action: openSubscription)
                }
                Button("重新处理", action: restart)
                    .disabled(isActionDisabled)
            }
        }
    }
}

private struct SetupStatusRow: View {
    let title: String
    let isReady: Bool
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(isReady ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }
}

private struct StatusPill: View {
    let title: String
    let color: Color

    init(_ title: String, color: Color) {
        self.title = title
        self.color = color
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(0.13), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct TaskProgressBar: View {
    let progress: SyncProgress
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if isRunning { ProgressView().controlSize(.small) }
                Text(progress.stage).font(.caption.weight(.medium))
                Spacer()
            }
            HStack(spacing: 12) {
                Label("X API 0", systemImage: "checkmark.shield")
                    .foregroundStyle(.green)
                Text("发现 \(progress.discoveredArticles)")
                Text("完成 \(progress.completedArticles)")
                if progress.skippedArticles > 0 { Text("跳过 \(progress.skippedArticles)") }
                Text("图片 \(progress.uploadedImages)")
                Text("视频 \(progress.uploadedVideos)")
                if progress.failedArticles > 0 { Text("失败 \(progress.failedArticles)").foregroundStyle(.red) }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.bar)
    }
}
