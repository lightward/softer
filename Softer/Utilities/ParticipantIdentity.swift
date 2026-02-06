import Foundation

/// Pure functions for matching the local user to an embedded participant.
/// No View, Store, or CloudKit dependencies — testable in isolation.
enum ParticipantIdentity {

    /// Find the local user's participant ID from embedded participants.
    ///
    /// Matching layers:
    /// 1. `userRecordID == localUserRecordID` — strongest match
    /// 2. If `!isSharedWithMe`: `identifierType == "currentUser"` — owner fallback
    /// 3. nil — no match
    static func findLocalParticipant(
        in participants: [EmbeddedParticipant],
        localUserRecordID: String,
        isSharedWithMe: Bool
    ) -> String? {
        // Layer 1: exact userRecordID match
        if let match = participants.first(where: { $0.userRecordID == localUserRecordID }) {
            return match.id
        }

        // Layer 2: owner fallback (only on rooms we created)
        if !isSharedWithMe {
            if let match = participants.first(where: { $0.identifierType == "currentUser" }) {
                return match.id
            }
        }

        // Layer 3: no match
        return nil
    }

    /// Populate the local user's userRecordID in embedded participants.
    ///
    /// Called when a shared room is fetched — the CKShare tells us our recordID,
    /// and we need to stamp it onto the right embedded participant.
    ///
    /// Returns the updated array, or the original if no change was needed.
    static func populateUserRecordID(
        in participants: [EmbeddedParticipant],
        shareUserRecordID: String,
        localUserRecordID: String
    ) -> [EmbeddedParticipant] {
        // Already matched? No work needed.
        if participants.contains(where: { $0.userRecordID == localUserRecordID }) {
            return participants
        }

        var result = participants
        for (index, participant) in result.enumerated() {
            // Skip lightward and currentUser — they're not share recipients
            if participant.identifierType == "lightward" || participant.identifierType == "currentUser" {
                continue
            }
            // Match: nil userRecordID or matches the share's user record
            if participant.userRecordID == nil || participant.userRecordID == shareUserRecordID {
                result[index] = EmbeddedParticipant(
                    id: participant.id,
                    nickname: participant.nickname,
                    identifierType: participant.identifierType,
                    identifierValue: participant.identifierValue,
                    orderIndex: participant.orderIndex,
                    hasSignaledHere: participant.hasSignaledHere,
                    userRecordID: shareUserRecordID
                )
                break
            }
        }

        return result
    }
}
