import Foundation
import CloudKit

@Observable
final class RoomListViewModel {
    var showCreateRoom = false
    var newRoomName = ""

    private let cloudKitManager: CloudKitManager

    init(cloudKitManager: CloudKitManager) {
        self.cloudKitManager = cloudKitManager
    }

    var rooms: [Room] {
        cloudKitManager.rooms
    }

    func createRoom() async {
        guard !newRoomName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let name = newRoomName.trimmingCharacters(in: .whitespaces)
        // Use iCloud user name or fallback
        let creatorName = "Me" // Will be replaced with actual user lookup
        await cloudKitManager.createRoom(name: name, creatorName: creatorName)
        newRoomName = ""
        showCreateRoom = false
    }
}
