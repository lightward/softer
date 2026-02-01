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
            container: nil,
            storage: nil,
            messageStorage: nil,
            zoneID: nil
        )

        // Without a container, sync status should not be synced
        XCTAssertEqual(store.syncStatus, .idle)
        XCTAssertTrue(store.rooms.isEmpty)
        XCTAssertFalse(store.initialLoadCompleted)
    }

    func testSyncStatusIsAvailableWithMockDependencies() async {
        // When container is provided (mocked), status should be synced
        let store = makeMockStore()
        XCTAssertEqual(store.syncStatus, .synced)
    }

    // MARK: - Room Operations

    func testRoomsInitiallyEmpty() async {
        let store = makeMockStore()
        XCTAssertTrue(store.rooms.isEmpty)
    }

    func testDeleteRoomThrowsWhenNotConfigured() async {
        let store = SofterStore(
            apiClient: MockLightwardAPIClient(),
            container: nil,
            storage: nil,
            messageStorage: nil,
            zoneID: nil
        )

        do {
            try await store.deleteRoom(id: "test")
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is StoreError)
        }
    }

    func testFetchMessagesThrowsWhenNotConfigured() async {
        let store = SofterStore(
            apiClient: MockLightwardAPIClient(),
            container: nil,
            storage: nil,
            messageStorage: nil,
            zoneID: nil
        )

        do {
            _ = try await store.fetchMessages(roomID: "test")
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
        // mock storage implementations.
        SofterStore(
            apiClient: MockLightwardAPIClient(),
            container: CKContainer(identifier: Constants.containerIdentifier),
            storage: nil,
            messageStorage: nil,
            zoneID: CKRecordZone.default().zoneID
        )
    }
}
