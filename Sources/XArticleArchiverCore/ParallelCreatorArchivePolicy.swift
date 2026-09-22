import Foundation

/// Coordinates reading each creator's Articles list and saving article bodies
/// as two independent pipelines. One creator's list can start downloading
/// while the next creator is still being scanned.
public enum ParallelCreatorArchivePolicy {
    public struct QueueMerge: Equatable, Sendable {
        public var acceptedPostIDs: [String]
        public var duplicateCount: Int

        public init(acceptedPostIDs: [String], duplicateCount: Int) {
            self.acceptedPostIDs = acceptedPostIDs
            self.duplicateCount = duplicateCount
        }
    }

    public static func mergeQueue(
        existingPostIDs: [String],
        incomingPostIDs: [String]
    ) -> QueueMerge {
        var seen = Set(existingPostIDs)
        var accepted: [String] = []
        var duplicates = 0
        for postID in incomingPostIDs {
            if seen.insert(postID).inserted {
                accepted.append(postID)
            } else {
                duplicates += 1
            }
        }
        return QueueMerge(acceptedPostIDs: accepted, duplicateCount: duplicates)
    }

    /// When the download queue drained before the next list arrived, the next
    /// capture index is the first newly appended item.
    public static func nextIndexAfterAppending(
        previousCount: Int,
        appendedCount: Int,
        currentIndex: Int,
        waitingForMore: Bool
    ) -> Int {
        if waitingForMore, appendedCount > 0 {
            return previousCount
        }
        return currentIndex
    }

    public static func shouldFinishSession(
        discoveryFinished: Bool,
        captureIdle: Bool
    ) -> Bool {
        discoveryFinished && captureIdle
    }
}

/// Keeps bulk archive jobs from pinning a single X.com WKWebView for tens of
/// thousands of navigations, or holding the whole download queue in RAM.
public enum BrowserProcessBudget {
    public static let capturePagesPerRecycle = 12
    public static let discoveryCreatorsPerRecycle = 4
    public static let inMemoryCaptureQueueLimit = 32
    public static let keepCompletedInMemory = 6
    public static let progressListWindow = 20
    public static let refillBelowRemaining = 8

    public static func shouldRecycleCapture(pagesSinceRecycle: Int) -> Bool {
        pagesSinceRecycle >= capturePagesPerRecycle
    }

    public static func shouldRecycleDiscovery(creatorsSinceRecycle: Int) -> Bool {
        creatorsSinceRecycle >= discoveryCreatorsPerRecycle
    }

    public static func acceptedCapacity(currentCount: Int, incomingCount: Int) -> Int {
        max(0, min(incomingCount, inMemoryCaptureQueueLimit - currentCount))
    }

    public static func compactDropCount(currentIndex: Int) -> Int {
        max(0, currentIndex - keepCompletedInMemory)
    }

    public static func remainingAfterCurrent(count: Int, currentIndex: Int) -> Int {
        max(0, count - currentIndex - 1)
    }

    public static func progressWindowRange(count: Int, currentIndex: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let clampedIndex = min(max(currentIndex, 0), count - 1)
        let start = max(0, clampedIndex - 4)
        let end = min(count, max(clampedIndex + 1, start + progressListWindow))
        return start..<end
    }
}
