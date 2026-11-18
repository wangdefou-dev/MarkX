import AppKit
import AVKit
import SwiftUI
import XArticleArchiverCore

struct RootView: View {
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isArticleListFocused: Bool
    @AppStorage("articlePreviewTextScale") private var articlePreviewTextScale = 1.0
    @AppStorage("sidebarLibraryExpanded") private var isLibraryExpanded = true
    @AppStorage("sidebarCollectionsExpanded") private var isCollectionsExpanded = true
    @AppStorage("sidebarCreatorsExpanded") private var isCreatorsExpanded = true
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showingNewCollection = false
    @State private var newCollectionName = ""
    @State private var newCollectionArticleID: UUID?
    @State private var collectionPendingDeletion: ArticleCollection?
    @State private var collectionDrag = CollectionArticleDrag()
    @State private var targetedCollectionID: UUID?
    @State private var collectionNotice: CollectionNotice?

    private struct CollectionNotice {
        let id = UUID()
        let collectionID: UUID
        let collectionName: String
        let alreadyIncluded: Bool

        var title: String { alreadyIncluded ? "已在「\(collectionName)」中" : "已加入「\(collectionName)」" }
    }

    var body: some View {
        libraryDialogs
            .onDisappear {
                collectionDrag.cancel()
                collectionNotice = nil
            }
            .task(id: collectionNotice?.id) {
                guard let id = collectionNotice?.id else { return }
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, collectionNotice?.id == id else { return }
                collectionNotice = nil
            }
            .alert("新建收藏夹", isPresented: $showingNewCollection) {
                TextField("收藏夹名称", text: $newCollectionName)
                Button("取消", role: .cancel) {}
                Button("创建") {
                    isCollectionsExpanded = true
                    model.createCollection(name: newCollectionName, articleID: newCollectionArticleID)
                }
                .disabled(newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.canEditCollections)
            } message: {
                if newCollectionArticleID != nil {
                    Text("创建后，当前文章会加入这个收藏夹。")
                }
            }
            .confirmationDialog(
                "删除收藏夹？",
                isPresented: Binding(
                    get: { collectionPendingDeletion != nil },
                    set: { if !$0 { collectionPendingDeletion = nil } }
                ),
                titleVisibility: .visible,
                presenting: collectionPendingDeletion
            ) { collection in
                Button("删除收藏夹", role: .destructive) { model.deleteCollection(collection) }
                Button("取消", role: .cancel) {}
            } message: { collection in
                Text("删除「\(collection.name)」及其中的收藏关系。文章和归档文件会保留。")
            }
    }

    private var collectionAnimation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.24) }

    private func addArticle(_ articleID: UUID, to collectionID: UUID) {
        guard model.canEditCollections,
              let collection = model.collections.first(where: { $0.id == collectionID }),
              model.articles.contains(where: { $0.id == articleID }) else { return }
        let alreadyIncluded = collection.articleIDs.contains(articleID)
        let notice = CollectionNotice(collectionID: collectionID, collectionName: collection.name,
                                      alreadyIncluded: alreadyIncluded)
        let showNotice = {
            collectionNotice = notice
            AccessibilityNotification.Announcement(notice.title).post()
        }
        if alreadyIncluded {
            showNotice()
        } else {
            model.setArticle(articleID, inCollection: collectionID, included: true, onSaved: showNotice)
        }
    }

    private var collectionFeedback: some View {
        ZStack {
            if let notice = collectionNotice {
                Label {
                    Text(notice.title)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                    .font(MarkXFont.detailStrong)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, MarkXSpace.xl)
                    .padding(.vertical, MarkXSpace.m)
                    .background(.regularMaterial, in: Capsule())
                    .overlay { Capsule().strokeBorder(.green.opacity(0.65)) }
                    .shadow(color: .black.opacity(0.16), radius: 7, y: 3)
                    .padding(.bottom, MarkXSpace.x3)
                    .id(notice.id)
                    .transition(.offset(y: 14).combined(with: .opacity))
            }
        }
        .allowsHitTesting(false)
        .animation(collectionAnimation, value: collectionNotice?.id)
    }

    private var mainContent: some View {
        splitLayout
        .navigationSplitViewStyle(.balanced)
        .modifier(SeamlessToolbar())
        // The visible heading is the list title item; the window title stays
        // "MarkX" (set on each column) because MarkXWindowPolicy matches it.
        .modifier(HiddenWindowTitle())
        .animation(nil, value: model.sidebarSelection)
        .animation(nil, value: model.selectedArticleID)
        .toolbar { toolbar }
        .font(MarkXFont.body)
        .onAppear { model.refreshBrowserStatus() }
        .onChange(of: isWelcomeLayout) { _, _ in
            if !isSidebarVisible { columnVisibility = hiddenSidebarVisibility }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.refreshBrowserStatus() }
            else { collectionDrag.cancel() }
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
    }

    private var libraryAlerts: some View {
        mainContent
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
    }

    private var libraryDialogs: some View {
        libraryAlerts
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

    /// First run and an empty library have nothing to list or read, so the
    /// welcome page spans the whole content area instead of a narrow list column.
    private var isWelcomeLayout: Bool {
        guard model.filteredArticles.isEmpty, selectedSidebarCreator == nil, selectedCollection == nil else {
            return false
        }
        if model.archiveRoot == nil || !model.imageHostVerified { return true }
        return model.isBootstrapped && model.articles.isEmpty
    }

    @ViewBuilder
    private var splitLayout: some View {
        if isWelcomeLayout {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarColumn
            } detail: {
                WelcomeView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(MarkXWindowPolicy.mainWindowTitle)
                    .toolbar {
                        if #available(macOS 26.0, *) {
                            ToolbarSpacer(.flexible)
                        }
                        libraryActions(placement: .automatic)
                    }
                    .background(SplitColumnGuard(columns: [SplitColumnLayout.sidebar]))
                    .navigationSplitViewColumnWidth(min: SplitColumnLayout.detailMinimum, ideal: 900)
            }
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                sidebarColumn
            } content: {
                articleList
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .navigationTitle(MarkXWindowPolicy.mainWindowTitle)
                    .toolbar {
                        listTitleToolbar
                        libraryActions(placement: .primaryAction)
                    }
                    .navigationSplitViewColumnWidth(
                        min: SplitColumnLayout.list.min,
                        ideal: SplitColumnLayout.list.ideal,
                        max: SplitColumnLayout.list.max
                    )
            } detail: {
                detail
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .navigationTitle(MarkXWindowPolicy.mainWindowTitle)
                    .toolbar { articleToolbar }
                    .background(SplitColumnGuard(columns: [SplitColumnLayout.sidebar, SplitColumnLayout.list]))
                    .navigationSplitViewColumnWidth(min: SplitColumnLayout.detailMinimum, ideal: 640)
            }
            // Nothing to search on the welcome page, so only the library has it.
            .searchable(text: $model.searchText, placement: .toolbar, prompt: "搜索标题、博主或正文")
        }
    }

    private var sidebarColumn: some View {
        sidebar
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(MarkXWindowPolicy.mainWindowTitle)
            .navigationSplitViewColumnWidth(
                min: SplitColumnLayout.sidebar.min,
                ideal: SplitColumnLayout.sidebar.ideal,
                max: SplitColumnLayout.sidebar.max
            )
    }

    /// Two-column and three-column split views hide the sidebar differently.
    private var hiddenSidebarVisibility: NavigationSplitViewVisibility {
        isWelcomeLayout ? .detailOnly : .doubleColumn
    }

    private var isSidebarVisible: Bool {
        columnVisibility != .doubleColumn && columnVisibility != .detailOnly
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarLibrary
            if model.isRunning {
                HStack(spacing: MarkXSpace.m) {
                    ProgressView().controlSize(.mini)
                    Text(model.progress.stage).font(MarkXFont.meta).foregroundStyle(MarkXInterface.text2).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, MarkXSpace.xl)
                .padding(.top, MarkXSpace.l)
                .padding(.bottom, MarkXSpace.l)
            }
        }
        .background(.bar)
    }

    private var sidebarLibrary: some View {
        let statistics = model.sidebarStatistics
        return List(selection: $model.sidebarSelection) {
            Section(isExpanded: $isLibraryExpanded) {
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
                    systemImage: "tag",
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
            } header: {
                Text("资料库")
            }
            collectionsSection
            Section(isExpanded: $isCreatorsExpanded) {
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
            } header: {
                creatorHeadingRow
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 32)
    }

    private var collectionsSection: some View {
        Section(isExpanded: $isCollectionsExpanded) {
                ForEach(model.collections) { collection in
                    let isTargeted = targetedCollectionID == collection.id
                    let isConfirmed = collectionNotice?.collectionID == collection.id
                    let highlight: Color = isTargeted ? .orange : .green
                    let icon = isTargeted ? "folder.badge.plus" : isConfirmed ? "checkmark.circle.fill" : "folder"
                    SidebarCountRow(title: collection.name, systemImage: icon,
                                    count: collection.articleIDs.count)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .background {
                            ZStack {
                                CollectionDropRegion(collectionID: collection.id, controller: collectionDrag)
                                RoundedRectangle(cornerRadius: MarkXRadius.control)
                                    .fill(highlight.opacity(0.22))
                                    .overlay { RoundedRectangle(cornerRadius: MarkXRadius.control).strokeBorder(highlight, lineWidth: 2) }
                                    .opacity(isTargeted || isConfirmed ? 1 : 0)
                                    .allowsHitTesting(false)
                                    .animation(collectionAnimation, value: isConfirmed)
                            }
                            // Extend past the label margins to the sidebar's selection edges.
                            .padding(.horizontal, -6)
                        }
                        .listRowInsets(EdgeInsets())
                        .help(collection.name)
                        .tag(AppViewModel.SidebarSelection.collection(collection.id))
                        .contextMenu {
                            Button(role: .destructive) {
                                collectionPendingDeletion = collection
                            } label: {
                                Label("删除收藏夹…", systemImage: "trash")
                            }
                            .disabled(!model.canEditCollections)
                        }
                }
                Button { presentNewCollection() } label: {
                    HStack(spacing: MarkXSpace.m) {
                        SidebarIcon(systemImage: "plus", color: MarkXInterface.text3)
                        Text("新建收藏夹…")
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(MarkXInterface.text2)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canEditCollections)
        } header: {
            Text("收藏夹")
        }
    }

    private func sidebarMetricRow<Icon: View, Title: View, Value: View>(
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder title: () -> Title,
        @ViewBuilder value: () -> Value
    ) -> some View {
        SidebarMetricRow(icon: icon, title: title, value: value)
    }

    private var creatorHeadingRow: some View {
        HStack(spacing: MarkXSpace.xs) {
            Text("博主")
            if model.enabledCreatorCount > 0 {
                Text(model.enabledCreatorCount, format: .number.grouping(.never))
                    .monospacedDigit()
                    .foregroundStyle(MarkXInterface.text3)
                    .accessibilityLabel("\(model.enabledCreatorCount) 位博主")
            }
        }
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
            SidebarIcon(systemImage: model.isCreatorPinned(creator)
                        ? "pin"
                        : creator.isProtected ? "lock" : "person")
        } title: {
            VStack(alignment: .leading, spacing: MarkXSpace.xxs) {
                Text(creator.displayName)
                    .font(MarkXFont.body)
                    .lineLimit(1).help(creator.displayName + " · @" + creator.username)
                Text("@\(creator.username)")
                    .font(MarkXFont.meta)
                    .foregroundStyle(MarkXInterface.text3)
                    .lineLimit(1)
            }
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
        .frame(minHeight: 40)
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

    private var articleList: some View {
        VStack(spacing: 0) {
            if model.isPreparingSearch {
                Text("正在整理历史文章，搜索结果会逐步补齐…")
                    .font(MarkXFont.meta).foregroundStyle(MarkXInterface.text2).padding(MarkXSpace.m)
                Divider()
            }
            Group {
                if !model.filteredArticles.isEmpty {
                    let collectionID = model.selectedCollectionID
                    List(selection: $model.selectedArticleID) {
                        ForEach(Array(model.filteredArticles.enumerated()), id: \.element.id) { index, article in
                            let creator = model.creators.first(where: { $0.id == article.creatorID })
                            ArticleRow(article: article, index: index + 1, creator: creator)
                                .overlay {
                                    CollectionDragSource(
                                        controller: collectionDrag,
                                        title: article.title,
                                        onSelect: {
                                            model.selectedArticleID = article.id
                                            isArticleListFocused = true
                                        },
                                        canDrag: { model.canEditCollections && isSidebarVisible && isCollectionsExpanded },
                                        onTarget: { targetedCollectionID = $0 },
                                        onDrop: { addArticle(article.id, to: $0) }
                                    )
                                    .accessibilityHidden(true)
                                }
                                .tag(article.id)
                                .listRowSeparator(.hidden)
                                .contextMenu {
                                    articleCollectionActions(for: article)
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
                                    if collectionID == nil, ExactCaptureQueuePolicy.needsCapture(article) {
                                        Button(role: .destructive) {
                                            guard model.selectedCollectionID == nil else { return }
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
                                    if collectionID == nil {
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
                    }
                    // Recreate the native row menus when switching collection scope.
                    .id(collectionID)
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .background(MarkXInterface.canvas)
                    .focused($isArticleListFocused)
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                } else if model.archiveRoot == nil || !model.imageHostVerified {
                    ContentUnavailableView {
                        Label("尚未完成配置", systemImage: "gearshape")
                    } description: {
                        Text("选择本地归档目录并确认媒体存储后，才能下载和查看文章。")
                    } actions: {
                        Button("开始配置") { model.showingConnectionSetup = true }
                            .buttonStyle(.markxPillProminent)
                    }
                } else if model.articles.isEmpty, selectedCollection == nil {
                    ContentUnavailableView {
                        Label("还没有归档 X Article", systemImage: "tray")
                    } description: {
                        Text("添加一个或多个 X 博主，程序只会保存官方 X Article，不会再把普通帖子或线程当成文章。")
                    } actions: {
                        Button("开始下载文章") { model.presentDownloadSheet() }
                            .buttonStyle(.markxPillProminent)
                            .help("输入博主主页或 X Article 链接开始下载")
                        Button("生成体验样例") { model.installDemo() }
                            .buttonStyle(.markxPill)
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
        .overlay(alignment: .bottom) { collectionFeedback }
        .safeAreaInset(edge: .bottom) {
            if model.isRunning || model.progress.scannedPosts > 0 {
                TaskProgressBar(progress: model.progress, isRunning: model.isRunning)
            }
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
                .padding(.horizontal, MarkXSpace.pageSide)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .top)
            }
            .id(article.id)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .background(MarkXInterface.reading)
        } else {
            ContentUnavailableView("选择一篇 X Article", systemImage: "doc.richtext", description: Text("这里会按文章排版展示完整正文、图片和视频。"))
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                .background(MarkXInterface.reading)
        }
    }

    private func articleDetailHeader(_ article: ArchivedArticle) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: MarkXSpace.xl) {
                Text(article.title)
                    .font(ArticleTypography(previewTextScale).titleFont)
                    .lineSpacing(ArticleTypography(previewTextScale).titleLineSpacing)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                    .textSelection(.enabled)
            }
            MarkXFlowLayout(spacing: MarkXSpace.m) {
                Button {
                    model.openCreatorProfile(handle: article.authorHandle)
                } label: {
                    HStack(spacing: MarkXSpace.xs) {
                        Text(selectedArticleCreator?.displayName ?? "@\(article.authorHandle)")
                            .font(MarkXFont.detailStrong)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("@\(selectedArticleCreator?.username ?? article.authorHandle)")
                            .lineLimit(1)
                        Image(systemName: "arrow.up.right")
                            .font(MarkXFont.badge)
                            .foregroundStyle(MarkXInterface.text3)
                    }
                }
                .buttonStyle(.plain)
                .help("查看 @\(article.authorHandle) 的 X 主页")
                Text(article.publishedAt, format: .dateTime.year().month().day().hour().minute())
                    .foregroundStyle(MarkXInterface.text3)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .font(MarkXFont.detail)
            .foregroundStyle(MarkXInterface.text2)
            .lineLimit(1)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(.top, MarkXSpace.l)
            MarkXFlowLayout(spacing: MarkXSpace.s) {
                StatusPill(
                    article.pipelineState.displayName,
                    color: article.pipelineState == .committed
                        ? .green
                        : article.pipelineState == .subscriptionRequired ? .purple : .orange
                )
                if article.isPaidPartnership {
                    StatusPill("商单", color: .orange)
                        .help("X 官方 Paid partnership 商单内容标记")
                        .accessibilityLabel("商单内容，X 官方付费合作标记")
                }
                if article.imageCount > 0 {
                    StatusPill("\(article.imageCount) 张图片", color: .blue)
                }
                if article.videoCount > 0 {
                    StatusPill("\(article.videoCount) 个视频", color: .purple)
                }
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
            .padding(.top, MarkXSpace.xl)
        }
        .padding(.top, MarkXSpace.pageTop)
        .padding(.bottom, MarkXSpace.x4)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func articleCollectionActions(for article: ArchivedArticle) -> some View {
        Menu {
            collectionMenuItems(for: article)
        } label: {
            Label {
                Text("收藏到…")
            } icon: {
                Image(systemName: "star").foregroundStyle(.orange)
            }
        }
        .disabled(!model.canEditCollections)
        if let collection = selectedCollection {
            Button {
                model.setArticle(article.id, inCollection: collection.id, included: false)
            } label: {
                Label("移出当前收藏夹", systemImage: "minus.circle")
            }
            .disabled(!model.canEditCollections)
            .help("仅移出当前收藏夹，保留本地文件和其他收藏")
        }
        Divider()
    }

    @ViewBuilder
    private func collectionMenuItems(for article: ArchivedArticle) -> some View {
        ForEach(model.collections) { collection in
            Toggle(collection.name, isOn: Binding(
                get: { model.collections.first { $0.id == collection.id }?.articleIDs.contains(article.id) == true },
                set: { included in
                    if included {
                        addArticle(article.id, to: collection.id)
                    } else {
                        model.setArticle(article.id, inCollection: collection.id, included: false)
                    }
                }
            ))
        }
        if !model.collections.isEmpty { Divider() }
        Button {
            presentNewCollection(articleID: article.id)
        } label: {
            Label("新建收藏夹…", systemImage: "folder.badge.plus")
        }
    }

    private func presentNewCollection(articleID: UUID? = nil) {
        newCollectionName = ""
        newCollectionArticleID = articleID
        showingNewCollection = true
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

    }

    @ToolbarContentBuilder
    private var listTitleToolbar: some ToolbarContent {
        if selectedSidebarCreator == nil {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { listHeading }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { listHeading }
            }
        }
    }

    private var listHeading: some View {
        HStack(alignment: .firstTextBaseline, spacing: MarkXSpace.s) {
            Text(listTitle).font(MarkXFont.columnTitle)
            if !listSubtitle.isEmpty {
                Text(listSubtitle).font(MarkXFont.detail).foregroundStyle(MarkXInterface.text3).monospacedDigit()
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, MarkXSpace.xs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Library-wide actions sit over the list column (like Mail's compose).
    /// Settings live in the app menu (⌘,), not the toolbar.
    @ToolbarContentBuilder
    private func libraryActions(placement: ToolbarItemPlacement) -> some ToolbarContent {
        ToolbarItemGroup(placement: placement) {
            Button {
                model.presentDownloadSheet()
            } label: {
                Label("下载文章", systemImage: "square.and.arrow.down")
            }
            .disabled(model.isRunning || model.hasActiveDownloadProgress)
            .help("输入博主主页或 X Article 链接开始下载（⌘N）")

            Button {
                model.requestSyncAll()
            } label: {
                Label("同步博主", systemImage: SyncVisualStyle.symbolName)
            }
            .disabled(model.isRunning || model.hasActiveDownloadProgress || model.enabledCreatorCount == 0)
            .help("检查所有已跟踪博主的新文章（⌘R）")

            if model.hasActiveDownloadProgress {
                Button {
                    model.showDownloadProgressWindow()
                } label: {
                    Label("下载进度", systemImage: "arrow.down.circle")
                }
                .help("打开后台下载队列和当前进度")
            }
            if model.isRunning || model.hasActiveDownloadProgress {
                Button(role: .cancel) { model.cancelCurrentTask() } label: {
                    Label("停止", systemImage: "stop.circle")
                }
                .help("安全停止当前任务，已完成内容保留（⌘.）")
            }
        }
    }

    /// Actions for the selected article sit over the reading column.
    @ToolbarContentBuilder
    private var articleToolbar: some ToolbarContent {
        if let article = model.selectedArticle {
            ToolbarItemGroup(placement: .primaryAction) {
                Menu {
                    collectionMenuItems(for: article)
                } label: {
                    Label("收藏", systemImage: model.collections.contains { $0.articleIDs.contains(article.id) }
                          ? "star.fill" : "star")
                }
                .disabled(!model.canEditCollections)
                .help("加入或移出收藏夹")

                Button {
                    model.openSource()
                } label: {
                    Label("打开原文", systemImage: "safari")
                }
                .help("在浏览器中打开 X 原文（⌘L）")

                Menu {
                    articleMoreItems(for: article)
                } label: {
                    Label("更多", systemImage: "ellipsis")
                }
                .help("打开 Markdown、在 Finder 中显示、重新处理或删除")
            }
        }
    }

    @ViewBuilder
    private func articleMoreItems(for article: ArchivedArticle) -> some View {
        Button("打开 Markdown") { model.openSelectedArticle() }
        Button("在 Finder 中显示") { model.revealSelectedArticle() }
        Divider()
        if article.pipelineState == .subscriptionRequired {
            Button("在浏览器订阅 @\(article.authorHandle)") { model.openSubscriptionPage(for: article) }
        }
        if model.isArticleActivelyProcessing(article) {
            Button("停止处理") { model.stopProcessing(article) }
        } else {
            Button("重新处理") { model.restartProcessing(article) }
                .disabled(model.isRunning || model.hasActiveDownloadProgress)
        }
        if model.selectedCollectionID == nil {
            Divider()
            Button("删除文章…", role: .destructive) { model.requestDeleteArticle(article) }
                .disabled(model.isRunning || model.hasActiveDownloadProgress)
        }
    }

    private var listSubtitle: String {
        let count = model.filteredArticles.count
        return count == 0 ? "" : "\(count) 篇"
    }

    private var listTitle: String {
        switch model.sidebarSelection {
        case .all, .none: "全部文章"
        case .today: "今日推文"
        case .commercial: "商单内容"
        case .pending: "等待继续"
        case .failed: "需要处理"
        case .collection: selectedCollection?.name ?? "收藏夹"
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
        case .collection: "这个收藏夹还是空的"
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
        case .collection: "star"
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
        case .collection:
            "在阅读页点五角星，或右键点击文章，选择这个收藏夹。"
        case .creator:
            "可以从右键菜单重新拉取该博主的 X Article。"
        default:
            "添加一个或多个 X 博主，程序只会保存官方 X Article。"
        }
    }

    private var selectedCollection: ArticleCollection? {
        guard let id = model.selectedCollectionID else { return nil }
        return model.collections.first { $0.id == id }
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
            ScrollView {
                VStack(alignment: .leading, spacing: MarkXInterface.spacing) {
                    if !notice.metrics.isEmpty {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: MarkXSpace.m), count: 3), spacing: MarkXSpace.m) {
                            ForEach(notice.metrics, id: \.id) { DownloadResultMetricText(metric: $0) }
                        }
                    }
                    MarkXSection(title: "结果说明") {
                        Text(notice.message).font(MarkXFont.detail).foregroundStyle(MarkXInterface.text2)
                            .lineSpacing(4).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(MarkXInterface.inset)
            }
            MarkXFooter {
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.markxPillProminent)
                    .help("关闭结果窗口")
            }
        }
        .background(MarkXInterface.canvas)
        .font(MarkXFont.body)
        .frame(width: 620, height: MarkXInterface.sheetHeight(600))
        .onExitCommand { dismiss() }
    }
}

private struct DownloadResultMetricText: View {
    let metric: DownloadResultMetric
    private var color: Color {
        switch metric.tone {
        case .accent: MarkXInterface.text3
        case .positive: .green
        case .neutral: MarkXInterface.text3
        case .warning: .orange
        case .danger: .red
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: MarkXSpace.m) {
            HStack(spacing: MarkXSpace.s) {
                StatusDot(color: color)
                Text(metric.label).foregroundStyle(MarkXInterface.text2)
            }
            .font(MarkXFont.meta).lineLimit(1)
            Text(metric.value).font(MarkXFont.metric).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .padding(MarkXSpace.l).markxSurface()
        .accessibilityElement(children: .combine)
    }
}

private struct CreatorProfileToolbarHeader: View {
    let creator: Creator
    let openProfile: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: MarkXSpace.m) {
            Text(creator.displayName)
                .font(MarkXFont.title)
                .lineLimit(1)

            Button(action: openProfile) {
                HStack(alignment: .center, spacing: MarkXSpace.xs) {
                    Text("查看主页")
                    Image(systemName: "arrow.up.right")
                        .font(MarkXFont.metaStrong)
                }
                .font(MarkXFont.body)
                .foregroundStyle(MarkXInterface.text2)
                .fixedSize(horizontal: true, vertical: false)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("查看 @\(creator.username) 的 X 主页")
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .frame(height: 36, alignment: .center)
        .padding(.leading, MarkXSpace.l)
    }
}

/// Reading typography, after Fog's prose rules (Web/thread/body.css):
/// paragraphs 1.25em apart, line height ~1.6 for CJK, headings in medium
/// weight only slightly larger than the text with 1.25em above and 0.75em
/// below, list items 0.5em apart with grey bullets, quotes as a 2pt grey rule
/// beside grey text. Every value scales with the reader's zoom.
struct ArticleTypography {
    let scale: CGFloat

    init(_ scale: Double) {
        self.scale = CGFloat(scale)
    }

    /// 15pt text at 100% (MarkX reading text is interface + 2pt).
    var bodySize: CGFloat { MarkXTypography.readingPointSize(13, scale: scale) }
    var em: CGFloat { bodySize }

    var titleFont: Font { MarkXTypography.reading(size: 22, scale: scale, weight: .medium) }
    var titleLineSpacing: CGFloat { 0.25 * MarkXTypography.readingPointSize(22, scale: scale) }

    func headingSize(level: Int) -> CGFloat {
        switch level {
        case 0...1: bodySize * 1.4
        case 2: bodySize * 1.22
        default: bodySize * 1.1
        }
    }

    var bodyLineSpacing: CGFloat { 0.5 * em }
    var headingLineSpacing: CGFloat { 0.2 * em }
    var paragraphSpacing: CGFloat { 1.15 * em }
    var headingTopSpacing: CGFloat { 1.6 * em }
    var headingBottomSpacing: CGFloat { 0.8 * em }
    var listItemSpacing: CGFloat { 0.5 * em }
    var listGroupSpacing: CGFloat { 1.15 * em }
    var listIndent: CGFloat { 1.25 * em }
    var listMarkerGap: CGFloat { 0.5 * em }
    var listMarkerWidth: CGFloat { 1.25 * em }
    var quoteSpacing: CGFloat { 1.15 * em }
    var blockSpacing: CGFloat { 1.25 * em }
    var explicitBlankLineHeight: CGFloat { 0.75 * em }
    var smallSize: CGFloat { 0.857 * em }
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
                VStack(alignment: .leading, spacing: 0.4 * typography.em) {
                    Label("原始排版说明", systemImage: "info.circle")
                        .font(.system(size: typography.smallSize, weight: .medium))
                    ForEach(document.warnings, id: \.self) { warning in
                        Text("• \(warning)")
                    }
                }
                .font(.system(size: typography.smallSize))
                .foregroundStyle(MarkXInterface.text2)
                .padding(0.8 * typography.em)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MarkXInterface.wash, in: RoundedRectangle(cornerRadius: MarkXRadius.card))
                .padding(.top, 0.5 * typography.em)
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
                .lineSpacing(typography.headingLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        case .unorderedListItem:
            listRow(marker: unorderedListMarker)
        case .orderedListItem:
            listRow(marker: resolvedOrderedMarker ?? "1.")
        case .quote:
            HStack(alignment: .top, spacing: 0.8 * typography.em) {
                Rectangle()
                    .fill(MarkXInterface.washStrong)
                    .frame(width: 2)
                inlineText
                    .font(bodyFont)
                    .foregroundStyle(MarkXInterface.text2)
                    .lineSpacing(typography.bodyLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 0.15 * typography.em)
        case .code:
            ScrollView(.horizontal) {
                Text(block.text)
                    .font(.system(size: typography.smallSize, design: .monospaced))
                    .lineSpacing(0.6 * typography.smallSize)
                    .padding(.vertical, 0.75 * typography.em)
                    .padding(.horizontal, typography.em)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MarkXInterface.wash, in: RoundedRectangle(cornerRadius: MarkXRadius.control))
        case .divider:
            Rectangle().fill(MarkXInterface.washStrong).frame(height: 1)
                .padding(.vertical, 0.75 * typography.em)
        case .table:
            if let rows = block.tableRows, !rows.isEmpty {
                ScrollView(.horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    tableCellText(cell)
                                        .font(.system(size: typography.smallSize, weight: cell.isHeader ? .medium : .regular))
                                        .lineSpacing(0.4 * typography.smallSize)
                                        .padding(.horizontal, 0.8 * typography.em)
                                        .padding(.vertical, 0.55 * typography.em)
                                        .frame(
                                            minWidth: CGFloat(140 * max(1, cell.columnSpan)),
                                            maxWidth: CGFloat(340 * max(1, cell.columnSpan)),
                                            alignment: .leading
                                        )
                                        .background(cell.isHeader ? MarkXInterface.wash : Color.clear)
                                        .overlay(Rectangle().stroke(MarkXInterface.hairline, lineWidth: 0.5))
                                }
                            }
                        }
                    }
                    .padding(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: MarkXRadius.control).stroke(MarkXInterface.hairline))
                .clipShape(RoundedRectangle(cornerRadius: MarkXRadius.control))
            } else {
                ScrollView(.horizontal) {
                    Text(block.text)
                        .font(.system(size: typography.smallSize, design: .monospaced))
                        .lineSpacing(0.6 * typography.smallSize)
                        .padding(0.8 * typography.em)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MarkXInterface.wash, in: RoundedRectangle(cornerRadius: MarkXRadius.control))
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
            .padding(typography.em)
            .frame(maxWidth: .infinity, alignment: .leading)
            .markxSurface()
        case .unsupported:
            if !block.text.isEmpty {
                inlineText
                    .font(bodyFont)
                    .foregroundStyle(MarkXInterface.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var headingFont: Font {
        .system(size: typography.headingSize(level: block.level), weight: .medium)
    }

    private var bodyFont: Font {
        MarkXTypography.reading(size: 13, scale: typography.scale)
    }

    private func listRow(marker: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: typography.listMarkerGap) {
            Text(marker)
                .foregroundStyle(block.kind == .unorderedListItem ? MarkXInterface.text3 : Color.primary)
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
            VStack(alignment: .leading, spacing: 0.5 * typography.em) {
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
                                    .foregroundStyle(MarkXInterface.text2)
                                    .frame(maxWidth: .infinity, minHeight: 150)
                            @unknown default:
                                EmptyView()
                            }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: MarkXRadius.card))
                .overlay(RoundedRectangle(cornerRadius: MarkXRadius.card).stroke(MarkXInterface.hairline))

                if let altText = media.altText, !altText.isEmpty {
                    Text(altText)
                        .font(.system(size: typography.smallSize))
                        .lineSpacing(0.3 * typography.smallSize)
                        .foregroundStyle(MarkXInterface.text2)
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
        VStack(alignment: .leading, spacing: MarkXSpace.m) {
            ArchivedAVPlayerView(url: url)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: MarkXRadius.card))
                .overlay(RoundedRectangle(cornerRadius: MarkXRadius.card).stroke(MarkXInterface.hairline))
            Link(destination: url) {
                Label("在默认播放器中打开视频", systemImage: "arrow.up.right.square")
            }
            .font(MarkXFont.meta)
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
        HStack(alignment: .firstTextBaseline, spacing: MarkXSpace.m) {
            Text(index, format: .number.grouping(.never))
                .font(MarkXFont.meta.monospacedDigit())
                .foregroundStyle(MarkXInterface.text3)
                .lineLimit(1)
                .frame(minWidth: 24, alignment: .trailing)
                .fixedSize()
                .accessibilityLabel("第 \(index) 篇")

            VStack(alignment: .leading, spacing: MarkXSpace.xs) {
                Text(article.title)
                    .font(MarkXFont.headline)
                    .foregroundStyle(.primary)
                    .lineSpacing(MarkXSpace.xxs)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                HStack(spacing: MarkXSpace.s) {
                    if article.isPaidPartnership {
                        CommercialContentBadge()
                    }
                    Text(creator?.displayName ?? "@\(article.authorHandle)")
                        .foregroundStyle(MarkXInterface.text2)
                    Text("@\(creator?.username ?? article.authorHandle)")
                        .foregroundStyle(MarkXInterface.text3)
                    Spacer(minLength: MarkXSpace.m)
                    Text(article.publishedAt, style: .date)
                        .foregroundStyle(MarkXInterface.text3)
                        .monospacedDigit()
                }
                .font(MarkXFont.meta)
                .lineLimit(1)
                HStack(spacing: MarkXSpace.s) {
                    StatusDot(color: statusColor)
                    Text(statusTitle)
                    if article.imageCount > 0 { Text("· \(article.imageCount) 张图") }
                    if article.videoCount > 0 { Text("· \(article.videoCount) 个视频") }
                }
                .font(MarkXFont.meta)
                .foregroundStyle(MarkXInterface.text2)
                .lineLimit(1)
                .accessibilityElement(children: .combine)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, MarkXSpace.m + MarkXSpace.xxs)
        .padding(.trailing, MarkXSpace.xs)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .alignmentGuide(.listRowSeparatorTrailing) { dimensions in dimensions.width }
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
        // Native sidebar row and badge (macOS hides a zero badge). Icons are
        // one monochrome outline set in secondary grey, as in Fog's sidebar.
        Label {
            Text(title)
        } icon: {
            SidebarIcon(systemImage: systemImage)
        }
        .badge(count)
    }
}

/// The one sidebar icon treatment: monochrome, secondary grey, fixed column.
private struct SidebarIcon: View {
    let systemImage: String
    var color: Color = MarkXInterface.text2

    var body: some View {
        Image(systemName: systemImage)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(color)
            .frame(width: SidebarMetricBadge.iconColumn)
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
        HStack(spacing: MarkXSpace.m) {
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
            .font(MarkXFont.badge).monospacedDigit()
            .foregroundStyle(MarkXInterface.text2)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: Self.columnWidth, alignment: .trailing)
            .accessibilityLabel(accessibilityLabel)
    }
}

private struct FixedReprocessButton: View {
    let isDisabled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("重新处理", systemImage: "arrow.clockwise")
                .lineLimit(1)
        }
        .buttonStyle(.markxCompactProminent)
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

    var body: some View {
        VStack(alignment: .leading, spacing: MarkXSpace.l) {
            VStack(alignment: .leading, spacing: MarkXSpace.s) {
                HStack(alignment: .firstTextBaseline, spacing: MarkXSpace.m) {
                    StatusDot(color: color, size: 8)
                    Text(title)
                        .font(MarkXFont.headline)
                        .lineLimit(2)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
                Text(detail)
                    .font(MarkXFont.meta)
                    .foregroundStyle(MarkXInterface.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: MarkXSpace.m) {
                Spacer(minLength: 0)
                if isActive {
                    Button("停止处理", systemImage: "stop", role: .cancel, action: stop)
                        .buttonStyle(.markxCompact)
                } else if requiresSubscription {
                    Button("在浏览器订阅", systemImage: "arrow.up.right", action: openSubscription)
                        .buttonStyle(.markxCompact)
                    Button("订阅后重新处理", action: restart)
                        .buttonStyle(.markxCompactProminent)
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
                VStack(alignment: .leading, spacing: MarkXSpace.xs) {
                    Text(requiresSubscription ? "访问说明" : "错误原因")
                        .font(MarkXFont.metaStrong)
                        .foregroundStyle(color)
                    Text(lastError)
                        .font(MarkXFont.detail)
                        .textSelection(.enabled)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                .padding(MarkXSpace.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: MarkXRadius.card))
            }

            VStack(alignment: .leading, spacing: MarkXSpace.s) {
                Text("处理日志").font(MarkXFont.metaStrong).foregroundStyle(MarkXInterface.text2)
                ScrollView {
                    VStack(alignment: .leading, spacing: MarkXSpace.xs) {
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
                .font(MarkXFont.meta.monospaced())
                .foregroundStyle(MarkXInterface.text2)
                .textSelection(.enabled)
            }
            .padding(MarkXSpace.l)
            .background(MarkXInterface.wash, in: RoundedRectangle(cornerRadius: MarkXRadius.card))
        }
        .padding(.horizontal, MarkXSpace.x3)
        .padding(.vertical, MarkXSpace.xl)
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

/// Fog chip: 6pt corners, hairline border, a small coloured square marker.
private struct CommercialContentBadge: View {
    var body: some View {
        HStack(spacing: MarkXSpace.xs) {
            StatusDot(color: .orange)
            Text("商单")
        }
        .font(MarkXFont.badge)
        .foregroundStyle(MarkXInterface.text2)
        .padding(.horizontal, MarkXSpace.s)
        .frame(height: 18)
        .overlay(RoundedRectangle(cornerRadius: MarkXRadius.control - 2).strokeBorder(MarkXInterface.hairline, lineWidth: 1))
        .fixedSize()
        .accessibilityLabel("商单内容，X 官方付费合作标记")
    }
}

/// Status marker shared by rows and chips (Fog `.chip .dot`: 2pt-rounded square).
struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: size, height: size)
            .accessibilityHidden(true)
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
        HStack(spacing: MarkXSpace.s) {
            StatusDot(color: color)
            Text(title)
        }
        .font(MarkXFont.metaStrong)
        .foregroundStyle(.primary)
        .padding(.horizontal, MarkXSpace.m)
        .frame(height: 24)
        .background(MarkXInterface.surface, in: RoundedRectangle(cornerRadius: MarkXRadius.control))
        .overlay(RoundedRectangle(cornerRadius: MarkXRadius.control).strokeBorder(MarkXInterface.hairline, lineWidth: 1))
    }
}

private struct TaskProgressBar: View {
    let progress: SyncProgress
    let isRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: MarkXSpace.m) {
            HStack {
                if isRunning { ProgressView().controlSize(.small) }
                Text(progress.stage).font(MarkXFont.metaStrong)
                Spacer()
            }
            HStack(spacing: MarkXSpace.l) {
                Label("X API 0", systemImage: "checkmark.shield")
                    .foregroundStyle(.green)
                Text("发现 \(progress.discoveredArticles)")
                Text("完成 \(progress.completedArticles)")
                if progress.skippedArticles > 0 { Text("跳过 \(progress.skippedArticles)") }
                Text("图片 \(progress.uploadedImages)")
                Text("视频 \(progress.uploadedVideos)")
                if progress.failedArticles > 0 { Text("失败 \(progress.failedArticles)").foregroundStyle(.red) }
            }
            .font(MarkXFont.badge)
            .foregroundStyle(MarkXInterface.text2)
        }
        .padding(MarkXSpace.l)
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
                VStack(alignment: .leading, spacing: MarkXSpace.l) {
                    if article.pipelineState == .committed {
                        Label("文章预览不可用", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text("完整来源快照不可用，下面显示本地 Markdown。").foregroundStyle(MarkXInterface.text2)
                        FixedReprocessButton(isDisabled: isBusy, help: "重新打开原文并恢复完整预览", action: reprocess)
                    }
                    Text(preview?.markdown ?? "无法读取本地 Markdown。")
                        .font(MarkXTypography.reading(.body, design: .monospaced)).textSelection(.enabled)
                }
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
                .padding(.top, MarkXSpace.m).padding(.bottom, MarkXSpace.x3)
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

private struct HiddenWindowTitle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbar(removing: .title)
        } else {
            content
        }
    }
}

/// Lets content run under the title bar, without a separate toolbar strip.
private struct SeamlessToolbar: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
        }
    }
}
