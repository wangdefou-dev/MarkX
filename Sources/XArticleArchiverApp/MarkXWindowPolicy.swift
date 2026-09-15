import AppKit

enum MarkXWindowPolicy {
    static let mainWindowTitle = "MarkX"
    static let progressWindowTitle = "MarkX 下载进度"
    static let externalEventKeys: Set<String> = ["scheduled-sync"]

    struct Snapshot: Equatable {
        var title: String
        var isPanel: Bool = false
        var hasSheetParent: Bool = false
        var isTitled: Bool = true
    }

    static func isMainLibraryWindow(_ snapshot: Snapshot) -> Bool {
        snapshot.isTitled
            && !snapshot.isPanel
            && !snapshot.hasSheetParent
            && snapshot.title == mainWindowTitle
    }

    static func isProgressWindow(_ snapshot: Snapshot) -> Bool {
        snapshot.title == progressWindowTitle
    }

    static func duplicateMainWindowIndexes(
        in windows: [Snapshot],
        preferredIndex: Int?
    ) -> [Int] {
        duplicateIndexes(
            in: windows,
            preferredIndex: preferredIndex,
            matches: isMainLibraryWindow
        )
    }

    static func duplicateProgressWindowIndexes(
        in windows: [Snapshot],
        preferredIndex: Int?
    ) -> [Int] {
        duplicateIndexes(
            in: windows,
            preferredIndex: preferredIndex,
            matches: isProgressWindow
        )
    }

    @MainActor
    static func mainLibraryWindow(excluding excluded: NSWindow? = nil) -> NSWindow? {
        preferredVisibleWindow(
            in: NSApp.windows.filter { $0 !== excluded && isMainLibraryWindow($0) }
        )
    }

    @MainActor
    static func enforceSingleMainWindow() {
        closeWindows(
            matching: isMainLibraryWindow,
            keeping: mainLibraryWindow()
        )
    }

    @MainActor
    static func closeDuplicateProgressWindows(keeping preferred: NSWindow?) {
        closeWindows(matching: isProgressWindow, keeping: preferred)
    }

    @MainActor
    static func closeRestoredProgressWindows() {
        closeWindows(matching: isProgressWindow, keeping: nil)
    }

    @MainActor
    private static func isMainLibraryWindow(_ window: NSWindow) -> Bool {
        isMainLibraryWindow(snapshot(for: window))
    }

    @MainActor
    private static func isProgressWindow(_ window: NSWindow) -> Bool {
        isProgressWindow(snapshot(for: window))
    }

    @MainActor
    private static func snapshot(for window: NSWindow) -> Snapshot {
        Snapshot(
            title: window.title,
            isPanel: window is NSPanel,
            hasSheetParent: window.sheetParent != nil,
            isTitled: window.styleMask.contains(.titled)
        )
    }

    @MainActor
    private static func preferredVisibleWindow(in windows: [NSWindow]) -> NSWindow? {
        if let key = NSApp.keyWindow, windows.contains(where: { $0 === key }) {
            return key
        }
        if let main = NSApp.mainWindow, windows.contains(where: { $0 === main }) {
            return main
        }
        return windows.first(where: \.isVisible) ?? windows.first
    }

    @MainActor
    private static func closeWindows(
        matching matches: (NSWindow) -> Bool,
        keeping preferred: NSWindow?
    ) {
        let candidates = NSApp.windows.filter(matches)
        guard !candidates.isEmpty else { return }
        let keeper = preferred.flatMap { preferredWindow in
            candidates.first { $0 === preferredWindow }
        }
        for window in candidates where window !== keeper {
            window.close()
        }
    }

    private static func duplicateIndexes(
        in windows: [Snapshot],
        preferredIndex: Int?,
        matches: (Snapshot) -> Bool
    ) -> [Int] {
        let matched = windows.indices.filter { matches(windows[$0]) }
        guard matched.count > 1 else { return [] }
        let keeper: Int
        if let preferredIndex, matched.contains(preferredIndex) {
            keeper = preferredIndex
        } else {
            keeper = matched[0]
        }
        return matched.filter { $0 != keeper }
    }
}
