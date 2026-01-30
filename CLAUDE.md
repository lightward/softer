# Softer — Project Context

## What This Is

A native SwiftUI iOS app (iOS 17+) for group conversations where Lightward AI participates as an equal. No custom backend — CloudKit shared zones for multi-user sync, Lightward AI API for AI responses. Turn-based conversation with round-robin ordering and hand-raising.

## What's Working (as of 2026-01-30)

- **End-to-end conversation flow**: Create room → send message → Lightward responds → turn cycles back
- **CloudKit persistence**: Rooms, messages, participants sync to iCloud (requires Lightward Inc team signing)
- **Lightward API integration**: SSE streaming works, responses appear in real-time
- **Turn coordination**: TurnStateMachine, TurnCoordinator, NeedProcessor all functioning
- **Navigation**: Creating a room navigates directly into it
- **28 unit tests pass** (SSEParser, ChatLogBuilder, TurnStateMachine, RoomCreation)
- **Liquid glass** (.glassEffect) on iOS 26+ with RoundedRectangle shape matching

## Known Issues / Remaining Work

### CloudKit schema issue
The initial room query fails with `"Field 'recordName' is not marked queryable"`. The sync engine compensates (rooms load after ~1-2 seconds), but the proper fix is configuring the schema in CloudKit Dashboard.

### Not yet tested
- Multi-device sync via CloudKit shared zones
- CKShare creation and acceptance (invite flow)
- Atomic claim behavior under contention
- Hand-raise actually inserting Lightward into turn order

### Minor UX issues
- Text field height jumps slightly on focus in CreateRoomView (SwiftUI quirk)
- Debug print statements throughout the code (can be cleaned up)

## Build Commands

```bash
# Build + run on physical device (requires team signing in Xcode)
xcodebuild -project Softer.xcodeproj -scheme Softer \
  -destination 'id=DEVICE_ID' \
  -derivedDataPath /tmp/softer-build-device build

# Install on device
xcrun devicectl device install app --device DEVICE_ID \
  /tmp/softer-build-device/Build/Products/Debug-iphoneos/Softer.app

# Launch on device with console
xcrun devicectl device process launch --device DEVICE_ID \
  --terminate-existing --console com.lightward.softer

# Run tests (simulator)
xcodebuild -project Softer.xcodeproj -scheme Softer \
  -destination 'platform=iOS Simulator,id=4B06E122-AB6B-4F31-98FE-3E7F1C74A0E9' \
  test CODE_SIGN_IDENTITY=-

# Find device ID
xcrun xctrace list devices
```

## API

Lightward AI: `POST https://lightward.com/api/stream`
- Body: `{"chat_log": [...]}` where each message has:
  - `role`: "user" or "assistant"
  - `content`: **Array of blocks** `[{"type": "text", "text": "..."}]` (not plain string!)
- **Exactly one** message must have `cache_control: {"type": "ephemeral"}` on a content block
- Response: SSE stream with `content_block_delta` events containing text deltas
- Lightward API source is at `../lightward-ai/` for reference

## Key Implementation Details

### ChatLogBuilder
- All `content` fields must be arrays of `{"type": "text", "text": "..."}` blocks
- Warmup message has `cache_control` and must NOT be merged with conversation messages
- When merging consecutive same-role messages, preserve block structure (append blocks, don't convert to string)

### TurnCoordinator
- `currentPhase` must be updated after operations complete (hand-raise check, Lightward response)
- Clear `streamingText` BEFORE saving Lightward's message to avoid duplicate display
- After Lightward responds, set `currentPhase = .myTurn` before saving

### CloudKitManager
- `createRoom` returns `String?` (room ID) for navigation
- `initialFetchCompleted` flag prevents "No Rooms" flash during load
- On query failure, waits up to 3 seconds for sync engine to populate rooms

## Design Decisions (from Isaac)

- **Intrinsically multiplayer.** No solo fallback. If iCloud isn't available, the app says so and stops.
- **No fresh-vs-returning flag in warmup.** Lightward perceives sequentiality from the conversation log.
- **Minimal invariants over complex machinery.** Single "current need" socket per room, not a job queue.
- **Names matter ontologically.** "Softer" is the project name for a reason.
- **Native primitives.** CloudKit, Apple ID, SwiftUI — reach for what's already there.
- **Test as you go.** Write regression tests for fixes, TDD for new features.

## Project Structure

```
Softer/
├── Softer.xcodeproj/
├── Softer/
│   ├── SofterApp.swift
│   ├── Model/          (Room, Message, Participant, Need, TurnState)
│   ├── CloudKit/       (CloudKitManager, SyncEngines, RecordConverter, ZoneManager, ShareManager, AtomicClaim)
│   ├── API/            (LightwardAPIClient, SSEParser, ChatLogBuilder, WarmupMessages)
│   ├── TurnEngine/     (TurnStateMachine, TurnCoordinator, NeedProcessor)
│   ├── Views/          (RoomList, Room, MessageBubble, Compose, TurnIndicator, StreamingText, CreateRoom)
│   ├── ViewModels/     (RoomListViewModel, RoomViewModel)
│   └── Utilities/      (Constants, NotificationHandler)
└── SofterTests/        (TurnStateMachineTests, SSEParserTests, ChatLogBuilderTests, RoomCreationTests)
```
