import Foundation
import CloudKit
import UIKit

@Observable
final class TurnCoordinator {
    private let cloudKitManager: CloudKitManager
    private let needProcessor: NeedProcessor
    private let deviceID: String

    var currentPhase: TurnPhase = .waitingForTurn
    var streamingText: String = ""
    var isProcessing: Bool = false

    init(cloudKitManager: CloudKitManager, needProcessor: NeedProcessor) {
        self.cloudKitManager = cloudKitManager
        self.needProcessor = needProcessor
        self.deviceID = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
    }

    func onRoomUpdated(room: Room, localParticipantID: String) {
        let machine = TurnStateMachine(room: room)
        currentPhase = machine.phase(for: localParticipantID)

        // If there's an unclaimed need, try to claim it
        if let need = room.currentNeed, !need.isClaimed {
            Task {
                await attemptClaim(room: room, need: need)
            }
        }
    }

    func sendMessage(room: Room, text: String, authorID: String, authorName: String) async {
        let message = Message(
            roomID: room.id,
            authorID: authorID,
            authorName: authorName,
            text: text
        )

        var machine = TurnStateMachine(room: room)
        let effects = machine.apply(event: .messageSent(authorID: authorID))

        await cloudKitManager.saveMessage(message)
        await cloudKitManager.updateRoom(machine.room)

        var latestRoom = machine.room
        for effect in effects {
            latestRoom = await handleEffect(effect, room: latestRoom)
        }

        // If a need was created, process it immediately
        if let need = latestRoom.currentNeed, !need.isClaimed {
            await attemptClaim(room: latestRoom, need: need)
        }
    }

    func yieldTurn(room: Room) async {
        var machine = TurnStateMachine(room: room)
        let effects = machine.apply(event: .turnYielded)

        await cloudKitManager.updateRoom(machine.room)

        for effect in effects {
            await handleEffect(effect, room: machine.room)
        }
    }

    private func attemptClaim(room: Room, need: Need) async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        do {
            let claimed = try await cloudKitManager.atomicClaimNeed(
                roomID: room.id,
                needID: need.id,
                deviceID: deviceID
            )

            guard claimed else { return }

            await processNeed(need: need, room: room)
        } catch {
            print("Claim failed: \(error)")
        }
    }

    private func processNeed(need: Need, room: Room) async {
        let messages = await cloudKitManager.messages(for: room.id)
        let participants = await cloudKitManager.participants(for: room.id)
        let participantNames = participants.map(\.name)

        switch need.type {
        case .handRaiseCheck:
            let wantsToSpeak = await needProcessor.checkHandRaise(
                messages: messages,
                roomName: room.name,
                participantNames: participantNames
            )
            var machine = TurnStateMachine(room: room)
            let _ = machine.apply(event: .handRaiseResult(
                participantID: Constants.lightwardParticipantName,
                wantsToSpeak: wantsToSpeak
            ))
            await cloudKitManager.updateRoom(machine.room)

            // Update phase after hand-raise check completes
            currentPhase = .myTurn

        case .lightwardTurn:
            streamingText = ""
            currentPhase = .lightwardStreaming

            let fullText = await needProcessor.executeLightwardTurn(
                messages: messages,
                roomName: room.name,
                participantNames: participantNames
            ) { [weak self] chunk in
                Task { @MainActor in
                    self?.streamingText += chunk
                }
            }

            // Clear streaming state BEFORE saving message to avoid duplication
            streamingText = ""
            currentPhase = .myTurn

            if let responseText = fullText {
                let message = Message(
                    roomID: room.id,
                    authorID: Constants.lightwardParticipantName,
                    authorName: Constants.lightwardParticipantName,
                    text: responseText
                )

                var machine = TurnStateMachine(room: room)
                let effects = machine.apply(event: .lightwardResponseCompleted(text: responseText))

                await cloudKitManager.saveMessage(message)
                await cloudKitManager.updateRoom(machine.room)

                for effect in effects {
                    await handleEffect(effect, room: machine.room)
                }
            } else {
                // Lightward chose to yield
                await yieldTurn(room: room)
            }
        }
    }

    @discardableResult
    private func handleEffect(_ effect: SideEffect, room: Room) async -> Room {
        switch effect {
        case .generateNeed(let type):
            let need = Need(type: type)
            var updatedRoom = room
            updatedRoom.currentNeed = need
            await cloudKitManager.updateRoom(updatedRoom)
            return updatedRoom
        }
    }
}
