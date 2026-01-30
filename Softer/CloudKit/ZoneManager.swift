import Foundation
import CloudKit

actor ZoneManager {
    private let container: CKContainer
    private let privateDB: CKDatabase
    private let sharedDB: CKDatabase

    init(container: CKContainer) {
        self.container = container
        self.privateDB = container.privateCloudDatabase
        self.sharedDB = container.sharedCloudDatabase
    }

    func ensureZoneExists(named zoneName: String, in database: CKDatabase) async throws -> CKRecordZone.ID {
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        let zone = CKRecordZone(zoneID: zoneID)

        do {
            let savedZone = try await database.save(zone)
            return savedZone.zoneID
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Zone likely already exists
            return zoneID
        }
    }

    func deleteZone(named zoneName: String, in database: CKDatabase) async throws {
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        try await database.deleteRecordZone(withID: zoneID)
    }

    func fetchAllZones(in database: CKDatabase) async throws -> [CKRecordZone] {
        let zones = try await database.allRecordZones()
        return zones
    }
}
