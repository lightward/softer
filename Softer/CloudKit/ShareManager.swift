import Foundation
import CloudKit

actor ShareManager {
    private let container: CKContainer
    private let privateDB: CKDatabase

    init(container: CKContainer) {
        self.container = container
        self.privateDB = container.privateCloudDatabase
    }

    func createShare(for roomRecord: CKRecord) async throws -> CKShare {
        let share = CKShare(rootRecord: roomRecord)
        share[CKShare.SystemFieldKey.title] = roomRecord["name"] as? String ?? "Softer Room"
        share.publicPermission = .none

        let modifyOperation = CKModifyRecordsOperation(
            recordsToSave: [roomRecord, share]
        )
        modifyOperation.savePolicy = .ifServerRecordUnchanged

        return try await withCheckedThrowingContinuation { continuation in
            modifyOperation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: share)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            self.privateDB.add(modifyOperation)
        }
    }

    func acceptShare(_ shareMetadata: CKShare.Metadata) async throws {
        let operation = CKAcceptSharesOperation(shareMetadatas: [shareMetadata])

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.acceptSharesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            self.container.add(operation)
        }
    }

    func fetchExistingShare(for recordID: CKRecord.ID) async throws -> CKShare? {
        do {
            let record = try await privateDB.record(for: recordID)
            guard let shareRef = record.share else { return nil }
            let shareRecord = try await privateDB.record(for: shareRef.recordID)
            return shareRecord as? CKShare
        } catch {
            return nil
        }
    }
}
