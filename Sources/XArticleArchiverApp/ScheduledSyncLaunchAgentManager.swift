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

struct ScheduledSyncLaunchctlCommand: Equatable {
    var arguments: [String]
    var required: Bool
}

enum ScheduledSyncLaunchctlPlan {
    /// A disabled override makes `bootstrap` fail with "Bootstrap failed: 5:
    /// Input/output error". Enable the label before bootstrapping it.
    static func applyCommands(uid: uid_t, label: String, plistPath: String) -> [ScheduledSyncLaunchctlCommand] {
        let service = "gui/\(uid)/\(label)"
        let domain = "gui/\(uid)"
        return [
            ScheduledSyncLaunchctlCommand(arguments: ["enable", service], required: true),
            ScheduledSyncLaunchctlCommand(arguments: ["bootout", service], required: false),
            ScheduledSyncLaunchctlCommand(arguments: ["bootstrap", domain, plistPath], required: true),
            ScheduledSyncLaunchctlCommand(arguments: ["enable", service], required: true)
        ]
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
        var didWritePropertyList = false
        let commands = ScheduledSyncLaunchctlPlan.applyCommands(
            uid: getuid(),
            label: ScheduledSyncLaunchAgentDescriptor.label,
            plistPath: propertyListURL.path
        )
        for command in commands {
            if !didWritePropertyList, command.arguments.first == "bootstrap" {
                try data.write(to: propertyListURL, options: .atomic)
                didWritePropertyList = true
            }
            try runLaunchctl(command.arguments, allowsFailure: !command.required)
        }
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
