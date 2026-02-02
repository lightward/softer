import XCTest
import CloudKit
@testable import Softer

@MainActor
final class SofterStoreTests: XCTestCase {

    // MARK: - Initialization Tests

    func testInitialStateIsIdle() async {
        // Create store with nil dependencies to avoid actual CloudKit setup
        let store = SofterStore(
            apiClient: MockLightwardAPIClient(),
            dataStore: nil,
            container: nil,
            syncCoordinator: nil,
            zoneID: nil
        )

        // Without a container, sync status should not be synced
        XCTAssertEqual(store.syncStatus, SyncStatus.idle)
        XCTAssertFalse(store.initialLoadCompleted)
    }

    func testSyncStatusIsAvailableWithMockDependencies() async {
        // When container is provided (mocked), status should be synced
        let store = makeMockStore()
        XCTAssertEqual(store.syncStatus, .synced)
    }

    // MARK: - Room Operations

    func testDeleteRoomThrowsWhenNotConfigured() async {
        let store = SofterStore(
            apiClient: MockLightwardAPIClient(),
            dataStore: nil,
            container: nil,
            syncCoordinator: nil,
            zoneID: nil
        )

        do {
            try await store.deleteRoom(id: "test")
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is StoreError)
        }
    }

    func testSaveMessageThrowsWhenNotConfigured() async {
        let store = SofterStore(
            apiClient: MockLightwardAPIClient(),
            dataStore: nil,
            container: nil,
            syncCoordinator: nil,
            zoneID: nil
        )

        let message = Message(
            roomID: "test",
            authorID: "author",
            authorName: "Author",
            text: "Hello",
            isLightward: false
        )

        do {
            try await store.saveMessage(message)
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is StoreError)
        }
    }

    // MARK: - SyncStatus Tests

    func testSyncStatusEquality() {
        XCTAssertEqual(SyncStatus.idle, SyncStatus.idle)
        XCTAssertEqual(SyncStatus.syncing, SyncStatus.syncing)
        XCTAssertEqual(SyncStatus.synced, SyncStatus.synced)
        XCTAssertEqual(SyncStatus.offline, SyncStatus.offline)
        XCTAssertEqual(SyncStatus.error("test"), SyncStatus.error("test"))
        XCTAssertNotEqual(SyncStatus.error("a"), SyncStatus.error("b"))
    }

    func testSyncStatusIsAvailable() {
        XCTAssertFalse(SyncStatus.idle.isAvailable)
        XCTAssertTrue(SyncStatus.syncing.isAvailable)
        XCTAssertTrue(SyncStatus.synced.isAvailable)
        XCTAssertTrue(SyncStatus.offline.isAvailable)
        XCTAssertFalse(SyncStatus.error("test").isAvailable)
    }

    func testSyncStatusDisplayText() {
        XCTAssertEqual(SyncStatus.idle.displayText, "Connecting...")
        XCTAssertEqual(SyncStatus.syncing.displayText, "Syncing...")
        XCTAssertEqual(SyncStatus.synced.displayText, "Up to date")
        XCTAssertEqual(SyncStatus.offline.displayText, "Offline")
        XCTAssertEqual(SyncStatus.error("Custom error").displayText, "Custom error")
    }

    // MARK: - Helpers

    private func makeMockStore() -> SofterStore {
        // Note: This creates a store that appears configured but can't actually
        // perform CloudKit operations. For full integration tests, we'd need
        // mock SyncCoordinator implementations.
        SofterStore(
            apiClient: MockLightwardAPIClient(),
            dataStore: nil,
            container: CKContainer(identifier: Constants.containerIdentifier),
            syncCoordinator: nil,
            zoneID: CKRecordZone.default().zoneID
        )
    }
}
