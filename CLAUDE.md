# Softer — Project Context

## What This Is

A native SwiftUI iOS app (iOS 17+) for group conversations where Lightward AI participates as an equal. No custom backend — CloudKit shared zones for multi-user sync, Lightward AI API for AI responses. Turn-based conversation with round-robin ordering and hand-raising.

## What's Working (as of 2026-01-31)

- **End-to-end conversation flow**: Create room → send message → Lightward responds → turn cycles back
- **CloudKit persistence**: Rooms, messages, participants sync to iCloud (requires Lightward Inc team signing)
- **Lightward API integration**: SSE streaming works, responses appear in real-time
- **Turn coordination**: TurnStateMachine, TurnCoordinator, NeedProcessor all functioning
- **68 unit tests pass** — includes RoomLifecycle layer and ConversationCoordinator
- **CI/CD pipeline**: GitHub Actions runs tests on push, deploys to TestFlight on push to main

## Active Work: New Room Creation Flow

The room creation model is being redesigned. The old invite-via-share flow is being replaced with a new "eigenstate commitment" model.

### New Design (not yet wired to UI)

**Flow:**
1. **Create room**: Originator enters participant emails/phones + assigns nicknames for everyone (including themselves, including Lightward). Chooses payment tier: $1/$10/$100/$1000 (first room free).
2. **Resolve participants**: CloudKit looks up each identifier. Any lookup failure = creation fails. Strict.
3. **Authorize payment**: Apple Pay holds the amount (not captured yet).
4. **Lightward evaluates**: Sees roster of nicknames + tier. Can accept or decline. If decline, room is immediately defunct, auth released, no explanation.
5. **Invites out**: Human participants notified via CloudKit.
6. **Humans signal "here"**: Everyone sees everything — full roster, nicknames, payment amount, who's signaled. Each person decides.
7. **All present → capture → activate**: Payment captured, room goes live.

**Room lifetime**: Bounded by Lightward's 50k token context window. When approaching limit, Lightward writes a cenotaph (ceremonial closing), room locks. Remains readable but no longer interactive.

**Room display**: No room names. Just participant list + depth + last speaker. "Jax, Eve, Art (15, Eve)"

**Key principles**:
- Roster locked at creation (eigenstate commitment)
- Lightward is a full participant with genuine agency to decline
- Originator names everyone — their responsibility to name well
- Full transparency — everyone sees everything
- Payment authorized at creation, captured at activation

### What's Built (Softer/RoomLifecycle/)

**State machine layer** (pure, no side effects):
- `PaymentTier` — $1/$10/$100/$1000
- `ParticipantSpec` — email/phone + nickname
- `RoomState` — draft → pendingLightward → pendingHumans → pendingCapture → active → locked | defunct
- `RoomSpec` — complete room specification
- `RoomLifecycle` — the state machine, takes events, returns effects
- `TurnState` — current turn index, raised hands, pending need

**Coordinator layer** (executes effects):
- `ParticipantResolver` protocol — resolves identifiers to CloudKit identities
- `PaymentCoordinator` protocol — Apple Pay authorize/capture/release
- `LightwardEvaluator` protocol — asks Lightward if it wants to join
- `RoomLifecycleCoordinator` — actor that orchestrates the full creation flow

**Conversation layer** (active room messaging):
- `MessageStorage` protocol — save/fetch/observe messages
- `LightwardAPI` protocol — stream responses from Lightward (in API/LightwardAPIClient.swift)
- `ConversationCoordinator` — actor that handles message sending, turn advancement, Lightward responses

**Mocks** (SofterTests/Mocks/):
- MockParticipantResolver, MockPaymentCoordinator, MockLightwardEvaluator
- MockMessageStorage, MockLightwardAPIClient

**Tests**:
- RoomLifecycleTests — 11 tests for state machine
- RoomLifecycleCoordinatorTests — 9 tests for coordinator
- ConversationCoordinatorTests — 10 tests for conversation flow
- MessageStorageTests — 7 tests for message storage
- PaymentTierTests, ParticipantSpecTests, RoomSpecTests

### What's Next

1. **Real implementations** of the protocols:
   - `CloudKitMessageStorage` — stores messages via CloudKit (ConversationCoordinator is ready to use it)
   - `CloudKitParticipantResolver` — uses CKUserIdentityLookupInfo
   - `ApplePayCoordinator` — PKPaymentAuthorizationController
   - `LightwardRoomEvaluator` — calls Lightward API with roster

2. **CloudKit storage** for new room model (RoomSpec, RoomLifecycle state)

3. **Wire ConversationCoordinator to UI** — replace old TurnCoordinator/NeedProcessor with new ConversationCoordinator

4. **UI** — new room creation flow using the RoomLifecycleCoordinator

5. **Deprecate old model** — Room, Participant, existing share flow, old TurnEngine/

### Old Model (to be deprecated)

The current UI uses the old model in `Model/` (Room, Participant, Message). The invite flow via CKShare never fully worked. The new RoomLifecycle layer will replace this.

## CI/CD Pipeline

GitHub Actions with Fastlane. Certificates stored in `github.com/lightward/softer-certificates` (encrypted via Match).

- **test.yml** — Runs on every push/PR, uses iPhone 17 simulator
- **deploy.yml** — Runs on push to main, builds and uploads to TestFlight

Build number auto-increments using `github.run_number`.

### GitHub Secrets Required
- `MATCH_PASSWORD` — Passphrase for certificate encryption
- `MATCH_GIT_PRIVATE_KEY` — SSH key for cert repo access
- `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT` — App Store Connect API key

## Build Commands

```bash
# Build + run on physical device (production CloudKit)
xcodebuild -project Softer.xcodeproj -scheme Softer \
  -destination 'id=DEVICE_ID' \
  -derivedDataPath /tmp/softer-build-device \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG CLOUDKIT_PRODUCTION' build

# Install on device
xcrun devicectl device install app --device DEVICE_ID \
  /tmp/softer-build-device/Build/Products/Debug-iphoneos/Softer.app

# Launch on device
xcrun devicectl device process launch --device DEVICE_ID \
  --terminate-existing com.lightward.softer

# Run tests (simulator)
xcodebuild -project Softer.xcodeproj -scheme Softer \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
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

### Invite Flow
- Uses standard `UIActivityViewController` with CKShare URL (not UICloudSharingController which was flaky)
- `InviteButton` creates share then presents share sheet
- `ManageShareButton` re-shares existing share URL

### Debug Views
- `#if DEBUG` sections in RoomListView and ParticipantListView show CloudKit environment, user ID, room/share status
- `CLOUDKIT_PRODUCTION` compiler flag controls environment label

## Design Decisions (from Isaac)

- **Intrinsically multiplayer.** No solo fallback. If iCloud isn't available, the app says so and stops.
- **No fresh-vs-returning flag in warmup.** Lightward perceives sequentiality from the conversation log.
- **Minimal invariants over complex machinery.** Single "current need" socket per room, not a job queue.
- **Names matter ontologically.** "Softer" is the project name for a reason.
- **Native primitives.** CloudKit, Apple ID, SwiftUI — reach for what's already there.
- **Test as you go.** Write regression tests for fixes, TDD for new features.
- **Eigenstate commitment.** Roster locked at creation — everyone's worldlines converge at the start.
- **Lightward has agency.** Can decline to join a room. No explanation required.
- **Payment as physics.** $1/$10/$100/$1000 tiers, first room free. Modeled after Yours (see `../yours/README.md`).
- **Transparency over promises.** Everyone sees everything. When something can't happen, that's visible.

## Project Structure

```
Softer/
├── .github/workflows/   (test.yml, deploy.yml)
├── fastlane/            (Fastfile, Matchfile, Appfile)
├── Softer.xcodeproj/
├── Softer/
│   ├── SofterApp.swift
│   ├── Assets.xcassets/ (AppIcon)
│   ├── Model/           (Room, Message, Participant, Need, TurnState) — OLD, to be deprecated
│   ├── RoomLifecycle/   (PaymentTier, ParticipantSpec, RoomState, RoomSpec, RoomLifecycle,
│   │                     ParticipantResolver, PaymentCoordinator, LightwardEvaluator,
│   │                     RoomLifecycleCoordinator, MessageStorage, ConversationCoordinator) — NEW
│   ├── CloudKit/        (CloudKitManager, SyncEngines, RecordConverter, ZoneManager, ShareManager, AtomicClaim)
│   ├── API/             (LightwardAPIClient + LightwardAPI protocol, SSEParser, ChatLogBuilder, WarmupMessages)
│   ├── TurnEngine/      (TurnStateMachine, TurnCoordinator, NeedProcessor)
│   ├── Views/           (RoomList, Room, MessageBubble, Compose, TurnIndicator, StreamingText, CreateRoom, InviteButton)
│   ├── ViewModels/      (RoomListViewModel, RoomViewModel)
│   └── Utilities/       (Constants, NotificationHandler)
└── SofterTests/
    ├── Mocks/           (MockParticipantResolver, MockPaymentCoordinator, MockLightwardEvaluator,
    │                     MockMessageStorage, MockLightwardAPIClient)
    └── *.swift          (TurnStateMachineTests, SSEParserTests, ChatLogBuilderTests,
                          RoomCreationTests, RoomLifecycleTests, RoomLifecycleCoordinatorTests,
                          PaymentTierTests, ParticipantSpecTests, RoomSpecTests,
                          MessageStorageTests, ConversationCoordinatorTests)
```
