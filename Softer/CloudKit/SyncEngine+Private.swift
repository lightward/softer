import Foundation
import CloudKit

final class PrivateSyncEngine: NSObject, @unchecked Sendable {
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private weak var manager: CloudKitManager?
    private var syncEngine: CKSyncEngine?

    init(database: CKDatabase, zoneID: CKRecordZone.ID, manager: CloudKitManager) {
        self.database = database
        self.zoneID = zoneID
        self.manager = manager
        super.init()

        setupSyncEngine()
    }

    private func setupSyncEngine() {
        let configuration = CKSyncEngine.Configuration(
            database: database,
            stateSerialization: loadState(),
            delegate: self
        )
        syncEngine = CKSyncEngine(configuration)
    }

    private func loadState() -> CKSyncEngine.State.Serialization? {
        guard let data = UserDefaults.standard.data(forKey: "privateSyncEngineState") else {
            return nil
        }
        return try? CKSyncEngine.State.Serialization(from: data)
    }

    private func saveState(_ state: CKSyncEngine.State.Serialization) {
        if let data = try? state.rawData() {
            UserDefaults.standard.set(data, forKey: "privateSyncEngineState")
        }
    }
}

extension PrivateSyncEngine: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        switch event {
        case .stateUpdate(let stateUpdate):
            saveState(stateUpdate.stateSerialization)

        case .accountChange(let accountChange):
            handleAccountChange(accountChange)

        case .fetchedDatabaseChanges(let fetchedChanges):
            handleFetchedDatabaseChanges(fetchedChanges)

        case .fetchedRecordZoneChanges(let fetchedChanges):
            handleFetchedRecordZoneChanges(fetchedChanges)

        case .sentRecordZoneChanges(let sentChanges):
            handleSentRecordZoneChanges(sentChanges)

        case .sentDatabaseChanges:
            break

        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .didFetchChanges, .willSendChanges, .didSendChanges:
            break

        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pendingChanges = syncEngine.state.pendingRecordZoneChanges
        guard !pendingChanges.isEmpty else { return nil }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pendingChanges) { recordID in
            return nil
        }
    }

    private func handleAccountChange(_ change: CKSyncEngine.Event.AccountChange) {
        switch change.changeType {
        case .signIn, .switchAccounts:
            // Re-fetch everything
            break
        case .signOut:
            break
        @unknown default:
            break
        }
    }

    private func handleFetchedDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) {
        for modification in changes.modifications {
            print("Zone modified: \(modification.zoneID)")
        }
    }

    private func handleFetchedRecordZoneChanges(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        for modification in changes.modifications {
            manager?.handleRecordChanged(modification.record)
        }
        for deletion in changes.deletions {
            manager?.handleRecordDeleted(
                recordID: deletion.recordID,
                recordType: deletion.recordType
            )
        }
    }

    private func handleSentRecordZoneChanges(_ changes: CKSyncEngine.Event.SentRecordZoneChanges) {
        for savedRecord in changes.savedRecords {
            manager?.handleRecordChanged(savedRecord)
        }
        for failedSave in changes.failedRecordSaves {
            print("Failed to save record: \(failedSave.record.recordID), error: \(failedSave.error)")
            if failedSave.error.code == .serverRecordChanged {
                // Conflict — the server version wins
                if let serverRecord = failedSave.error.serverRecord {
                    manager?.handleRecordChanged(serverRecord)
                }
            }
        }
    }
}

private extension CKSyncEngine.State.Serialization {
    init?(from data: Data) throws {
        // CKSyncEngine.State.Serialization init from archived data
        guard let unarchived = try NSKeyedUnarchiver.unarchivedObject(
            ofClass: NSData.self,
            from: data
        ) else { return nil }
        try self.init(from: unarchived as Data)
    }

    func rawData() throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: self, requiringSecureCoding: true)
    }
}
