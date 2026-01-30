import Foundation
import CloudKit

actor AtomicClaim {
    private let database: CKDatabase

    init(database: CKDatabase) {
        self.database = database
    }

    /// Attempts to atomically claim a need on a room record.
    /// Returns true if this device won the claim, false if another device got it first.
    func claim(
        roomRecordID: CKRecord.ID,
        needID: String,
        deviceID: String
    ) async throws -> Bool {
        // Fetch the current record
        let record = try await database.record(for: roomRecordID)

        // Verify the need is still unclaimed
        guard let existingNeedID = record["needID"] as? String,
              existingNeedID == needID,
              record["needClaimedBy"] == nil else {
            return false // Need was already claimed or changed
        }

        // Set our claim
        record["needClaimedBy"] = deviceID as NSString
        record["needClaimedAt"] = Date() as NSDate

        // Save with ifServerRecordUnchanged policy - this is the atomic part
        let modifyOperation = CKModifyRecordsOperation(recordsToSave: [record])
        modifyOperation.savePolicy = .ifServerRecordUnchanged
        modifyOperation.qualityOfService = .userInitiated

        return try await withCheckedThrowingContinuation { continuation in
            modifyOperation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: true)
                case .failure(let error):
                    if let ckError = error as? CKError,
                       ckError.code == .serverRecordChanged {
                        // Another device claimed it first
                        continuation.resume(returning: false)
                    } else {
                        continuation.resume(throwing: error)
                    }
                }
            }

            self.database.add(modifyOperation)
        }
    }
}
