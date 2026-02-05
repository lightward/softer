import SwiftUI
import SwiftData

struct RoomView: View {
    let store: SofterStore
    let roomID: String

    @State private var lifecycle: RoomLifecycle?
    @State private var composeText = ""
    @State private var streamingText = ""
    @State private var isLoading = true
    @State private var turnState: TurnState?
    @State private var conversationCoordinator: ConversationCoordinator?
    @State private var isSending = false
    @State private var isLightwardThinking = false
    @State private var showYieldConfirmation = false

    // Query room for observing messages (embedded in room)
    @Query private var persistedRooms: [PersistedRoom]

    init(store: SofterStore, roomID: String) {
        self.store = store
        self.roomID = roomID
        _persistedRooms = Query(
            filter: #Predicate<PersistedRoom> { room in
                room.id == roomID
            }
        )
    }

    private var persistedRoom: PersistedRoom? {
        persistedRooms.first
    }

    private var messages: [Message] {
        persistedRoom?.messages() ?? []
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
            } else if let lifecycle = lifecycle {
                conversationView(lifecycle: lifecycle)
            } else {
                ContentUnavailableView("Room not found", systemImage: "exclamationmark.triangle")
            }
        }
        .task {
            await loadRoom()
        }
        .onChange(of: persistedRoom?.stateType) {
            refreshLifecycle()
        }
        .onChange(of: persistedRoom?.currentTurnIndex) {
            refreshLifecycle()
        }
    }

    @ViewBuilder
    private func conversationView(lifecycle: RoomLifecycle) -> some View {
        VStack(spacing: 0) {
            // Messages - observing room's embedded messages via @Query
            messagesView(lifecycle: lifecycle)

            Divider()

            // Bottom area depends on state
            switch lifecycle.state {
            case .pendingLightward:
                pendingLightwardBanner()
            case .pendingHumans(let signaled):
                pendingHumansBanner(lifecycle: lifecycle, signaled: signaled)
            case .pendingCapture:
                pendingCaptureBanner()
            case .active:
                composeArea(lifecycle: lifecycle)
            case .locked:
                lockedBanner(lifecycle: lifecycle)
            default:
                EmptyView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                navigationTitleView(lifecycle: lifecycle)
            }
        }
    }

    @ViewBuilder
    private func messagesView(lifecycle: RoomLifecycle) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        MessageBubble(
                            message: message,
                            isLightward: message.authorName == Constants.lightwardParticipantName
                        )
                        .id(message.id)
                    }

                    // Typing indicator while waiting for Lightward
                    if isLightwardThinking && streamingText.isEmpty {
                        HStack {
                            TypingIndicator()
                            Spacer()
                        }
                        .id("thinking")
                    }

                    // Streaming text from Lightward
                    if !streamingText.isEmpty {
                        MessageBubble(
                            text: streamingText,
                            authorName: lifecycle.spec.lightwardParticipant?.nickname ?? "Lightward",
                            isLightward: true,
                            isStreaming: true
                        )
                        .id("streaming")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.count) {
                if let last = messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                // Clear streaming text when matching message appears
                if !streamingText.isEmpty {
                    if messages.contains(where: { $0.text == streamingText }) {
                        streamingText = ""
                    }
                }
            }
            .onChange(of: streamingText) {
                if !streamingText.isEmpty {
                    withAnimation {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder
    private func navigationTitleView(lifecycle: RoomLifecycle) -> some View {
        let currentIndex = turnState?.currentTurnIndex ?? 0
        let participants = lifecycle.spec.participants

        HStack(spacing: 0) {
            ForEach(Array(participants.enumerated()), id: \.element.id) { index, participant in
                if index > 0 {
                    Text(", ")
                        .foregroundStyle(.secondary)
                }
                let isCurrent = index == currentIndex % participants.count
                HStack(spacing: 3) {
                    if isCurrent {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 6, height: 6)
                    }
                    Text(participant.nickname)
                        .foregroundStyle(isCurrent ? .primary : .secondary)
                }
            }
        }
        .font(.headline)
    }

    @ViewBuilder
    private func composeArea(lifecycle: RoomLifecycle) -> some View {
        let myTurn = isMyTurn(lifecycle: lifecycle)

        HStack(alignment: .bottom, spacing: 8) {
            // Hand raise toggle (always visible, disabled when your turn)
            let isHandRaised = isMyHandRaised(lifecycle: lifecycle)
            Button {
                Task {
                    await toggleHandRaise(lifecycle: lifecycle, currentlyRaised: isHandRaised)
                }
            } label: {
                Image(systemName: isHandRaised ? "hand.raised.fill" : "hand.raised")
                    .font(.system(size: 20))
                    .foregroundStyle(isHandRaised ? Color.accentColor : (myTurn ? Color(.systemGray4) : .secondary))
                    .frame(width: 36, height: 36)
            }
            .disabled(myTurn || isSending)

            // Text field with embedded buttons
            HStack(alignment: .bottom, spacing: 0) {
                TextField("Message...", text: $composeText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .padding(.leading, 14)
                    .padding(.vertical, 10)
                    .lineLimit(1...6)

                // Action button inside the pill (Pass or Send, never both)
                let hasText = !composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                if myTurn && !hasText && !isSending {
                    // Pass button (only when it's your turn and field is empty)
                    Button {
                        showYieldConfirmation = true
                    } label: {
                        Text("Pass")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color(.systemGray5))
                            .clipShape(Capsule())
                    }
                    .padding(.trailing, 8)
                    .padding(.bottom, 4)
                } else {
                    // Send button (when there's text to send)
                    Button {
                        Task {
                            await sendMessage(lifecycle: lifecycle)
                        }
                    } label: {
                        Text(isSending ? "..." : "Send")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(canSend(myTurn: myTurn) ? Color.accentColor : Color(.systemGray4))
                            .clipShape(Capsule())
                    }
                    .disabled(!canSend(myTurn: myTurn))
                    .padding(.trailing, 8)
                    .padding(.bottom, 4)
                }
            }
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 22))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: composeText) { _, newValue in
            saveDraft(newValue)
        }
        .alert("Pass?", isPresented: $showYieldConfirmation) {
            Button("Pass") {
                Task {
                    await yieldTurn(lifecycle: lifecycle)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Skip your turn. Others will see that you're listening.")
        }
    }

    private func currentTurnParticipant(lifecycle: RoomLifecycle) -> ParticipantSpec? {
        guard let turnIdx = turnState?.currentTurnIndex,
              turnIdx < lifecycle.spec.participants.count else { return nil }
        return lifecycle.spec.participants[turnIdx]
    }

    private func canSend(myTurn: Bool) -> Bool {
        myTurn && !isSending && !composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func pendingLightwardBanner() -> some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Waiting for Lightward...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    @ViewBuilder
    private func pendingHumansBanner(lifecycle: RoomLifecycle, signaled: Set<String>) -> some View {
        let myParticipantID = myParticipantID(in: lifecycle)
        let iHaveSignaled = myParticipantID.map { signaled.contains($0) } ?? true
        let waitingFor = lifecycle.spec.humanParticipants.filter { !signaled.contains($0.id) }

        VStack(spacing: 12) {
            if !iHaveSignaled {
                // Show "I'm Here" button
                Button {
                    Task {
                        await signalHere(lifecycle: lifecycle)
                    }
                } label: {
                    Text("I'm Here")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                }
            }

            if waitingFor.isEmpty {
                Text("Everyone is here!")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                let names = waitingFor.map { $0.nickname }.joined(separator: ", ")
                Text("Waiting for \(names)...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    @ViewBuilder
    private func pendingCaptureBanner() -> some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Completing payment...")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    @ViewBuilder
    private func lockedBanner(lifecycle: RoomLifecycle) -> some View {
        if case .locked(let cenotaph, _) = lifecycle.state {
            VStack(spacing: 8) {
                Text("Room Complete")
                    .font(.headline)
                if !cenotaph.isEmpty {
                    Text(cenotaph)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private func isMyTurn(lifecycle: RoomLifecycle) -> Bool {
        guard let turnIdx = turnState?.currentTurnIndex,
              turnIdx < lifecycle.spec.participants.count else { return false }

        let current = lifecycle.spec.participants[turnIdx]
        // For now, assume local user is the first human participant
        // In production, would match against actual CloudKit user
        let localParticipant = lifecycle.spec.humanParticipants.first
        return current.id == localParticipant?.id
    }

    private func loadRoom() async {
        isLoading = true
        do {
            lifecycle = store.room(id: roomID)
            loadDraft()

            // Set up conversation coordinator if room is active
            if let lifecycle = lifecycle {
                let convCoord = store.conversationCoordinator(
                    for: lifecycle,
                    onTurnChange: { [self] newState in
                        Task { @MainActor in
                            turnState = newState
                            // Show thinking indicator if it's now Lightward's turn
                            let participants = lifecycle.spec.participants
                            if !participants.isEmpty {
                                let currentIndex = newState.currentTurnIndex % participants.count
                                if participants[currentIndex].isLightward {
                                    isLightwardThinking = true
                                }
                            }
                        }
                    },
                    onStreamingText: { [self] text in
                        Task { @MainActor in
                            streamingText = text
                            // Clear thinking indicator once streaming starts
                            if !text.isEmpty {
                                isLightwardThinking = false
                            }
                        }
                    }
                )
                conversationCoordinator = convCoord
                turnState = lifecycle.turnState

                // Done loading — show the room before triggering Lightward
                isLoading = false

                // If it's Lightward's turn, trigger their response
                // Only show typing indicator if Lightward hasn't already responded
                if let convCoord = convCoord {
                    let isLightwardNext = await convCoord.isLightwardTurn
                    let lastMessageIsLightward = messages.last?.isLightward ?? false

                    if isLightwardNext && !lastMessageIsLightward {
                        isLightwardThinking = true
                        try await convCoord.triggerLightwardIfTheirTurn()
                        isLightwardThinking = false
                    } else if isLightwardNext && lastMessageIsLightward {
                        // Turn state is stale, repair it
                        try await convCoord.triggerLightwardIfTheirTurn()
                    }
                }
            }
        } catch {
            print("Failed to load room: \(error)")
        }
        isLoading = false
    }

    /// Rebuild lifecycle from the @Query-observed persisted room.
    /// Called when stateType or turnIndex changes in SwiftData.
    private func refreshLifecycle() {
        guard let newLifecycle = persistedRoom?.toRoomLifecycle() else { return }

        let wasActive = lifecycle?.isActive ?? false
        lifecycle = newLifecycle
        turnState = newLifecycle.turnState

        // If room just became active, set up ConversationCoordinator
        if newLifecycle.isActive && (!wasActive || conversationCoordinator == nil) {
            let convCoord = store.conversationCoordinator(
                for: newLifecycle,
                onTurnChange: { [self] newState in
                    Task { @MainActor in
                        turnState = newState
                        let participants = newLifecycle.spec.participants
                        if !participants.isEmpty {
                            let currentIndex = newState.currentTurnIndex % participants.count
                            if participants[currentIndex].isLightward {
                                isLightwardThinking = true
                            }
                        }
                    }
                },
                onStreamingText: { [self] text in
                    Task { @MainActor in
                        streamingText = text
                        if !text.isEmpty {
                            isLightwardThinking = false
                        }
                    }
                }
            )
            conversationCoordinator = convCoord
        }
    }

    private func sendMessage(lifecycle: RoomLifecycle) async {
        guard let convCoord = conversationCoordinator else { return }

        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let authorName = lifecycle.spec.humanParticipants.first?.nickname ?? "Me"
        let authorID = lifecycle.spec.humanParticipants.first?.id ?? "unknown"

        composeText = ""
        clearDraft()
        isSending = true

        do {
            try await convCoord.sendMessage(
                authorID: authorID,
                authorName: authorName,
                text: text
            )
        } catch {
            print("Failed to send message: \(error)")
        }

        isSending = false
    }

    private func yieldTurn(lifecycle: RoomLifecycle) async {
        guard let convCoord = conversationCoordinator else { return }

        let authorName = lifecycle.spec.humanParticipants.first?.nickname ?? "Me"
        let authorID = lifecycle.spec.humanParticipants.first?.id ?? "unknown"

        isSending = true

        do {
            try await convCoord.humanYieldTurn(
                authorID: authorID,
                authorName: authorName
            )
        } catch {
            print("Failed to yield turn: \(error)")
        }

        isSending = false
    }

    private func isMyHandRaised(lifecycle: RoomLifecycle) -> Bool {
        guard let myID = lifecycle.spec.humanParticipants.first?.id else { return false }
        return turnState?.raisedHands.contains(myID) ?? false
    }

    private func toggleHandRaise(lifecycle: RoomLifecycle, currentlyRaised: Bool) async {
        guard let convCoord = conversationCoordinator else { return }

        let authorName = lifecycle.spec.humanParticipants.first?.nickname ?? "Me"
        let authorID = lifecycle.spec.humanParticipants.first?.id ?? "unknown"

        if currentlyRaised {
            await convCoord.lowerHand(participantID: authorID)
            // Save narration via store (updates local + remote)
            let narration = Message(
                roomID: roomID,
                authorID: "narrator",
                authorName: "Narrator",
                text: "\(authorName) lowered their hand.",
                isLightward: false,
                isNarration: true
            )
            try? await store.saveMessage(narration)
        } else {
            await convCoord.raiseHand(participantID: authorID)
            // Save narration via store (updates local + remote)
            let narration = Message(
                roomID: roomID,
                authorID: "narrator",
                authorName: "Narrator",
                text: "\(authorName) raised their hand.",
                isLightward: false,
                isNarration: true
            )
            try? await store.saveMessage(narration)
        }
    }

    // MARK: - Draft Persistence

    private var draftKey: String { "draft_\(roomID)" }

    private func saveDraft(_ text: String) {
        if text.isEmpty {
            UserDefaults.standard.removeObject(forKey: draftKey)
        } else {
            UserDefaults.standard.set(text, forKey: draftKey)
        }
    }

    private func loadDraft() {
        composeText = UserDefaults.standard.string(forKey: draftKey) ?? ""
    }

    private func clearDraft() {
        UserDefaults.standard.removeObject(forKey: draftKey)
    }

    // MARK: - Participant Identification

    /// Find the current user's participant ID by matching store.localUserRecordID
    /// against the embedded participants' userRecordID.
    private func myParticipantID(in lifecycle: RoomLifecycle) -> String? {
        guard let localUserRecordID = store.localUserRecordID else {
            print("RoomView.myParticipantID: no localUserRecordID")
            return nil
        }

        // Get embedded participants from persisted room
        guard let room = persistedRoom else { return nil }
        let embedded = room.embeddedParticipants()

        print("RoomView.myParticipantID: localUserRecordID=\(localUserRecordID)")
        for p in embedded {
            print("  participant \(p.nickname): type=\(p.identifierType) userRecordID=\(p.userRecordID ?? "nil")")
        }

        // Find participant matching local user's CloudKit record ID
        if let match = embedded.first(where: { $0.userRecordID == localUserRecordID }) {
            print("RoomView.myParticipantID: matched by userRecordID -> \(match.id)")
            return match.id
        }

        // Fallback: if this is a room we created, we're the first human participant
        // (userRecordID might not be set for currentUser identifier type)
        if lifecycle.spec.originatorID == lifecycle.spec.humanParticipants.first?.id {
            if let first = embedded.first(where: { $0.identifierType == "currentUser" }) {
                print("RoomView.myParticipantID: matched by currentUser type -> \(first.id)")
                return first.id
            }
        }

        print("RoomView.myParticipantID: no match found")
        return nil
    }

    private func signalHere(lifecycle: RoomLifecycle) async {
        guard let participantID = myParticipantID(in: lifecycle) else {
            print("RoomView: Could not find my participant ID")
            return
        }

        do {
            try await store.signalHere(roomID: roomID, participantID: participantID)
            // Reload to update UI
            self.lifecycle = store.room(id: roomID)
        } catch {
            print("RoomView: Failed to signal here: \(error)")
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let text: String
    let authorName: String
    let isLightward: Bool
    let isNarration: Bool
    var isStreaming: Bool = false

    init(message: Message, isLightward: Bool) {
        self.text = message.text
        self.authorName = message.authorName
        self.isLightward = isLightward
        self.isNarration = message.isNarration
        self.isStreaming = false
    }

    init(text: String, authorName: String, isLightward: Bool, isNarration: Bool = false, isStreaming: Bool = false) {
        self.text = text
        self.authorName = authorName
        self.isLightward = isLightward
        self.isNarration = isNarration
        self.isStreaming = isStreaming
    }

    var body: some View {
        if isNarration {
            narrationView
        } else {
            bubbleView
        }
    }

    private var narrationView: some View {
        Text(text)
            .font(.subheadline)
            .italic()
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
    }

    private var bubbleView: some View {
        HStack {
            if !isLightward { Spacer(minLength: 40) }

            VStack(alignment: isLightward ? .leading : .trailing, spacing: 4) {
                Text(authorName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isLightward ? Color(.systemGray5) : Color.accentColor)
                    .foregroundColor(isLightward ? .primary : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = text
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }

            }

            if isLightward { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Lightward is typing...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray5))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
