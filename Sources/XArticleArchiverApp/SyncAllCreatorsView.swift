import SwiftUI

enum SyncVisualStyle {
    static let symbolName = "arrow.clockwise"
    static let iconSize: CGFloat = 14
}

struct SyncAllCreatorsView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case now, schedule
        var id: String { rawValue }
        var title: String { self == .now ? "立即同步" : "定时同步" }
    }
    @EnvironmentObject private var model: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .now
    @State private var articleLimit = 10
    @State private var downloadAllArticles = false
    @State private var resolveTotalCount = false
    @State private var scheduleEnabled = false
    @State private var scheduleTime = Date()
    @State private var scheduleArticleLimit = 10
    @State private var loadedSchedule = false
    @State private var isSavingSchedule = false

    var body: some View {
        VStack(spacing: 0) {
            MarkXPaneHeader(title: "同步博主文章", onClose: { if !isSavingSchedule { dismiss() } })
            VStack(alignment: .leading, spacing: MarkXSpace.xl) {
                Picker("同步方式", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).disabled(isSavingSchedule)
                if mode == .now { immediateGroup } else { scheduleGroup }
                if mode == .now || scheduleEnabled { readinessRow }
            }
            .padding(.horizontal, MarkXInterface.inset)
            MarkXFooter {
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(isSavingSchedule)
                if mode == .now {
                    Button("同步 \(model.enabledCreatorCount) 位博主") {
                        model.startSyncAll(articleLimit: downloadAllArticles ? nil : articleLimit,
                            resolveTotalCount: downloadAllArticles || resolveTotalCount)
                    }
                    .buttonStyle(.markxPillProminent).keyboardShortcut(.defaultAction)
                    .disabled(!canStartNow)
                } else {
                    Button(isSavingSchedule ? "正在保存…" : "保存", action: saveSchedule)
                        .buttonStyle(.markxPillProminent).keyboardShortcut(.defaultAction)
                        .disabled(!canSaveSchedule)
                }
            }
        }
        .background(MarkXInterface.canvas)
        .font(MarkXFont.body)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: loadScheduleOnce)
        .interactiveDismissDisabled(isSavingSchedule)
    }

    private var immediateGroup: some View {
        MarkXGroup {
            MarkXRow(title: "范围") {
                Picker("范围", selection: $downloadAllArticles) {
                    Text("最近").tag(false)
                    Text("全部").tag(true)
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            if !downloadAllArticles {
                MarkXRow(title: "每位博主") { ArticleLimitControl(limit: $articleLimit) }
                MarkXRow(title: "同时刷新线上总数") {
                    Toggle("同时刷新线上总数", isOn: $resolveTotalCount)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
            }
        }
    }

    private var scheduleGroup: some View {
        MarkXGroup(footer: lastScheduledRunDescription) {
            MarkXRow(title: "每天自动同步") {
                Toggle("每天自动同步", isOn: $scheduleEnabled)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            if scheduleEnabled {
                MarkXRow(title: "时间") {
                    DatePicker("时间", selection: $scheduleTime, displayedComponents: .hourAndMinute)
                        .labelsHidden().fixedSize()
                }
                MarkXRow(title: "每位博主") { ArticleLimitControl(limit: $scheduleArticleLimit) }
            }
        }
    }

    @ViewBuilder private var readinessRow: some View {
        if !readinessWarning.isEmpty {
            Button {
                dismiss()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(220))
                    model.presentConnectionSetup(focusing: .imageHost)
                }
            } label: {
                MarkXInfoLine(symbol: "exclamationmark.circle", text: readinessWarning, color: .orange)
            }
            .buttonStyle(.plain).help("前往连接与存储配置")
            .padding(.horizontal, MarkXSpace.xs)
        }
    }

    private var canStartNow: Bool {
        model.enabledCreatorCount > 0 && model.archiveRoot != nil && model.imageHostVerified
    }

    private var canSaveSchedule: Bool {
        !isSavingSchedule && (!scheduleEnabled || canStartNow)
    }

    private var readinessWarning: String {
        if model.archiveRoot == nil { return "未选择归档目录" }
        if !model.imageHostVerified { return "媒体存储未就绪" }
        if model.enabledCreatorCount == 0 { return "还没有已跟踪博主" }
        return ""
    }

    private var lastScheduledRunDescription: String {
        guard let date = model.scheduledSyncLastRunAt else {
            return model.scheduledSyncLastResult
        }
        return "\(date.formatted(date: .abbreviated, time: .shortened)) · \(model.scheduledSyncLastResult)"
    }

    private func loadScheduleOnce() {
        guard !loadedSchedule else { return }
        loadedSchedule = true
        scheduleEnabled = model.scheduledSyncEnabled
        scheduleArticleLimit = model.scheduledSyncArticleLimit
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.hour = model.scheduledSyncHour
        components.minute = model.scheduledSyncMinute
        scheduleTime = Calendar.current.date(from: components) ?? Date()
    }

    private func saveSchedule() {
        let components = Calendar.current.dateComponents([.hour, .minute], from: scheduleTime)
        isSavingSchedule = true
        Task {
            let success = await model.saveScheduledSync(
                enabled: scheduleEnabled,
                hour: components.hour ?? 2,
                minute: components.minute ?? 0,
                articleLimit: scheduleArticleLimit
            )
            isSavingSchedule = false
            if success { dismiss() }
        }
    }
}
