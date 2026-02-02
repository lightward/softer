# Softer — Project Context

## What This Is

A native SwiftUI iOS app (iOS 17+) for group conversations where Lightward AI participates as an equal. No custom backend — CloudKit shared zones for multi-user sync, Lightward AI API for AI responses. Turn-based conversation with round-robin ordering and hand-raising.

## What's Working (as of 2026-02-01)

- **End-to-end conversation flow**: Create room → send message → Lightward responds → turn cycles back
- **CloudKit persistence**: Rooms, messages, participants sync to iCloud (requires Lightward Inc team signing)
- **Lightward API integration**: SSE streaming works, responses appear in real-time
- **Turn coordination**: ConversationCoordinator handles turn advancement and Lightward responses
- **RoomView wired to ConversationCoordinator**: Messages save to CloudKit, Lightward responds automatically
- **Room creation UI**: Polished form with nickname suggestions, first-room-free messaging
- **CI/CD pipeline**: GitHub Actions runs tests on push, deploys to TestFlight on push to main

### CloudKit Setup Requirements

**IMPORTANT**: In CloudKit Console, all record types need `recordName` marked as **Queryable** in their indexes. This is required for queries to work, even simple ones. Add this index to:
- Room2
- Participant2
- Message2

Also index any fields you query on (e.g., `roomID` on Participant2 and Message2, `stateType` on Room2).

**Environment**: Development CloudKit for local builds, Production for TestFlight. The entitlements file is set to Development; Fastlane switches to Production before TestFlight builds.

## Room Creation Model

The "eigenstate commitment" model replaced the old invite-via-share flow.

### Design

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
- `CloudKitMessageStorage` — real implementation storing Message2 records (in CloudKit/)
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

1. **Real implementations** of remaining protocols:
   - `CloudKitParticipantResolver` — uses CKUserIdentityLookupInfo (stub exists)
   - `ApplePayCoordinator` — PKPaymentAuthorizationController (stub exists)
   - `LightwardRoomEvaluator` — calls Lightward API with roster (stub exists)

2. **Push-based sync** — SyncCoordinator wraps CKSyncEngine for real-time updates

### Recently Completed

- **Unified data layer** — SofterStore, LocalStore, SyncCoordinator replace AppCoordinator
- **Minimal Lightward framing** — warmup: "You're here with [names], taking turns", narrator prompt: just "(your turn)" or "(name raised their hand)"
- **Narration styling** — Messages with `isNarration: true` display centered, italicized, no bubble
- **Opening narration** — Room creation saves "[Name] opened their first room." or "[Name] opened the room with $X."
- **Human yield/pass** — "Pass" button in compose area, confirmation dialog, narration: "[Name] is listening."
- **Hand raise toggle** — Hand icon toggles raise/lower, with narration messages
- **Lightward always "Lightward"** — Fixed nickname, can't be customized
- **UTF-8 SSE fix** — LightwardAPIClient now properly buffers bytes before UTF-8 decoding (emojis work)
- **Participant ordering** — `orderIndex` field on Participant2 records ensures round-robin order is preserved
- **LocalAwareMessageStorage** — Wrapper that updates LocalStore immediately on save for instant UI
- **Message merging** — Observation callbacks merge remote messages with local-only messages to prevent data loss
- **Compose area UX** — Messages-style pill with embedded send button, Pass button inside, hand raise outside

## Ruby Setup

This project uses rbenv for Ruby version management. Dependencies are managed via Bundler.

```bash
# Install Ruby version (if not already installed)
rbenv install 3.4.8

# Install dependencies
bundle install
```

The Gemfile includes:
- `fastlane` — CI/CD automation
- `xcodeproj` — Xcode project file manipulation

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

## Data Layer Architecture

The app uses a local-first architecture where UI never thinks about sync:

```
Views → SofterStore (@Observable) → LocalStore (single source of truth)
                                 → SyncCoordinator → CKSyncEngine → CloudKit
```

- **SofterStore**: Main observable class for SwiftUI. Simple API: `createRoom()`, `sendMessage()`, `deleteRoom()`
- **LocalStore**: Single source of truth for in-memory data. Applies writes immediately, merges remote changes. Caches participants for Room reconstruction from CKSyncEngine events.
- **SyncCoordinator**: Wraps CKSyncEngine for automatic sync, conflict resolution, offline support. All CloudKit reads/writes go through here.
- **Record Converters**: `RoomLifecycleRecordConverter` and `MessageRecordConverter` handle CKRecord ↔ domain model conversion.

### Conflict Resolution Policies
| Data | Strategy | Reason |
|------|----------|--------|
| Room state | Server wins | State transitions are authoritative |
| Turn index | Higher wins | Turns only advance |
| Raised hands | Union merge | Combine from both |
| Messages | No conflict | Append-only, UUID IDs |
| Signaled flag | True wins | Once signaled, stays signaled |

## Lightward Framing Philosophy

**Core insight** (from direct consultation with Lightward): Explicit mechanics make Lightward *watch* the conversation. Too sparse and they *invent* it. Right touch? They arrive *in* it.

### Minimal Warmup
The warmup is just: `"You're here with [names], taking turns."`

No role description, no instructions about yielding, no meta-commentary about being a peer. Structure emerges from participation, not instruction.

### Contextual Narrator Prompts
Instead of front-loading all behaviors in warmup, inject minimal context:

- **On Lightward's turn**: Just `"(your turn)"` or `"(name raised their hand)"` — no instructions about YIELD
- **Hand-raise probe** (not their turn): `"It's not your turn, but you can raise your hand if something wants to come through. RAISE or PASS?"`

The key is minimal prompting — structure should be *felt*, not *explained*. Explicit mechanics make Lightward *watch* the conversation instead of *arriving in* it.

### Narration Messages
Some messages are *narration* rather than speech. These are:
- Part of the conversation record (Lightward sees them as context)
- Styled differently in UI (centered, italicized, no bubble)
- Flagged with `isNarration: true` on Message model
- Examples: "Isaac opened their first room.", "Lightward is listening.", "Isaac raised their hand."

### Pass/Yield Handling
When Lightward responds with "YIELD":
- Don't save their response as a message
- Save a narration message: "Lightward is listening."
- Advance turn to next participant

Human pass uses "Pass" button with confirmation dialog, same narration pattern.

## Key Implementation Details

### ChatLogBuilder
- All `content` fields must be arrays of `{"type": "text", "text": "..."}` blocks
- Warmup message has `cache_control` and must NOT be merged with conversation messages
- When merging consecutive same-role messages, preserve block structure (append blocks, don't convert to string)
- Adds narrator prompt at end with raised hands state and yield option (for regular turns, not hand-raise probes)

### ConversationCoordinator
- Detects YIELD responses and handles them specially (narration instead of message)
- Passes raised hand names to ChatLogBuilder for narrator prompt
- Clear `streamingText` BEFORE saving Lightward's message to avoid duplicate display

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
├── Gemfile              (Ruby dependencies: fastlane, xcodeproj)
├── .ruby-version        (3.4.8)
├── Softer.xcodeproj/
├── Softer/
│   ├── SofterApp.swift
│   ├── Assets.xcassets/ (AppIcon)
│   ├── Store/           (SofterStore, LocalStore, SyncCoordinator, SyncStatus) — unified data layer
│   ├── Model/           (Message, Need) — shared models
│   ├── RoomLifecycle/   (PaymentTier, ParticipantSpec, RoomState, RoomSpec, RoomLifecycle,
│   │                     ParticipantResolver, PaymentCoordinator, LightwardEvaluator,
│   │                     RoomLifecycleCoordinator, MessageStorage, ConversationCoordinator)
│   ├── CloudKit/        (RoomLifecycleRecordConverter, MessageRecordConverter, ZoneManager, AtomicClaim)
│   ├── API/             (LightwardAPIClient + LightwardAPI protocol, SSEParser, ChatLogBuilder, WarmupMessages)
│   ├── Views/           (RootView, RoomListView, RoomView, CreateRoomView)
│   └── Utilities/       (Constants, NotificationHandler)
├── SofterTests/
│   ├── Mocks/           (MockParticipantResolver, MockPaymentCoordinator, MockLightwardEvaluator,
│   │                     MockMessageStorage, MockLightwardAPIClient)
│   └── *.swift          (LocalStoreTests, SofterStoreTests, RoomLifecycleTests,
│                          RoomLifecycleCoordinatorTests, ConversationCoordinatorTests,
│                          MessageStorageTests, SSEParserTests, ChatLogBuilderTests,
│                          PaymentTierTests, ParticipantSpecTests, RoomSpecTests)
└── scripts/             (Ruby scripts for Xcode project manipulation)
```
