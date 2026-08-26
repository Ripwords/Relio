import Foundation
import SwiftData

public enum ChatRole: String, Codable, Hashable, Sendable, CaseIterable {
    case user, assistant
}

/// One turn of the assistant transcript. The model type ships in schema V1 so the
/// assistant plan does not need a migration; nothing in this plan writes to it.
@Model
public final class ChatMessage {

    public var id: UUID = UUID()
    public var roleRaw: String = ChatRole.user.rawValue
    public var text: String = ""
    public var createdAt: Date = Date.distantPast
    /// The Year of Assessment the turn was about, so history can be scoped per year.
    public var year: Int = 0

    public var updatedAt: Date = Date.distantPast
    public var deletedAt: Date?

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

extension ChatMessage {

    /// Spec §5: history is capped at the most recent 200 messages and prunable from
    /// Settings. Enforced by `TaxStore` when the assistant plan lands.
    public static let historyLimit = 200

    public var role: ChatRole {
        get { ChatRole(rawValue: roleRaw) ?? .user }
        set { roleRaw = newValue.rawValue }
    }

    public var isLive: Bool { deletedAt == nil }
}
