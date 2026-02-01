import Foundation

/// How a participant is identified for CloudKit lookup.
enum ParticipantIdentifier: Sendable, Codable, Equatable {
    case email(String)
    case phone(String)
    case lightward  // Special case - not resolved via CloudKit

    var displayString: String {
        switch self {
        case .email(let email): return email
        case .phone(let phone): return phone
        case .lightward: return "Lightward AI"
        }
    }

    var isLightward: Bool {
        if case .lightward = self { return true }
        return false
    }
}

/// A participant as specified at room creation time.
/// The originator names everyone - it's their responsibility to name well.
struct ParticipantSpec: Sendable, Codable, Equatable, Identifiable {
    let id: String
    let identifier: ParticipantIdentifier
    let nickname: String

    init(
        id: String = UUID().uuidString,
        identifier: ParticipantIdentifier,
        nickname: String
    ) {
        self.id = id
        self.identifier = identifier
        self.nickname = nickname
    }

    var isLightward: Bool {
        identifier.isLightward
    }

    /// Creates a Lightward participant spec with the given nickname.
    static func lightward(nickname: String) -> ParticipantSpec {
        ParticipantSpec(identifier: .lightward, nickname: nickname)
    }
}
