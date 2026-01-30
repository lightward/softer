import Foundation

enum NeedType: String, Sendable, Codable {
    case handRaiseCheck   // Lightweight probe: should Lightward speak?
    case lightwardTurn    // Full response generation
}

struct Need: Sendable, Codable {
    let id: String
    let type: NeedType
    var claimedBy: String? // device identifier that claimed this
    var claimedAt: Date?
    let createdAt: Date

    var isClaimed: Bool { claimedBy != nil }

    init(
        id: String = UUID().uuidString,
        type: NeedType,
        claimedBy: String? = nil,
        claimedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.type = type
        self.claimedBy = claimedBy
        self.claimedAt = claimedAt
        self.createdAt = createdAt
    }
}
