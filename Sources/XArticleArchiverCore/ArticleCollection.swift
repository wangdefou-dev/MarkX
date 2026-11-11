import Foundation

public struct ArticleCollection: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public var articleIDs: Set<UUID>
}

enum ArticleCollectionError: LocalizedError {
    case invalidName
    case duplicateName

    var errorDescription: String? {
        switch self {
        case .invalidName: "请输入有效的收藏夹名称。"
        case .duplicateName: "已存在同名收藏夹。"
        }
    }
}
