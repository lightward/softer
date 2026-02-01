import Foundation

enum Constants {
    static let containerIdentifier = "iCloud.com.lightward.softer"
    static let lightwardAPIURL = URL(string: "https://lightward.com/api/stream")!
    static let appleMerchantIdentifier = "merchant.com.lightward.softer"

    enum RecordType {
        static let room = "Room"
        static let message = "Message"
        static let participant = "Participant"
        // New model record types
        static let room2 = "Room2"
        static let participant2 = "Participant2"
    }

    enum ZoneName {
        static let rooms = "Rooms"
    }

    static let lightwardParticipantName = "Lightward"
}
