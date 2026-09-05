import Darwin
import Foundation
import XArticleArchiverCore

enum ScheduledSyncLaunchAgentError: LocalizedError {
    case launchctlFailed(String)

    var errorDescription: String? {
        switch self {
        case .launchctlFailed(let detail):
            "无法注册 macOS 后台定时任务：\(detail)"
        }
    }
}

enum ScheduledSyncLaunchAgentManager {
    static var propertyListURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents", directoryHint: .isDirectory)
            .appending(path: "\(ScheduledSyncLaunchAgentDescriptor.label).plist")
    }

    static func apply(_ configuration: ScheduledSyncConfiguration) throws {
        if !configuration.isEnabled {
            try remove()
            return
        }

        let directory = propertyListURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try ScheduledSyncLaunchAgentDescriptor.propertyListData(for: configuration)

        _ = try? runLaunchctl([
            "bootout",
            "gui/\(getuid())/\(ScheduledSyncLaunchAgentDescriptor.label)"
        ], allowsFailure: true)
        try data.write(to: propertyListURL, options: .atomic)
        try runLaunchctl([
            "bootstrap",
            "gui/\(getuid())",
            propertyListURL.path
        ])
        try runLaunchctl([
            "enable",
            "gui/\(getuid())/\(ScheduledSyncLaunchAgentDescriptor.label)"
        ])
    }

    static func remove() throws {
        _ = try? runLaunchctl([
            "bootout",
            "gui/\(getuid())/\(ScheduledSyncLaunchAgentDescriptor.label)"
        ], allowsFailure: true)
        if FileManager.default.fileExists(atPath: propertyListURL.path) {
            try FileManager.default.removeItem(at: propertyListURL)
        }
    }

    @discardableResult
    private static func runLaunchctl(
        _ arguments: [String],
        allowsFailure: Bool = false
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let detail = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if process.terminationStatus != 0 && !allowsFailure {
            throw ScheduledSyncLaunchAgentError.launchctlFailed(
                detail.isEmpty ? "launchctl 退出码 \(process.terminationStatus)" : detail
            )
        }
        return detail
    }
}
