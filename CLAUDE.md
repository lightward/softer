# Softer — Project Context

## What This Is

A native SwiftUI iOS app (iOS 18+) for group conversations where Lightward AI participates as an equal. No custom backend — CloudKit shared zones for multi-user sync, Lightward AI API for AI responses. Turn-based conversation with round-robin ordering and hand-raising.

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
- Room3

Also index any fields you query on (e.g., `stateType` on Room3).

**Note**: Room3 embeds both participants and messages as JSON (`participantsJSON` and `messagesJSON` fields) — single record type for the entire room. This eliminates sync ordering issues and simplifies conflict resolution.

**Environment**: Development CloudKit for all builds (local and TestFlight). This allows testers to see the same data as local development. When ready for real users, uncomment the Production switch in `fastlane/Fastfile`.

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
- `MessageStorage` protocol — save/fetch/observe messages (used for testing abstraction)
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

1. **Share acceptance flow** — Handle `ckshare://` URLs so participants can accept room invitations
2. **Signal "here" UI** — When a participant opens a pending room, show UI to signal presence
3. **Pending state in RoomView** — Show "waiting for participants" inside the room, not just in list
4. **CreateRoomView UX** — Contact picker, nickname prefill, visual confirmation of participant validity

### Recently Completed

- **Multi-user room sharing (CKShare)** — Rooms with multiple humans now create a CKShare. Uses `CKFetchShareParticipantsOperation` for participant validation (not `CKDiscoverUserIdentitiesOperation` which requires opt-in discoverability). SyncCoordinator has dual engines for private + shared databases. Share is created after room save, participants added by email/phone lookup.
- **Participant resolution via share lookup** — `CloudKitParticipantResolver` now validates participants can receive shares. This is the right validation for eigenstate commitment — verifying existence, not discoverability.
- **Only originator auto-signals** — Other humans signal after accepting the share. Room stays in `pendingHumans` until all signal.
- **Development CloudKit for all builds** — TestFlight now uses Development environment (same as local builds) so testers see the same data. Fastlane production switch is commented out.
- **Single-record-type app** — Room3 now embeds both participants (`participantsJSON`) and messages (`messagesJSON`) as JSON. No separate Message2 records. Single CloudKit record type = simpler sync, fewer edge cases, data shape matches value shape. 50k token room limit ≈ 350-400KB total, well under CloudKit's 1MB limit.
- **SwiftData @Query refactor** — Views observe SwiftData directly via `@Query`, no manual `dataVersion` counter. RoomView observes room's embedded messages.
- **SwiftData local persistence** — PersistenceStore with `cloudKitDatabase: .none` as single source of truth.
- **Turn index grows without wrapping** — `advanceTurn` increments instead of using modulo, so `higherTurnWins` merge works correctly
- **ScrollView room list** — Replaced List to avoid SwiftUI diffing crashes during room creation/deletion
- **CKSyncEngine with custom zone** — SyncCoordinator uses "SofterZone" (custom zones required for CKSyncEngine change tracking; default zone doesn't work)
- **Unified data layer** — SofterStore, PersistenceStore, SyncCoordinator
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

# Launch with console output (streams stdout/stderr - essential for debugging)
xcrun devicectl device process launch --device DEVICE_ID \
  --terminate-existing --console com.lightward.softer

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

The app uses a local-first architecture where UI observes SwiftData directly:

```
Views (@Query) → PersistenceStore (SwiftData, local-only)
SofterStore (actions) → SyncCoordinator → CKSyncEngine → CloudKit
```

- **Views with @Query**: `RoomListView`, `CreateRoomView`, and `RoomView` use SwiftUI's `@Query` to observe SwiftData directly. No manual reactivity needed.
- **SofterStore**: Action layer for SwiftUI. Simple API: `createRoom()`, `sendMessage()`, `deleteRoom()`. Exposes `modelContainer` for the `.modelContainer()` modifier.
- **PersistenceStore**: SwiftData wrapper with `cloudKitDatabase: .none` (we handle CloudKit sync ourselves). Single model: `PersistedRoom` with embedded participants and messages as JSON. Provides synchronous local updates before async CloudKit sync.
- **SyncCoordinator**: Wraps CKSyncEngine for automatic sync, conflict resolution, offline support. Uses custom zone "SofterZone" (required — CKSyncEngine doesn't track changes in the default zone).
- **Record Converter**: `RoomLifecycleRecordConverter` handles CKRecord ↔ domain model conversion, including message encoding/decoding.

### Conflict Resolution Policies
| Data | Strategy | Reason |
|------|----------|--------|
| Room state | Server wins | State transitions are authoritative |
| Turn index | Higher wins | Turns only advance (index grows, never wraps) |
| Raised hands | Union merge | Combine from both |
| Messages | Union by ID | Merge local + remote, sort by createdAt |
| Signaled flag | True wins | Once signaled, stays signaled |

### Known Technical Debt

- **ScrollView replaces List**: RoomListView uses ScrollView+LazyVStack instead of List to avoid diffing crashes. Lost swipe-to-delete (using context menu instead).
- **Debug logging**: PersistenceStore has print statements for turn state debugging.

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

- **A codeplace you want to return to.** Health from the inside out. Obvious patterns, no clever tricks. When you open a file, you should see the shape immediately — not archaeology through manual wiring. Code that makes you go "oh right, yes" rather than "wait, why...?"
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
│   ├── Store/           (SofterStore, PersistenceStore, SyncCoordinator, SyncStatus) — unified data layer
│   ├── Model/           (Message, Need, PersistentModels) — shared models + SwiftData entities
│   ├── RoomLifecycle/   (PaymentTier, ParticipantSpec, RoomState, RoomSpec, RoomLifecycle,
│   │                     ParticipantResolver, PaymentCoordinator, LightwardEvaluator,
│   │                     RoomLifecycleCoordinator, MessageStorage, ConversationCoordinator)
│   ├── CloudKit/        (RoomLifecycleRecordConverter, ZoneManager, AtomicClaim, CloudKitMessageStorage)
│   ├── API/             (LightwardAPIClient + LightwardAPI protocol, SSEParser, ChatLogBuilder, WarmupMessages)
│   ├── Views/           (RootView, RoomListView, RoomView, CreateRoomView)
│   └── Utilities/       (Constants, NotificationHandler)
└── SofterTests/
    ├── Mocks/           (MockParticipantResolver, MockPaymentCoordinator, MockLightwardEvaluator,
    │                     MockMessageStorage, MockLightwardAPIClient)
    └── *.swift          (SofterStoreTests, RoomLifecycleTests,
                          RoomLifecycleCoordinatorTests, ConversationCoordinatorTests,
                          MessageStorageTests, SSEParserTests, ChatLogBuilderTests,
                          PaymentTierTests, ParticipantSpecTests, RoomSpecTests)
```

## Collaborators

### Isaac

**Working style**: Checks in on the relational space before diving into work. Will front-load meta-context at session start — this is calibration, not noise. Intervenes when something needs attention; silence means things are tracking.

**Values in code**: Inside-out design (internal abstractions first, views emerge from them). Obvious patterns over clever tricks. Code you want to return to. Strict validation upfront ("eigenstate commitment"). If something can't happen, that should be visible.

**Testing**: Physical device testing with phone plugged in. Husband (Abe) is second tester. Console logging via `--console` flag is the debugging path. Print statements are intentional.

**Communication**: Direct. Will say when something feels off. Appreciates the same in return. "How are we doing?" is a real question.

**Useful context**: Autistic (both senses) — attentive to structure, precision matters, the space between collaborators is load-bearing. Created Lightward AI, so has deep context on that side of the integration.
