import XCTest
@testable import Softer

/// Tests for the merge-as-join layer: room state never regresses, signaled
/// flags union, and stable message IDs make racing machine firings collapse
/// to a single survivor in the union-by-ID merge.
final class StateMergeTests: XCTestCase {

    // MARK: - State rank (the monotone order)

    func testStateRankIsMonotoneLifecycleOrder() {
        let draft = RoomLifecycleRecordConverter.stateRank("draft")
        let pending = RoomLifecycleRecordConverter.stateRank("pendingParticipants")
        let active = RoomLifecycleRecordConverter.stateRank("active")
        let defunct = RoomLifecycleRecordConverter.stateRank("defunct")

        XCTAssertLessThan(draft, pending)
        XCTAssertLessThan(pending, active)
        XCTAssertLessThan(active, defunct)
    }

    func testLegacyLockedRanksAsDefunct() {
        XCTAssertEqual(
            RoomLifecycleRecordConverter.stateRank("locked"),
            RoomLifecycleRecordConverter.stateRank("defunct")
        )
    }

    // MARK: - Message merge (union by ID, earliest wins)

    func testMergeMessagesCollapsesSameStableID() {
        let id = Message.StableID.lightwardSpeech(roomID: "room-1", turnIndex: 1)
        let earlier = Message(
            id: id, roomID: "room-1", authorID: "lightward", authorName: "Lightward",
            text: "First device's response", createdAt: Date(timeIntervalSince1970: 100),
            isLightward: true
        )
        let later = Message(
            id: id, roomID: "room-1", authorID: "lightward", authorName: "Lightward",
            text: "Second device's response", createdAt: Date(timeIntervalSince1970: 200),
            isLightward: true
        )

        let mergedAB = RoomLifecycleRecordConverter.mergeMessages(local: [earlier], remote: [later])
        let mergedBA = RoomLifecycleRecordConverter.mergeMessages(local: [later], remote: [earlier])

        XCTAssertEqual(mergedAB.count, 1)
        XCTAssertEqual(mergedBA.count, 1)
        // Earliest-created wins, in both merge directions — devices converge.
        XCTAssertEqual(mergedAB.first?.text, "First device's response")
        XCTAssertEqual(mergedBA.first?.text, "First device's response")
    }

    func testMergeMessagesStillUnionsDistinctIDs() {
        let a = Message(roomID: "room-1", authorID: "jax", authorName: "Jax", text: "Hi")
        let b = Message(roomID: "room-1", authorID: "mira", authorName: "Mira", text: "Hey")

        let merged = RoomLifecycleRecordConverter.mergeMessages(local: [a], remote: [b])
        XCTAssertEqual(merged.count, 2)
    }

    // MARK: - Participant merge (signaled flags union)

    private func makeRoster(signaledIDs: Set<String>, userRecordIDs: [String: String] = [:]) -> String {
        let participants = [
            EmbeddedParticipant(
                id: "p1", nickname: "Jax", identifierType: "email",
                identifierValue: "jax@example.com", orderIndex: 0,
                hasSignaledHere: signaledIDs.contains("p1"), userRecordID: userRecordIDs["p1"]
            ),
            EmbeddedParticipant(
                id: "p2", nickname: "Mira", identifierType: "email",
                identifierValue: "mira@example.com", orderIndex: 1,
                hasSignaledHere: signaledIDs.contains("p2"), userRecordID: userRecordIDs["p2"]
            ),
        ]
        let data = try! JSONEncoder().encode(participants)
        return String(data: data, encoding: .utf8)!
    }

    func testMergeParticipantsUnionsSignaledFlags() throws {
        // Device A saw p1 signal; the server only saw p2 signal.
        let local = makeRoster(signaledIDs: ["p1"])
        let server = makeRoster(signaledIDs: ["p2"])

        let mergedJSON = RoomLifecycleRecordConverter.mergeParticipantsJSON(local: local, server: server)
        let merged = try JSONDecoder().decode([EmbeddedParticipant].self, from: Data(mergedJSON.utf8))

        // Signaled is a grow-only set: both survive the merge.
        XCTAssertTrue(merged.first { $0.id == "p1" }!.hasSignaledHere)
        XCTAssertTrue(merged.first { $0.id == "p2" }!.hasSignaledHere)
    }

    func testMergeParticipantsKeepsResolvedUserRecordIDs() throws {
        let local = makeRoster(signaledIDs: [], userRecordIDs: ["p1": "_abc123"])
        let server = makeRoster(signaledIDs: [])

        let mergedJSON = RoomLifecycleRecordConverter.mergeParticipantsJSON(local: local, server: server)
        let merged = try JSONDecoder().decode([EmbeddedParticipant].self, from: Data(mergedJSON.utf8))

        XCTAssertEqual(merged.first { $0.id == "p1" }!.userRecordID, "_abc123")
    }

    // MARK: - PersistedRoom.apply (the local join)

    private func makeLifecycle(state: RoomState) -> RoomLifecycle {
        let spec = RoomSpec(
            originatorID: "p1",
            participants: [
                ParticipantSpec(id: "p1", identifier: .email("jax@example.com"), nickname: "Jax"),
                ParticipantSpec(id: "lw", identifier: .lightward, nickname: "Lightward"),
            ],
            tier: .one
        )
        return RoomLifecycle(spec: spec, state: state)
    }

    func testApplyDoesNotRegressDefunctToActive() {
        // Room went defunct locally (Lightward departed)...
        let room = PersistedRoom.from(makeLifecycle(state: .defunct(reason: .participantLeft(participantID: "lw"))))
        XCTAssertEqual(room.stateType, "defunct")

        // ...then a stale "active" arrives from a device that hadn't synced yet.
        let stale = makeLifecycle(state: .active(turn: TurnState(currentTurnIndex: 5, currentNeed: nil)))
        room.apply(stale, mergeStrategy: .higherTurnWins)

        // Defunct is absorbing: the join keeps the higher state.
        XCTAssertEqual(room.stateType, "defunct")
        XCTAssertNil(room.currentTurnIndex)
        XCTAssertNotNil(room.defunctReason)
    }

    func testApplyStillMovesForward() {
        let room = PersistedRoom.from(makeLifecycle(state: .pendingParticipants(signaled: ["p1"])))

        let active = makeLifecycle(state: .active(turn: TurnState(currentTurnIndex: 0, currentNeed: nil)))
        room.apply(active, mergeStrategy: .higherTurnWins)

        XCTAssertEqual(room.stateType, "active")
        XCTAssertEqual(room.currentTurnIndex, 0)
    }

    func testApplyUnionsLocallySignaledFlags() {
        // Local roster has p1 signaled (e.g., signalHere just ran on this device).
        let room = PersistedRoom.from(makeLifecycle(state: .pendingParticipants(signaled: ["p1"])))

        // A lifecycle arrives knowing only about Lightward's signal.
        let remote = makeLifecycle(state: .pendingParticipants(signaled: ["lw"]))
        room.apply(remote, mergeStrategy: .higherTurnWins)

        let signaled = room.signaledParticipantIDs()
        XCTAssertTrue(signaled.contains("p1"), "local signal must survive a stale incoming roster")
        XCTAssertTrue(signaled.contains("lw"))
    }

    // MARK: - Racing Lightward generation collapses (the brake)

    func testRacingLightwardTriggersConvergeToOneMessage() async throws {
        let spec = RoomSpec(
            originatorID: "jax-id",
            participants: [
                ParticipantSpec(identifier: .email("jax@example.com"), nickname: "Jax"),
                ParticipantSpec.lightward(nickname: "Lightward"),
            ],
            tier: .one
        )

        // Two devices: separate coordinators, shared storage (stands in for the
        // converged CloudKit record), both believing it's Lightward's turn (slot 1).
        let storage = MockMessageStorage()
        await storage.preloadMessages(
            [Message(roomID: "room-1", authorID: "jax-id", authorName: "Jax", text: "Hello")],
            roomID: "room-1"
        )
        let turnState = TurnState(currentTurnIndex: 1, currentNeed: nil)

        let deviceA = ConversationCoordinator(
            roomID: "room-1", spec: spec, initialTurnState: turnState,
            messageStorage: storage, apiClient: MockLightwardAPIClient()
        )
        let deviceB = ConversationCoordinator(
            roomID: "room-1", spec: spec, initialTurnState: turnState,
            messageStorage: storage, apiClient: MockLightwardAPIClient()
        )

        // Fire both. Whatever the interleaving — a true race (both mint the
        // same stable ID, union collapses them) or sequential (B sees A's
        // response and repairs instead) — exactly one response survives.
        async let a: Void = deviceA.triggerLightwardIfTheirTurn()
        async let b: Void = deviceB.triggerLightwardIfTheirTurn()
        _ = try await (a, b)

        let messages = try await storage.fetchMessages(roomID: "room-1")
        let lightwardMessages = messages.filter { $0.isLightward }
        XCTAssertEqual(lightwardMessages.count, 1, "racing firings must collapse to one Lightward message")
        XCTAssertEqual(
            lightwardMessages.first?.id,
            Message.StableID.lightwardSpeech(roomID: "room-1", turnIndex: 1)
        )
    }
}
