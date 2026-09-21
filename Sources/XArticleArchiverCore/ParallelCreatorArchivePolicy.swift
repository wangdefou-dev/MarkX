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
