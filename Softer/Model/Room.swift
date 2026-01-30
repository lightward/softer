import Foundation
import CloudKit

struct Room: Identifiable, Sendable {
    let id: String
    var name: String
    var turnOrder: [String] // participant IDs in round-robin order
    var currentTurnIndex: Int
    var raisedHands: Set<String> // participant IDs
    var currentNeed: Need?
    var createdAt: Date
    var modifiedAt: Date

    // CloudKit metadata
    var recordChangeTag: String?
    var shareReference: CKRecord.Reference?

    var currentTurnParticipantID: String? {
        guard !turnOrder.isEmpty else { return nil }
        let index = currentTurnIndex % turnOrder.count
        return turnOrder[index]
    }

    var isLightwardTurn: Bool {
        currentTurnParticipantID == Constants.lightwardParticipantName
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        turnOrder: [String] = [],
        currentTurnIndex: Int = 0,
        raisedHands: Set<String> = [],
        currentNeed: Need? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.turnOrder = turnOrder
        self.currentTurnIndex = currentTurnIndex
        self.raisedHands = raisedHands
        self.currentNeed = currentNeed
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    mutating func advanceTurn() {
        guard !turnOrder.isEmpty else { return }
        currentTurnIndex = (currentTurnIndex + 1) % turnOrder.count
        raisedHands.removeAll()
        modifiedAt = Date()
    }

    mutating func raiseHand(participantID: String) {
        raisedHands.insert(participantID)
        modifiedAt = Date()
    }
}
