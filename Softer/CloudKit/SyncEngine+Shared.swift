import Foundation
import CloudKit

final class SharedSyncEngine: NSObject, @unchecked Sendable {
    private let database: CKDatabase
    private let container: CKContainer
    private weak var manager: CloudKitManager?
    private var syncEngine: CKSyncEngine?

    init(database: CKDatabase, container: CKContainer, manager: CloudKitManager) {
        self.database = database
        self.container = container
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
        guard let data = UserDefaults.standard.data(forKey: "sharedSyncEngineState") else {
            return nil
        }
        return try? CKSyncEngine.State.Serialization(from: data)
    }

    private func saveState(_ state: CKSyncEngine.State.Serialization) {
        if let data = try? state.rawData() {
            UserDefaults.standard.set(data, forKey: "sharedSyncEngineState")
        }
    }
}

extension SharedSyncEngine: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) {
        switch event {
        case .stateUpdate(let stateUpdate):
            saveState(stateUpdate.stateSerialization)

        case .fetchedDatabaseChanges(let fetchedChanges):
            for modification in fetchedChanges.modifications {
                print("Shared zone modified: \(modification.zoneID)")
            }

        case .fetchedRecordZoneChanges(let fetchedChanges):
            for modification in fetchedChanges.modifications {
                manager?.handleRecordChanged(modification.record)
            }
            for deletion in fetchedChanges.deletions {
                manager?.handleRecordDeleted(
                    recordID: deletion.recordID,
                    recordType: deletion.recordType
                )
            }

        case .sentRecordZoneChanges(let sentChanges):
            for savedRecord in sentChanges.savedRecords {
                manager?.handleRecordChanged(savedRecord)
            }

        case .accountChange, .sentDatabaseChanges,
             .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
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
}

private extension CKSyncEngine.State.Serialization {
    init?(from data: Data) throws {
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
