import Foundation

public struct ScheduledSyncConfiguration: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var hour: Int
    public var minute: Int
    public var articleLimit: Int

    public init(isEnabled: Bool, hour: Int, minute: Int, articleLimit: Int) {
        self.isEnabled = isEnabled
        self.hour = hour
        self.minute = minute
        self.articleLimit = articleLimit
    }

    public var isValid: Bool {
        (0...23).contains(hour)
            && (0...59).contains(minute)
            && (1...100).contains(articleLimit)
    }
}

public enum ScheduledSyncLaunchAgentDescriptor {
    public static let label = "ai.defou.xarticlearchiver.scheduled-sync"
    public static let callbackURL = "xarticlearchiver://scheduled-sync"
    public static let appBundleIdentifier = "ai.defou.xarticlearchiver"

    public static func propertyListData(
        for configuration: ScheduledSyncConfiguration
    ) throws -> Data {
        guard configuration.isValid else {
            throw CocoaError(.propertyListWriteInvalid)
        }
        let propertyList: [String: Any] = [
            "Label": label,
            "ProgramArguments": [
                "/usr/bin/open",
                "-gj",
                "-b",
                appBundleIdentifier,
                callbackURL
            ],
            "StartCalendarInterval": [
                "Hour": configuration.hour,
                "Minute": configuration.minute
            ],
            "ProcessType": "Background",
            "RunAtLoad": false,
            "LowPriorityIO": true,
            "ThrottleInterval": 60
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
    }
}
