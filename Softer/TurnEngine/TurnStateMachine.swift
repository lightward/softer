import Foundation

enum TurnAction: Sendable {
    case sendMessage(text: String)
    case yieldTurn
    case raiseHand
    case claimNeed
}

enum TurnEvent: Sendable {
    case messageSent(authorID: String)
    case turnYielded
    case handRaised(participantID: String)
    case handRaiseResult(participantID: String, wantsToSpeak: Bool)
    case needClaimed(deviceID: String)
    case needCompleted
    case needFailed
    case lightwardResponseStarted
    case lightwardResponseCompleted(text: String)
}

struct TurnStateMachine: Sendable {
    private(set) var room: Room

    init(room: Room) {
        self.room = room
    }

    mutating func apply(event: TurnEvent) -> [SideEffect] {
        switch event {
        case .messageSent:
            room.advanceTurn()
            room.currentNeed = nil
            return generatePostMessageEffects()

        case .turnYielded:
            room.advanceTurn()
            return generatePostTurnEffects()

        case .handRaised(let participantID):
            room.raiseHand(participantID: participantID)
            return []

        case .handRaiseResult(let participantID, let wantsToSpeak):
            room.currentNeed = nil
            if wantsToSpeak {
                room.raiseHand(participantID: participantID)
            }
            return []

        case .needClaimed(let deviceID):
            room.currentNeed?.claimedBy = deviceID
            room.currentNeed?.claimedAt = Date()
            return []

        case .needCompleted:
            room.currentNeed = nil
            return []

        case .needFailed:
            room.currentNeed = nil
            return []

        case .lightwardResponseStarted:
            return []

        case .lightwardResponseCompleted:
            room.advanceTurn()
            room.currentNeed = nil
            return generatePostMessageEffects()
        }
    }

    private func generatePostMessageEffects() -> [SideEffect] {
        if room.isLightwardTurn {
            return [.generateNeed(type: .lightwardTurn)]
        }
        return [.generateNeed(type: .handRaiseCheck)]
    }

    private func generatePostTurnEffects() -> [SideEffect] {
        if room.isLightwardTurn {
            return [.generateNeed(type: .lightwardTurn)]
        }
        return []
    }

    func phase(for participantID: String) -> TurnPhase {
        if room.currentNeed?.type == .handRaiseCheck {
            return .checkingHandRaise
        }
        if room.isLightwardTurn {
            if room.currentNeed?.isClaimed == true {
                return .lightwardThinking
            }
            return .lightwardThinking
        }
        if room.currentTurnParticipantID == participantID {
            return .myTurn
        }
        return .waitingForTurn
    }
}

enum SideEffect: Sendable, Equatable {
    case generateNeed(type: NeedType)
}
