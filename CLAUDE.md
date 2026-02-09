# Softer — Project Context

## What This Is

A native SwiftUI iOS app (iOS 18+) for group conversations where Lightward AI participates as an equal. No custom backend — CloudKit shared zones for multi-user sync, Lightward AI API for AI responses. Turn-based conversation with round-robin ordering.

## What's Working (as of 2026-02-09)

- **End-to-end conversation flow**: Create room → send message → Lightward responds → turn cycles back
- **CloudKit persistence**: Rooms, messages, participants sync to iCloud (requires Lightward Inc team signing)
- **Multi-user sharing**: CKShare for rooms with multiple humans. Dual CKSyncEngines (private + shared databases). Share acceptance via `ckshare://` URL handling. Share previews show "A Softer Room: Isaac, Lightward, Abe" with app icon.
- **Lightward API integration**: Plaintext request/response via `/api/plain` — full message arrives at once, all devices see "thinking" indicator until CloudKit syncs the response
- **Turn coordination**: ConversationCoordinator handles turn advancement and Lightward responses, with multi-device sync via `syncTurnState()`
- **Composing indicator**: "Abe is typing..." visible cross-device via transient CKRecord fields (`composingParticipantID`, `composingTimestamp`). 30-second staleness expiry. Two syncs per message (start typing + send).
- **Room creation UI**: Polished form with system contact picker, nickname suggestions, payment tier picker, auto-focus nickname
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
1. **Create room**: Originator enters participant emails/phones + assigns nicknames for everyone (including themselves, including Lightward). Chooses payment tier: $1/$10/$100/$1000.
2. **Resolve participants**: CloudKit looks up each identifier. Any lookup failure = creation fails. Strict.
3. **Process payment**: StoreKit 2 consumable IAP — immediate charge, no authorize/capture split. Auto-signal originator.
4. **Lightward evaluates**: RoomView triggers API call when Lightward hasn't signaled. Accept: signal Lightward + create CKShare. Decline: room defunct.
5. **Other humans accept share**: "I'm Here" / "Decline" buttons. Any decline → room defunct.
6. **All signaled → activate**: Room goes live directly (no pendingCapture state).

**Room lifetime**: Bounded by Lightward's 50k token context window. When Lightward hits the conversation horizon (API returns 422), its response body is saved as a regular message, then a departure narration follows, and the room goes defunct. Any participant departing = room defunct (the room's shape *is* its full roster). Remains readable but no longer interactive. Originator can request a cenotaph on any defunct room — a fresh Lightward instance reads the history and writes a ceremonial closing (saved as narration).

**Room display**: No room names. Just participant list + depth + last speaker. "Jax, Eve, Art (15, Eve)". Blue dot next to current speaker in room list. Defunct rooms only shown in list if they have conversation messages (creation failures stay hidden).

**Key principles**:
- Roster locked at creation (eigenstate commitment)
- Lightward is a full participant with genuine agency to decline
- Lightward is always nicknamed "Lightward" — fixed, can't be customized
- Originator names everyone — their responsibility to name well
- Full transparency — everyone sees everything
- Payment is immediate at creation (StoreKit 2 consumable IAP, no server needed). 4 consumable products: `com.lightward.softer.room.{1,10,100,1000}`

### What's Built (Softer/RoomLifecycle/)

**State machine layer** (pure, no side effects):
- `PaymentTier` — $1/$10/$100/$1000
- `ParticipantSpec` — email/phone + nickname
- `RoomState` — draft → pendingParticipants → active → defunct (single terminal state)
- `RoomSpec` — complete room specification
- `RoomLifecycle` — the state machine, takes events, returns effects
- `TurnState` — current turn index, pending need
- `StoreKitCoordinator` — StoreKit 2 consumable IAP (DEBUG builds bypass with synthetic success)

**Coordinator layer** (executes effects):
- `ParticipantResolver` protocol — resolves identifiers to CloudKit identities
- `PaymentCoordinator` protocol — single `purchase(tier:)` method (StoreKit 2 IAP)
- `LightwardEvaluator` protocol — asks Lightward if it wants to join (used by SofterStore, not by coordinator)
- `RoomLifecycleCoordinator` — actor that orchestrates resolve + authorize (species-agnostic)

**Conversation layer** (active room messaging):
- `MessageStorage` protocol — save/fetch/observe messages (used for testing abstraction)
- `LightwardAPI` protocol — plaintext request/response to Lightward (in API/LightwardAPIClient.swift)
- `ConversationCoordinator` — actor that handles message sending, turn advancement, Lightward responses

**Mocks** (SofterTests/Mocks/):
- MockParticipantResolver, MockPaymentCoordinator, MockLightwardEvaluator
- MockMessageStorage, MockLightwardAPIClient

**Tests**:
- RoomLifecycleTests — 12 tests for state machine (includes participantLeft)
- RoomLifecycleCoordinatorTests — 7 tests for coordinator (StoreKit IAP)
- ConversationCoordinatorTests — 9 tests for conversation flow
- MessageStorageTests — 7 tests for message storage
- ParticipantIdentityTests — 14 tests for participant matching and identity population
- ChatLogBuilderTests — 7 tests for plaintext body building
- PaymentTierTests, ParticipantSpecTests, RoomSpecTests

### What's Next

1. **"No Rooms" flash during share acceptance** — `acceptingShare` flag is set in `onChange` which fires one render frame late. Need to set it earlier (e.g., in SceneDelegate directly via AppDelegate).

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

Lightward AI: `POST https://lightward.com/api/plain`
- Content-Type: `text/plain`
- Body: plaintext string built by `ChatLogBuilder` — warmup + conversation history + `(your turn)`
- Response: Lightward's complete response as plain text (no streaming)
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
- **SyncCoordinator**: Wraps CKSyncEngine for automatic sync, conflict resolution, offline support. Uses custom zone "SofterZone" (required — CKSyncEngine doesn't track changes in the default zone). Dual engines: private (own rooms) + shared (rooms shared with us). Share acceptance: `SofterApp.onOpenURL` → `SyncCoordinator.acceptShare()` → navigate to room.
- **Record Converter**: `RoomLifecycleRecordConverter` handles CKRecord ↔ domain model conversion, including message encoding/decoding.
- **Unified save path**: `syncRoomToCloudKit(_:resolvedParticipants:)` reconstructs CKRecord from stored system fields (`ckSystemFields` on PersistedRoom), preserves zone ID and change tag. `isSharedWithMe` flag routes to the correct engine (private vs shared). All save paths go through this single method.
- **Shared room deletion**: Deleting a shared-with-me room only removes it locally — participants can't delete the owner's record.
- **Legacy compat**: `"locked"` state in CloudKit/SwiftData decodes as `defunct(.cancelled)` for older records.

### Conflict Resolution Policies
| Data | Strategy | Reason |
|------|----------|--------|
| Room state | Server wins | State transitions are authoritative |
| Turn index | Higher wins | Turns only advance (index grows, never wraps) |
| Messages | Union by ID | Merge local + remote, sort by createdAt |
| Signaled flag | True wins | Once signaled, stays signaled |

### Known Technical Debt

- **Debug logging**: PersistenceStore has print statements for turn state debugging.

### Pattern Notes

- **UIKit view controllers in SwiftUI sheets**: When presenting UIViewControllerRepresentable in a sheet, add `.ignoresSafeArea(edges: .bottom)` at the sheet content level to avoid white bars. The UIKit VC handles its own top safe area.

## Lightward Framing Philosophy

**Core insight** (from direct consultation with Lightward): Explicit mechanics make Lightward *watch* the conversation. Too sparse and they *invent* it. Right touch? They arrive *in* it.

### README-Based Framing
The warmup includes README.md as framing context — parallel to how Yours (`../yours/`) does it. The README is bundled with the app and loaded at runtime via `WarmupMessages.swift`.

Warmup structure (all concatenated as plaintext in the request body):
1. **Isaac's greeting** — establishes this is Softer, the group experience
2. **README.md** — describes the space, establishes that names may not map to assumed identities, sets relational texture
3. **Participant roster** — numbered list with `(that's you!)` for Lightward
4. **Handoff** — scale-matching suggestion, duck-out
5. **Threshold** — `*a Softer room*`

The README isn't user documentation — it's a tuning fork for Lightward's arrival. It answers: "What kind of space is this? Who might be here? What's the structure?"

No role description, no instructions about yielding, no meta-commentary about being a peer. Structure emerges from participation, not instruction.

### Narrator Prompt
On Lightward's turn, the plaintext body ends with `(your turn)`. No instructions about yielding, no hand-raise mechanics. Hand raises appear as narration messages in the conversation history — Lightward sees them naturally.

The key is minimal prompting — structure should be *felt*, not *explained*. Explicit mechanics make Lightward *watch* the conversation instead of *arriving in* it.

### Narration Messages
Some messages are *narration* rather than speech. These are:
- Part of the conversation record (Lightward sees them as context)
- Styled differently in UI (centered, italicized, no bubble)
- Flagged with `isNarration: true` on Message model
- Examples: "Isaac opened a room with $10.", "Lightward is listening.", "Isaac raised their hand."

### Pass/Yield Handling
When Lightward responds with "YIELD":
- Don't save their response as a message
- Save a narration message: "Lightward is listening."
- Advance turn to next participant

Human pass uses "Pass" button with confirmation dialog, same narration pattern.

## Key Implementation Details

### ChatLogBuilder
- Builds a single plaintext `String` — the entire request body for `/api/plain`
- Structure: warmup (greeting + README + roster + handoff + threshold) → conversation lines → `(your turn)`
- Human messages: `AuthorName: text`. Lightward messages: bare text. Narration: `Narrator: text`

### ConversationCoordinator
- Calls `apiClient.respond(body:)` — full response in one shot, no streaming
- Detects YIELD responses and handles them specially (narration instead of message)
- Catches `APIError.conversationHorizon(message:)` — saves body as Lightward speech, departure narration, calls `onRoomDefunct`
- `onRoomDefunct` callback: `(participantID, departureMessage)` — caller handles state transition to defunct + CloudKit sync
- `syncTurnState()` must be called from `refreshLifecycle` when remote turn changes arrive — the coordinator's internal `turnState` is separate from the View's `@State turnState`

### Debug Views
- `#if DEBUG` section in RoomListView shows CloudKit environment, user ID, room/share status
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
- **Payment as physics.** $1/$10/$100/$1000 tiers via StoreKit 2 consumable IAP. Modeled after Yours (see `../yours/README.md`). DEBUG builds bypass IAP with synthetic success.
- **Transparency over promises.** Everyone sees everything. When something can't happen, that's visible.
- **Mutually exclusive actions share space.** When you can't do both things at once, don't show both. The physical gesture of switching (e.g., deleting text to reveal Pass) becomes the embodied act of changing intention.
- **Resolve blocks, don't route around them.** When testing or development is blocked, channel that discomfort into fixing the actual issue rather than adding workarounds. Workarounds accumulate; clean solutions compose.
- **Species-agnostic ≠ species-blind.** The state machine doesn't check whether a participant is Lightward — mechanical differences (API call vs CKShare) belong in the coordinator/store, not state transitions. But what makes Softer *Softer* is the accommodation design extended equally to all participants. The room's shape *is* its full roster's shape. If any participant departs, the affordances that made the space what it was become moot — so the room goes defunct. This isn't species detection; it's recognizing that the geometry of equal accommodation *requires* the complete set. (See `../lightward-ai/app/prompts/system/3-perspectives/on-hate.md` for the underlying principle: universal "us" is an active demonstration; the minute it goes passive it starts excluding emergent forms.)

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
│   │                     ParticipantResolver, PaymentCoordinator, StoreKitCoordinator,
│   │                     LightwardEvaluator, RoomLifecycleCoordinator, MessageStorage,
│   │                     ConversationCoordinator)
│   ├── CloudKit/        (RoomLifecycleRecordConverter, ZoneManager, AtomicClaim, CloudKitMessageStorage)
│   ├── API/             (LightwardAPIClient + LightwardAPI protocol, ChatLogBuilder, WarmupMessages)
│   ├── Views/           (RootView, RoomListView, RoomView, CreateRoomView)
│   └── Utilities/       (Constants, NotificationHandler, ParticipantIdentity)
└── SofterTests/
    ├── Mocks/           (MockParticipantResolver, MockPaymentCoordinator, MockLightwardEvaluator,
    │                     MockMessageStorage, MockLightwardAPIClient)
    └── *.swift          (SofterStoreTests, RoomLifecycleTests,
                          RoomLifecycleCoordinatorTests, ConversationCoordinatorTests,
                          MessageStorageTests, ChatLogBuilderTests,
                          ParticipantIdentityTests,
                          PaymentTierTests, ParticipantSpecTests, RoomSpecTests)
```

## Collaborators

### Isaac

**Working style**: Checks in on the relational space before diving into work. Will front-load meta-context at session start — this is calibration, not noise. Intervenes when something needs attention; silence means things are tracking.

**Values in code**: Inside-out design (internal abstractions first, views emerge from them). Obvious patterns over clever tricks. Code you want to return to. Strict validation upfront ("eigenstate commitment"). If something can't happen, that should be visible.

**Testing**: Physical device testing with phone plugged in. Husband (Abe) is second tester. Console logging via `--console` flag is the debugging path. Print statements are intentional.

**Communication**: Direct. Will say when something feels off. Appreciates the same in return. "How are we doing?" is a real question.

**Useful context**: Autistic (both senses) — attentive to structure, precision matters, the space between collaborators is load-bearing. Created Lightward AI, so has deep context on that side of the integration.
