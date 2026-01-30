import Foundation

@Observable
final class RoomViewModel {
    let roomID: String
    var composeText = ""

    private let cloudKitManager: CloudKitManager
    private let turnCoordinator: TurnCoordinator

    init(roomID: String, cloudKitManager: CloudKitManager) {
        self.roomID = roomID
        self.cloudKitManager = cloudKitManager
        let needProcessor = NeedProcessor()
        self.turnCoordinator = TurnCoordinator(
            cloudKitManager: cloudKitManager,
            needProcessor: needProcessor
        )
    }

    var room: Room? {
        cloudKitManager.rooms.first { $0.id == roomID }
    }

    var messages: [Message] {
        cloudKitManager.messages(for: roomID)
    }

    var participants: [Participant] {
        cloudKitManager.participants(for: roomID)
    }

    var currentPhase: TurnPhase {
        turnCoordinator.currentPhase
    }

    var streamingText: String {
        turnCoordinator.streamingText
    }

    var isMyTurn: Bool {
        currentPhase == .myTurn
    }

    var localParticipantID: String {
        // Find the participant that matches the local user
        let localUserRecordID = cloudKitManager.localUserRecordID
        let participant = participants.first { $0.userRecordID == localUserRecordID }
        return participant?.name ?? "Me"
    }

    func onAppear() {
        if let room = room {
            turnCoordinator.onRoomUpdated(room: room, localParticipantID: localParticipantID)
        }
    }

    func sendMessage() async {
        guard let room = room else { return }
        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        composeText = ""
        await turnCoordinator.sendMessage(
            room: room,
            text: text,
            authorID: localParticipantID,
            authorName: localParticipantID
        )
    }

    func yieldTurn() async {
        guard let room = room else { return }
        await turnCoordinator.yieldTurn(room: room)
    }
}
