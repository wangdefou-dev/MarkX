import AppKit
import AVKit
import SwiftUI
import XArticleArchiverCore

struct RootView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("articlePreviewTextScale") private var articlePreviewTextScale = 1.0
    @AppStorage("sidebarLibraryExpanded") private var isLibraryExpanded = true
    @AppStorage("sidebarCreatorsExpanded") private var isCreatorsExpanded = true
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 280)
                .toolbar(removing: .sidebarToggle)
        } content: {
            articleList
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .background(MainWindowChrome(
                    isSidebarVisible: isSidebarVisible,
                    libraryTitle: selectedSidebarCreator == nil ? listTitle : nil
                ) {
                    withAnimation(.easeInOut(duration: MainWindowChrome.sidebarTransitionDuration)) {
                        columnVisibility = isSidebarVisible ? .doubleColumn : .all
                    }
                })
                .navigationSplitViewColumnWidth(min: 360, ideal: 430, max: 500)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .animation(nil, value: model.sidebarSelection)
        .animation(nil, value: model.selectedArticleID)
        .toolbar { toolbar }
        .font(MarkXTypography.body)
        .onAppear { model.refreshBrowserStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshBrowserStatus() }
        }
        .onOpenURL { model.handleOpenURL($0) }
        .handlesExternalEvents(
            preferring: MarkXWindowPolicy.externalEventKeys,
            allowing: MarkXWindowPolicy.externalEventKeys
        )
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
        .sheet(item: $model.downloadResultNotice) { notice in
            DownloadResultView(notice: notice)
        }
        .sheet(item: $model.syncResultNotice) { notice in
            DownloadResultView(notice: notice)
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

    private var isSidebarVisible: Bool {
        columnVisibility != .doubleColumn && columnVisibility != .detailOnly
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarDownloadEntry
            sidebarLibrary
            if model.isRunning {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(model.progress.stage).font(MarkXTypography.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)
            }
        }
        .background(.bar)
    }

    private var sidebarLibrary: some View {
        let statistics = model.sidebarStatistics
        return List(selection: $model.sidebarSelection) {
            Section {
                if isLibraryExpanded {
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
                    title: "今日推文",
                    systemImage: "sun.max",
                    count: model.todayArticleCount
                )
                .tag(AppViewModel.SidebarSelection.today)
                .help("按 X 原始发布时间显示今天发布的文章")

                SidebarCountRow(
                    title: "商单内容",
                    systemImage: "tag.fill",
                    count: statistics.commercialArticleCount
                )
                .tag(AppViewModel.SidebarSelection.commercial)
                .help("显示带有 X 官方 Paid partnership 标记的商单内容")

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
                        model.reprocessNeedsAttentionArticles()
                    } label: {
                        Label("重新处理", systemImage: "arrow.clockwise")
                    }
                    .disabled(model.isRunning || model.hasActiveDownloadProgress || statistics.needsAttentionArticleCount == 0)
                    Divider()
                    Button(role: .destructive) {
                        model.requestDeleteAllExactCaptureTasks()
                    } label: {
                        Label("删除全部待处理任务…", systemImage: "trash")
                    }
                    .disabled(model.pendingExactCaptureCount == 0)
                }
                }
            } header: {
                SidebarSectionHeader(title: "资料库", isExpanded: $isLibraryExpanded)
            }
            Section {
                if isCreatorsExpanded {
                    if !model.pinnedCreators.isEmpty {
                        ForEach(model.pinnedCreators) { creator in
                            creatorSidebarRow(creator, statistics: statistics)
                        }
                        .onMove { offsets, destination in
                            model.movePinnedCreators(fromOffsets: offsets, toOffset: destination)
                        }
                    }
                    ForEach(model.unpinnedCreators) { creator in
                        creatorSidebarRow(creator, statistics: statistics)
                    }
                }
            } header: {
                creatorHeadingRow
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 32)
    }

    private var sidebarDownloadEntry: some View {
        Button { model.presentDownloadSheet() } label: {
            HStack(spacing: 9) {
                Text("开始下载文章")
                Spacer(minLength: 4)
                Image(systemName: "square.and.arrow.down")
                    .accessibilityHidden(true)
            }
            .font(MarkXTypography.system(size: 15, weight: .medium))
            .foregroundStyle(.orange)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
            .background(Color.orange.opacity(0.1), ignoresSafeAreaEdges: [])
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.isRunning || model.hasActiveDownloadProgress)
        .help("输入博主主页或 X Article 链接开始下载")
    }

    private func sidebarMetricRow<Icon: View, Title: View, Value: View>(
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder title: () -> Title,
        @ViewBuilder value: () -> Value
    ) -> some View {
        SidebarMetricRow(icon: icon, title: title, value: value)
    }

    private var creatorHeadingRow: some View {
        SidebarSectionHeader(title: "博主", count: model.enabledCreatorCount, countUnit: "位博主", isExpanded: $isCreatorsExpanded)
    }

    private func creatorArticleCountHelp(
        downloaded: Int,
        known: Int?,
        displayedTotal: Int?,
        localArticleCount: Int
    ) -> String {
        if let known, known > 0 {
            return "已下载 \(downloaded) 篇；线上文章总数 \(max(known, downloaded)) 篇；本地记录 \(localArticleCount) 篇"
        }
        if displayedTotal == 0 {
            return "已下载 \(downloaded) 篇；线上文章总数已核对为 0；本地记录 \(localArticleCount) 篇"
        }
        if let displayedTotal {
            return "已下载 \(downloaded) 篇；线上总数还没有核对完，先按已保存的 \(displayedTotal) 篇显示；本地记录 \(localArticleCount) 篇"
        }
        return "已下载 \(downloaded) 篇；线上总数尚未获取；本地记录 \(localArticleCount) 篇"
    }

    private func creatorSidebarRow(
        _ creator: Creator,
        statistics: ArchiveSidebarStatistics
    ) -> some View {
        let localArticleCount = statistics.articleCount(for: creator.id)
        let downloadedArticleCount = statistics.downloadedArticleCount(for: creator.id)
        return sidebarMetricRow {
            Image(systemName: model.isCreatorPinned(creator)
                  ? "pin.fill"
                  : creator.isProtected ? "lock" : "person")
                .font(MarkXTypography.system(size: model.isCreatorPinned(creator) ? 11 : 13, weight: .regular))
                .foregroundStyle(model.isCreatorPinned(creator) ? Color.orange : Color.secondary)
        } title: {
            VStack(alignment: .leading, spacing: 2) {
                Text(creator.displayName)
                    .lineLimit(1).help(creator.displayName + " · @" + creator.username)
                Text("@\(creator.username)")
                    .font(MarkXTypography.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .font(MarkXTypography.system(size: 12, weight: .medium))
        } value: {
            let verifiedEmpty = creator.completeness == .fullArchiveVerified
                && downloadedArticleCount == 0
                && (creator.knownArticleCount ?? 0) == 0
            let displayedTotal = CreatorArticleCountPolicy.displayedTotal(
                known: creator.knownArticleCount,
                downloaded: downloadedArticleCount,
                verifiedEmpty: verifiedEmpty
            )
            SidebarMetricBadge(
                text: SidebarMetricBadge.fraction(
                    numerator: downloadedArticleCount,
                    denominator: displayedTotal
                ),
                accessibilityLabel: displayedTotal.map {
                    "已下载 \(downloadedArticleCount) 篇，文章总数 \($0) 篇"
                } ?? "已下载 \(downloadedArticleCount) 篇，文章总数尚未获取"
            )
            .help(creatorArticleCountHelp(
                downloaded: downloadedArticleCount,
                known: creator.knownArticleCount,
                displayedTotal: displayedTotal,
                localArticleCount: localArticleCount
            ))
        }
        .frame(minHeight: 38)
        .padding(.vertical, 2)
        .tag(AppViewModel.SidebarSelection.creator(creator.id))
        .contextMenu {
            if model.isCreatorPinned(creator) {
                Button {
                    model.unpinCreator(creator)
                } label: {
                    Label("取消置顶", systemImage: "pin.slash")
                }
                if let index = model.pinnedCreatorIndex(of: creator) {
                    Divider()
                    Button {
                        model.movePinnedCreator(creator, by: -1)
                    } label: {
                        Label("置顶上移", systemImage: "arrow.up")
                    }
                    .disabled(index == 0)
                    Button {
                        model.movePinnedCreator(creator, by: 1)
                    } label: {
                        Label("置顶下移", systemImage: "arrow.down")
                    }
                    .disabled(index == model.pinnedCreators.count - 1)
                }
            } else if model.canPinAnotherCreator {
                Button {
                    model.pinCreator(creator)
                } label: {
                    Label("置顶博主", systemImage: "pin")
                }
                .help("将 @\(creator.username) 放入置顶列表，最多 5 位")
            } else {
                Button("置顶博主（最多 5 位）", systemImage: "pin") {}
                    .disabled(true)
            }
            Divider()
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
            Button {
                model.refreshCreatorArticleCount(creator)
            } label: {
                Label("刷新线上文章总数", systemImage: "number.circle")
            }
            .disabled(model.isRunning || model.hasActiveDownloadProgress)
            .help("完整扫描 @\(creator.username) 的 Articles 列表，只更新线上文章总数，不下载文章")
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

    private var librarySearchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索标题、博主或正文", text: $model.searchText)
                .textFieldStyle(.plain)
                .help("在当前分类内搜索，支持中文正文")
                .accessibilityLabel("搜索标题、博主或正文")
                .accessibilityIdentifier("librarySearchField")
            if model.isSearching { ProgressView().controlSize(.small) }
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("清空搜索")
            }
        }
        .font(MarkXTypography.system(size: 12))
        .padding(.horizontal, 10)
        .frame(width: 260, height: 30)
    }

    private var articleList: some View {
        VStack(spacing: 0) {
            if model.isPreparingSearch {
                Text("正在整理历史文章，搜索结果会逐步补齐…")
                    .font(MarkXTypography.caption).foregroundStyle(.secondary).padding(8)
                Divider()
            }
            Group {
                if !model.filteredArticles.isEmpty {
                    List(selection: $model.selectedArticleID) {
                        ForEach(Array(model.filteredArticles.enumerated()), id: \.element.id) { index, article in
                            let creator = model.creators.first(where: { $0.id == article.creatorID })
                            ArticleRow(article: article, index: index + 1, creator: creator)
                                .tag(article.id)
                                .contextMenu {
                                    if article.pipelineState == .subscriptionRequired {
                                        Button {
                                            model.openSubscriptionPage(for: article)
                                        } label: {
                                            Label("在浏览器订阅 @\(article.authorHandle)", systemImage: "lock.open")
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
                                    if let creator {
                                        Button {
                                            model.sidebarSelection = .creator(creator.id)
                                        } label: {
                                            Label("查看博主的其他文章", systemImage: "person.crop.circle")
                                        }
                                        .help("跳转到 @\(creator.username) 的文章分组")
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
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                } else if model.archiveRoot == nil || !model.imageHostVerified {
                    setupCard
                } else if model.articles.isEmpty {
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
                } else {
                    ContentUnavailableView {
                        Label(emptyFilterTitle, systemImage: emptyFilterIcon)
                    } description: {
                        Text(emptyFilterDescription)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("")
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
                    .font(MarkXTypography.system(size: 42, weight: .medium))
                    .foregroundStyle(.tint)
                Text("把 X Article 全文收进自己的 Mac")
                    .font(MarkXTypography.largeTitle.bold())
                Text("按博主下载时直接读取其 X Articles 专属列表，再逐篇打开真实页面，保留标题、段落、列表、表格、代码、图片和视频顺序。整个下载流程不调用 X API。")
                    .font(MarkXTypography.title3)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    SetupStatusRow(title: "本地归档目录", isReady: model.archiveRoot != nil, detail: model.archiveRoot?.path ?? "尚未选择")
                    SetupStatusRow(title: "浏览器 X 登录状态", isReady: model.hasBrowserSessionData, detail: model.browserSessionProbe.summary)
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
            ScrollView {
                VStack(spacing: 0) {
                    articleDetailHeader(article)
                    if article.pipelineState != .committed || article.lastError != nil {
                        ArticleProcessingPanel(
                            article: article,
                            isActive: model.isArticleActivelyProcessing(article),
                            isActionDisabled: model.isRunning || model.hasActiveDownloadProgress,
                            stop: { model.stopProcessing(article) },
                            restart: { model.restartProcessing(article) },
                            openSubscription: { model.openSubscriptionPage(for: article) }
                        )
                    }
                    articleDetailBody(article)
                }
                .frame(minWidth: 0, maxWidth: 860, alignment: .leading)
                .padding(.horizontal, 30)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .top)
            }
            .id(article.id)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            ContentUnavailableView("选择一篇 X Article", systemImage: "doc.richtext", description: Text("这里会按文章排版展示完整正文、图片和视频。"))
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
    }

    private func articleDetailHeader(_ article: ArchivedArticle) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(article.title)
                    .font(MarkXTypography.title2.bold())
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
                articleReadingControls(article)
            }
            MarkXFlowLayout(spacing: 8) {
                Button {
                    model.openCreatorProfile(handle: article.authorHandle)
                } label: {
                    HStack(spacing: 4) {
                        Text(selectedArticleCreator?.displayName ?? "@\(article.authorHandle)")
                            .lineLimit(1)
                        Text("@\(selectedArticleCreator?.username ?? article.authorHandle)")
                            .lineLimit(1)
                        Image(systemName: "arrow.up.right")
                            .font(MarkXTypography.caption2.weight(.semibold))
                    }
                }
                .buttonStyle(.plain)
                .help("查看 @\(article.authorHandle) 的 X 主页")
                Text(article.publishedAt, format: .dateTime.year().month().day().hour().minute())
                    .lineLimit(1)
            }
            .font(MarkXTypography.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            MarkXFlowLayout(spacing: 8) {
                StatusPill(
                    article.pipelineState.displayName,
                    color: article.pipelineState == .committed
                        ? .green
                        : article.pipelineState == .subscriptionRequired ? .purple : .orange
                )
                if article.isPaidPartnership {
                    StatusPill("商单内容", color: .orange)
                        .help("X 官方 Paid partnership 商单内容标记")
                        .accessibilityLabel("商单内容，X 官方付费合作标记")
                }
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
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
    }

    private func articleReadingControls(_ article: ArchivedArticle) -> some View {
        HStack(spacing: 9) {
            HStack(spacing: 3) {
                Button {
                    adjustArticleTextScale(by: -0.1)
                } label: {
                    Text("A−")
                        .font(MarkXTypography.callout.weight(.semibold))
                        .frame(minWidth: 25)
                }
                .buttonStyle(.borderless)
                .help("缩小文章文字")
                .disabled(previewTextScale <= 0.8)

                Button {
                    articlePreviewTextScale = 1.0
                } label: {
                    Text("\(Int((previewTextScale * 100).rounded()))%")
                        .font(MarkXTypography.caption.monospacedDigit())
                        .frame(minWidth: 38)
                }
                .buttonStyle(.borderless)
                .help("恢复 100% 字号")
                .disabled(previewTextScale == 1.0)

                Button {
                    adjustArticleTextScale(by: 0.1)
                } label: {
                    Text("A+")
                        .font(MarkXTypography.callout.weight(.semibold))
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
                    Button("在浏览器订阅 @\(article.authorHandle)") {
                        model.openSubscriptionPage(for: article)
                    }
                    .help("使用设置中选定的同一个浏览器账号完成订阅")
                }
                if model.isArticleActivelyProcessing(article) {
                    Button("停止处理", role: .cancel) { model.stopProcessing(article) }
                } else {
                    Button("重新处理") { model.restartProcessing(article) }
                        .disabled(model.isRunning || model.hasActiveDownloadProgress)
                        .help("重新打开原页并严格校验完整排版")
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(MarkXTypography.title2)
            }
            .menuStyle(.borderlessButton)
            .help("更多文章操作：打开文件、定位、访问原文或重新采集")
        }
        .fixedSize()
    }

    private func articleDetailBody(_ article: ArchivedArticle) -> some View {
        ArticlePreviewContent(article: article, root: model.archiveRoot, textScale: previewTextScale,
            isBusy: model.isRunning || model.hasActiveDownloadProgress) {
                model.restartProcessing(article)
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

        ToolbarItem(placement: .primaryAction) {
            librarySearchField
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

            SettingsLink {
                Label("设置", systemImage: "gearshape")
            }
            .help("打开设置，管理 X 登录验证、存储与本地资料库")
            .accessibilityIdentifier("openSettings")
        }
    }

    private var listTitle: String {
        switch model.sidebarSelection {
        case .all, .none: "全部文章"
        case .today: "今日推文"
        case .commercial: "商单内容"
        case .pending: "等待继续"
        case .failed: "需要处理"
        case .creator(let id): model.creators.first(where: { $0.id == id })?.displayName ?? "博主"
        }
    }

    private var emptyFilterTitle: String {
        if !model.searchText.isEmpty { return model.isSearching ? "正在搜索…" : "没有找到相关文章" }
        return switch model.sidebarSelection {
        case .today: "今天还没有新文章"
        case .commercial: "还没有商单内容"
        case .pending: "没有等待继续的文章"
        case .failed: "没有需要处理的文章"
        case .creator: "这位博主还没有归档文章"
        default: "还没有归档 X Article"
        }
    }

    private var emptyFilterIcon: String {
        switch model.sidebarSelection {
        case .today: "sun.max"
        case .commercial: "tag"
        case .pending: "clock.arrow.circlepath"
        case .failed: "exclamationmark.triangle"
        case .creator: "person.crop.circle"
        default: "tray"
        }
    }

    private var emptyFilterDescription: String {
        if !model.searchText.isEmpty { return "可以换个关键词，或清空搜索查看当前分类的全部文章。" }
        return switch model.sidebarSelection {
        case .today:
            "“今日推文”只显示 X 原始发布时间为今天的文章。"
        case .commercial:
            "这里只列出带有 X 官方 Paid partnership 标记的商单内容。重新处理已归档文章后，标记会补齐。"
        case .pending:
            "没有尚未完成的采集任务。"
        case .failed:
            "没有失败或需要订阅后才能继续的文章。"
        case .creator:
            "可以从右键菜单重新拉取该博主的 X Article。"
        default:
            "添加一个或多个 X 博主，程序只会保存官方 X Article。"
        }
    }

    private var selectedSidebarCreator: Creator? {
        guard case .creator(let id) = model.sidebarSelection else { return nil }
        return model.creators.first { $0.id == id }
    }

    private var selectedArticleCreator: Creator? {
        guard let article = model.selectedArticle else { return nil }
        return model.creators.first { $0.id == article.creatorID }
    }

    private var previewTextScale: Double {
        min(max(articlePreviewTextScale, 0.8), 1.6)
    }

    private func adjustArticleTextScale(by delta: Double) {
        articlePreviewTextScale = min(max((previewTextScale + delta) * 10, 8), 16).rounded() / 10
    }
}

private struct SidebarSectionHeader: View {
    let title: String
    var count: Int? = nil
    var countUnit = "篇文章"
    @Binding var isExpanded: Bool

    var body: some View {
        Button { withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() } } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(MarkXTypography.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primary)
                if let count {
                    Text(count, format: .number.grouping(.never)).font(MarkXTypography.system(size: 10)).monospacedDigit()
                        .accessibilityLabel("\(count) \(countUnit)")
                }
                Spacer(minLength: 4)
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(MarkXTypography.system(size: 9, weight: .semibold))
                    .frame(width: 10)
            }
            .foregroundStyle(.secondary)
            .padding(.trailing, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .padding(.top, 8).padding(.bottom, 5)
        .help(isExpanded ? "折叠\(title)" : "展开\(title)")
    }
}

struct DownloadResultView: View {
    let notice: DownloadResultNotice
    @Environment(\.dismiss) private var dismiss
    private var hasDanger: Bool { notice.metrics.contains { $0.tone == .danger } }
    private var hasWarning: Bool { notice.metrics.contains { $0.tone == .warning } }
    private var statusColor: Color { hasDanger ? .red : hasWarning ? .orange : .green }
    private var subtitle: String {
        hasDanger ? "部分文章处理失败，已保存的内容会保留。" : hasWarning ? "部分文章仍需处理，可以稍后继续。" : "本次任务已结束，下面是处理结果。"
    }
    var body: some View {
        VStack(spacing: 0) {
            MarkXPaneHeader(title: notice.title, subtitle: subtitle,
                symbol: hasDanger || hasWarning ? "exclamationmark.circle" : "checkmark.circle", symbolColor: statusColor)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: MarkXInterface.spacing) {
                    if !notice.metrics.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                            ForEach(notice.metrics, id: \.id) { DownloadResultMetricText(metric: $0) }
                        }
                    }
                    MarkXSection(title: "结果说明") {
                        Text(notice.message).font(MarkXTypography.system(size: 12)).foregroundStyle(.secondary)
                            .lineSpacing(4).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(MarkXInterface.inset)
            }
            MarkXFooter {
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .help("关闭结果窗口")
            }
        }
        .background(MarkXInterface.canvas)
        .font(MarkXTypography.body)
        .frame(width: 620, height: MarkXInterface.sheetHeight(600))
        .onExitCommand { dismiss() }
    }
}

private struct DownloadResultMetricText: View {
    let metric: DownloadResultMetric
    private var color: Color {
        switch metric.tone {
        case .accent: .secondary
        case .positive: .green
        case .neutral: .secondary
        case .warning: .orange
        case .danger: .red
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: metric.systemImage).foregroundStyle(color).frame(width: 13)
                Text(metric.label).foregroundStyle(.secondary)
            }
            .font(MarkXTypography.system(size: 11)).lineLimit(1)
            Text(metric.value).font(MarkXTypography.system(size: 24, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(14).markxSurface()
        .accessibilityElement(children: .combine)
    }
}

private struct CreatorProfileToolbarHeader: View {
    let creator: Creator
    let openProfile: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(creator.displayName)
                .font(MarkXTypography.title2.weight(.semibold))
                .lineLimit(1)

            Button(action: openProfile) {
                HStack(alignment: .center, spacing: 4) {
                    Text("查看主页")
                    Image(systemName: "arrow.up.right")
                        .font(MarkXTypography.caption.weight(.semibold))
                }
                .font(MarkXTypography.body)
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

private struct ArticleTypography {
    let scale: CGFloat

    init(_ scale: Double) {
        self.scale = CGFloat(scale)
    }

    var bodySize: CGFloat { MarkXTypography.readingPointSize(13, scale: scale) }
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

    private var typography: ArticleTypography { ArticleTypography(textScale) }

    var body: some View {
        let orderedMarkers = ArticleListMarkerResolver.orderedMarkers(for: document.blocks)
        LazyVStack(alignment: .leading, spacing: 0) {
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
                        .font(MarkXTypography.reading(size: 12.5, scale: CGFloat(textScale), weight: .semibold))
                    ForEach(document.warnings, id: \.self) { warning in
                        Text("• \(warning)")
                    }
                }
                .font(MarkXTypography.reading(size: 11, scale: CGFloat(textScale)))
                .foregroundStyle(.secondary)
                .padding(12 * typography.scale)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .padding(.top, 8 * typography.scale)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
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
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        case .blankLine:
            Color.clear.frame(height: typography.explicitBlankLineHeight)
        case .heading:
            inlineText
                .font(headingFont)
                .lineSpacing(3 * typography.scale)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
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
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4 * typography.scale)
        case .code:
            ScrollView(.horizontal) {
                Text(block.text)
                    .font(MarkXTypography.reading(size: 13, scale: CGFloat(textScale), design: .monospaced))
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
                                        .font(MarkXTypography.reading(size: 12.5, scale: CGFloat(textScale), weight: cell.isHeader ? .semibold : .regular))
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
                        .font(MarkXTypography.reading(size: 12.5, scale: CGFloat(textScale), design: .monospaced))
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
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var headingFont: Font {
        switch block.level {
        case 0...1: MarkXTypography.reading(size: 22, scale: CGFloat(textScale), weight: .bold)
        case 2: MarkXTypography.reading(size: 18, scale: CGFloat(textScale), weight: .bold)
        default: MarkXTypography.reading(size: 14, scale: CGFloat(textScale), weight: .semibold)
        }
    }

    private var bodyFont: Font {
        MarkXTypography.reading(size: 13, scale: typography.scale)
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
                    if let localPath = media.localCachePath {
                        LocalArticleImage(path: localPath, fallbackURL: url)
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
                        .font(MarkXTypography.reading(size: 11, scale: CGFloat(textScale)))
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
            .font(MarkXTypography.caption)
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

struct ArticleRow: View {
    let article: ArchivedArticle
    let index: Int
    let creator: Creator?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(index, format: .number.grouping(.never))
                .font(MarkXTypography.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 44, alignment: .trailing)
                .layoutPriority(1)
                .accessibilityLabel("第 \(index) 篇")

            VStack(alignment: .leading, spacing: 7) {
                Text(article.title)
                    .font(MarkXTypography.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    if article.isPaidPartnership {
                        CommercialContentBadge()
                    }
                    Text(creator?.displayName ?? "@\(article.authorHandle)")
                    Text("·")
                    Text("@\(creator?.username ?? article.authorHandle)")
                    Spacer()
                    Text(article.publishedAt, style: .date)
                }
                .font(MarkXTypography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                    Text(statusTitle)
                    if article.imageCount > 0 { Text("· \(article.imageCount) 张图") }
                    if article.videoCount > 0 { Text("· \(article.videoCount) 个视频") }
                }
                .font(MarkXTypography.caption)
                .foregroundStyle(.secondary)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
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
        HStack(spacing: 9) {
            Image(systemName: systemImage).font(MarkXTypography.system(size: 14, weight: .regular)).frame(width: 18)
            Text(title).font(MarkXTypography.system(size: 13))
            Spacer(minLength: 4)
            SidebarCountBadge(count: count)
        }
        .frame(minHeight: 27)
        .contentShape(Rectangle())
    }
}

private struct SidebarMetricRow<Icon: View, Title: View, Value: View>: View {
    private let icon: Icon
    private let title: Title
    private let value: Value

    init(
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder title: () -> Title,
        @ViewBuilder value: () -> Value
    ) {
        self.icon = icon()
        self.title = title()
        self.value = value()
    }

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: SidebarMetricBadge.iconColumn, height: SidebarMetricBadge.iconColumn)
            title
                .frame(maxWidth: .infinity, alignment: .leading)
            value
        }
    }
}

private struct SidebarMetricBadge: View {
    static let iconColumn: CGFloat = 18
    static let columnWidth: CGFloat = 56

    let text: String
    let accessibilityLabel: String

    static func fraction(numerator: Int, denominator: Int?) -> String {
        "\(numerator) / \(denominator.map(String.init) ?? "?")"
    }

    var body: some View {
        Text(text)
            .font(MarkXTypography.system(size: 10)).monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: Self.columnWidth, alignment: .trailing)
            .accessibilityLabel(accessibilityLabel)
    }
}

private struct SidebarCountBadge: View {
    let count: Int
    var unit = "篇文章"
    var horizontalPadding: CGFloat = 0
    var body: some View {
        Text(count, format: .number.grouping(.never))
            .font(MarkXTypography.system(size: 11)).monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(minWidth: 22, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("\(count) \(unit)")
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
            return "MarkX 不会绕过 X 的订阅权限。请在会话对应的浏览器中订阅，或切换到已订阅账号，然后重新处理；任务会一直保留。"
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
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: icon)
                        .font(MarkXTypography.title3)
                        .foregroundStyle(color)
                    Text(title)
                        .font(MarkXTypography.headline)
                        .lineLimit(2)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
                Text(detail)
                    .font(MarkXTypography.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if isActive {
                    Button("停止处理", role: .cancel, action: stop)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else if requiresSubscription {
                    Button("在浏览器订阅", action: openSubscription)
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
                        .font(MarkXTypography.caption.weight(.semibold))
                        .foregroundStyle(color)
                    Text(lastError)
                        .font(MarkXTypography.callout)
                        .textSelection(.enabled)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("处理日志").font(MarkXTypography.caption.weight(.semibold))
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
                .font(MarkXTypography.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            .padding(10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.035))
        .contextMenu {
            if isActive {
                Button("停止处理", role: .cancel, action: stop)
            } else {
                if requiresSubscription {
                    Button("在浏览器订阅", action: openSubscription)
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
                .font(MarkXTypography.title3)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(MarkXTypography.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
    }
}

private struct CommercialContentBadge: View {
    var body: some View {
        Text("商单内容")
            .font(MarkXTypography.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.13), in: Capsule())
            .foregroundStyle(.orange)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("商单内容，X 官方付费合作标记")
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
            .font(MarkXTypography.caption.weight(.medium))
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
                Text(progress.stage).font(MarkXTypography.caption.weight(.medium))
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
            .font(MarkXTypography.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.bar)
    }
}

private struct ArticlePreviewContent: View {
    let article: ArchivedArticle
    let root: URL?
    let textScale: Double
    let isBusy: Bool
    let reprocess: () -> Void
    @State private var preview: ArticlePreviewData?
    @State private var loadedKey: PreviewKey?

    private struct PreviewKey: Hashable {
        var id: UUID
        var synced: Date
        var root: URL?
        var path: String?
    }
    private var key: PreviewKey {
        PreviewKey(id: article.id, synced: article.lastSyncedAt, root: root, path: article.markdownPath)
    }

    var body: some View {
        Group {
            if loadedKey != key {
                ProgressView("正在加载正文…").frame(maxWidth: .infinity, minHeight: 200)
            } else if let document = preview?.document {
                ArticleDocumentPreview(document: document, textScale: textScale)
                    .padding(.top, 8 * textScale)
                    .padding(.bottom, 24 * textScale)
            } else if article.markdownPath == nil {
                ContentUnavailableView("正文尚未生成", systemImage: "doc.badge.clock",
                    description: Text("当前状态、错误原因和处理日志已显示在上方。"))
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if article.pipelineState == .committed {
                        Label("文章预览不可用", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text("完整来源快照不可用，下面显示本地 Markdown。").foregroundStyle(.secondary)
                        FixedReprocessButton(isDisabled: isBusy, help: "重新打开原文并恢复完整预览", action: reprocess)
                    }
                    Text(preview?.markdown ?? "无法读取本地 Markdown。")
                        .font(MarkXTypography.reading(.body, design: .monospaced)).textSelection(.enabled)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                .padding(.top, 8).padding(.bottom, 24)
            }
        }
        .task(id: key) {
            let requestedKey = key
            preview = nil
            loadedKey = nil
            let article = article
            let root = root
            let worker = Task.detached(priority: .userInitiated) {
                ArticlePreviewData.load(article: article, root: root)
            }
            let result = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            preview = result
            loadedKey = requestedKey
        }
    }
}

private struct LocalArticleImage: View {
    let path: String
    let fallbackURL: URL
    @State private var thumbnail: CGImage?
    @State private var finished = false

    var body: some View {
        Group {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1).resizable().scaledToFit()
            } else if finished {
                AsyncImage(url: fallbackURL) { image in image.resizable().scaledToFit() }
                    placeholder: { Label("图片暂时无法加载", systemImage: "photo") }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 150)
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: path) {
            thumbnail = nil
            finished = false
            let image = await ArticleThumbnailCache.shared.image(path: path)
            guard !Task.isCancelled else { return }
            thumbnail = image
            finished = true
        }
    }
}
