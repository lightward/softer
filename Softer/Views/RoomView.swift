import SwiftUI
import SwiftData
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct RoomView: View {
    let store: SofterStore
    let roomID: String
    @Binding var selectedRoomID: String?

    @State private var lifecycle: RoomLifecycle?
    @State private var composeText = ""
    @State private var isLoading = true
    @State private var turnState: TurnState?
    @State private var conversationCoordinator: ConversationCoordinator?
    @State private var isSending = false
    @State private var isLightwardThinking = false
    @State private var showYieldConfirmation = false
    @State private var showLeaveConfirmation = false
    @State private var isCurrentlyComposing = false
    @State private var composingCheckTimer: Timer?
    @State private var participantPhotos: [String: Image] = [:]
    @State private var speechRecognizer = SpeechRecognizer()
    @State private var showSpeechPermissionDenied = false

    // Query room for observing messages (embedded in room)
    @Query private var persistedRooms: [PersistedRoom]

    init(store: SofterStore, roomID: String, selectedRoomID: Binding<String?>) {
        self.store = store
        self.roomID = roomID
        _selectedRoomID = selectedRoomID
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
            store.startPolling(roomID: roomID)
            await loadRoom()
            loadParticipantPhotos()
        }
        .onAppear {
            store.currentlyViewingRoomID = roomID

            // Timer to expire stale composing indicators (the Date() check in
            // messagesView only runs on render — this forces periodic re-evaluation)
            composingCheckTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                Task { @MainActor in
                    if let composing = store.composingByRoom[roomID],
                       Date().timeIntervalSince(composing.timestamp) >= 30 {
                        store.clearComposing(roomID: roomID)
                    }
                }
            }
        }
        .onDisappear {
            store.currentlyViewingRoomID = nil

            composingCheckTimer?.invalidate()
            composingCheckTimer = nil
            store.stopPolling()
            if isCurrentlyComposing {
                isCurrentlyComposing = false
                store.clearComposing(roomID: roomID, sync: true)
            }
        }
        .onChange(of: persistedRoom?.stateType) {
            refreshLifecycle()
        }
        .onChange(of: persistedRoom?.currentTurnIndex) {
            refreshLifecycle()
        }
        .onChange(of: persistedRoom?.participantsJSON) {
            refreshLifecycle()
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            // Re-signal composing after foregrounding (clearAllComposing wiped it on background)
            if isCurrentlyComposing, let lifecycle = lifecycle, let myID = myParticipantID(in: lifecycle) {
                store.setComposing(roomID: roomID, participantID: myID)
            }
        }
        #elseif os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if isCurrentlyComposing, let lifecycle = lifecycle, let myID = myParticipantID(in: lifecycle) {
                store.setComposing(roomID: roomID, participantID: myID)
            }
        }
        #endif
    }

    @ViewBuilder
    private func conversationView(lifecycle: RoomLifecycle) -> some View {
        VStack(spacing: 0) {
            // Messages - observing room's embedded messages via @Query
            messagesView(lifecycle: lifecycle)

            Divider()

            // Bottom area depends on state
            switch lifecycle.state {
            case .pendingParticipants(let signaled):
                pendingParticipantsBanner(lifecycle: lifecycle, signaled: signaled)
            case .active:
                composeArea(lifecycle: lifecycle)
            case .defunct:
                defunctBanner(lifecycle: lifecycle)
            default:
                EmptyView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                navigationTitleView(lifecycle: lifecycle)
            }
            if lifecycle.isActive {
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button(role: .destructive) {
                            showLeaveConfirmation = true
                        } label: {
                            Label("Leave Room", systemImage: "figure.walk.departure")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .alert("Leave Room?", isPresented: $showLeaveConfirmation) {
            Button("Leave", role: .destructive) {
                Task {
                    await leaveRoom(lifecycle: lifecycle)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The room will end for everyone. This can't be undone.")
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
                            style: messageStyle(for: message, in: lifecycle)
                        )
                        .id(message.id)
                    }

                    // Composing indicator for remote human typing
                    if let composing = store.composingByRoom[roomID],
                       composing.participantID != myParticipantID(in: lifecycle),
                       Date().timeIntervalSince(composing.timestamp) < 30 {
                        let name = lifecycle.spec.participants.first { $0.id == composing.participantID }?.nickname ?? "Someone"
                        let embedded = persistedRoom?.embeddedParticipants() ?? []
                        let participant = embedded.first { $0.id == composing.participantID }
                        let color = Color.participantColor(orderIndex: participant?.orderIndex ?? 0)
                        ComposingIndicator(name: name, color: color, photo: participantPhotos[composing.participantID])
                            .id("composing")
                    }

                    // Typing indicator while waiting for Lightward
                    if isLightwardThinking {
                        TypingIndicator()
                            .id("thinking")
                    }

                    // Invisible anchor for reliable scroll-to-bottom
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding([.horizontal, .top])
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.bottom)
            .onChange(of: messages.count) {
                withAnimation {
                    proxy.scrollTo("bottom")
                }
                // Clear thinking indicator when a Lightward message appears
                if isLightwardThinking {
                    if messages.last?.isLightward == true {
                        isLightwardThinking = false
                    }
                }
            }
            .onChange(of: isLightwardThinking) {
                if isLightwardThinking {
                    withAnimation {
                        proxy.scrollTo("bottom")
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

        Group {
            if myTurn {
                // My turn: full compose area
                HStack(alignment: .bottom, spacing: 0) {
                    // Dictation button
                    Button {
                        if speechRecognizer.isRecording {
                            speechRecognizer.stopRecording()
                        } else {
                            speechRecognizer.transcript = composeText
                            speechRecognizer.startRecording()
                        }
                    } label: {
                        Image(systemName: speechRecognizer.isRecording ? "mic.fill" : "mic")
                            .font(.system(size: 17))
                            .foregroundStyle(speechRecognizer.isRecording ? Color.accentColor : .secondary)
                            .frame(width: 36, height: 36)
                    }
                    .disabled(isSending)
                    .padding(.leading, 4)
                    .padding(.bottom, 1)

                    TextField("Message...", text: $composeText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .padding(.leading, 10)
                        .padding(.trailing, 4)
                        .padding(.vertical, 10)
                        .lineLimit(1...6)

                    let hasText = !composeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

                    if !hasText && !isSending {
                        // Pass button (field is empty)
                        Button {
                            showYieldConfirmation = true
                        } label: {
                            Text("Pass")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.softerGray5)
                                .clipShape(Capsule())
                        }
                        .padding(.trailing, 8)
                        .padding(.bottom, 4)
                    } else {
                        // Send button
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
                                .background(canSend(myTurn: true) ? Color.accentColor : Color.softerGray4)
                                .clipShape(Capsule())
                        }
                        .disabled(!canSend(myTurn: true))
                        .padding(.trailing, 8)
                        .padding(.bottom, 4)
                    }
                }
                .background(Color.softerGray6)
                .clipShape(RoundedRectangle(cornerRadius: 22))
            } else {
                // Not my turn: whose turn it is + hand raise
                let currentIndex = turnState?.currentTurnIndex ?? 0
                let participants = lifecycle.spec.participants
                let currentName = participants.isEmpty ? "" : participants[currentIndex % participants.count].nickname

                HStack {
                    Text("\(currentName)'s turn")
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 16)

                    Spacer()

                    Button {
                        Task {
                            await raiseHand(lifecycle: lifecycle)
                        }
                    } label: {
                        Text("Raise hand")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }
                    .disabled(isSending)
                    .padding(.trailing, 8)
                    .padding(.bottom, 4)
                }
                .frame(minHeight: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.softerGray4, lineWidth: 1)
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: composeText) { _, newValue in
            saveDraft(newValue)

            let hasText = !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasText && !isCurrentlyComposing {
                isCurrentlyComposing = true
                if let myID = myParticipantID(in: lifecycle) {
                    store.setComposing(roomID: roomID, participantID: myID)
                }
            } else if !hasText && isCurrentlyComposing {
                isCurrentlyComposing = false
                store.clearComposing(roomID: roomID, sync: true)
            }
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
        .onChange(of: speechRecognizer.transcript) { _, newValue in
            if speechRecognizer.isRecording {
                composeText = newValue
            }
        }
        .onChange(of: speechRecognizer.permissionDenied) { _, denied in
            if denied {
                showSpeechPermissionDenied = true
                speechRecognizer.permissionDenied = false
            }
        }
        .alert("Microphone Access Required", isPresented: $showSpeechPermissionDenied) {
            Button("Open Settings") {
                #if os(iOS)
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                #elseif os(macOS)
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
                #endif
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enable microphone and speech recognition access in Settings to use voice input.")
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

    @State private var showDeclineConfirmation = false

    @ViewBuilder
    private func pendingParticipantsBanner(lifecycle: RoomLifecycle, signaled: Set<String>) -> some View {
        let myParticipantID = myParticipantID(in: lifecycle)
        let iHaveSignaled = myParticipantID.map { signaled.contains($0) } ?? true
        let waitingFor = lifecycle.spec.participants.filter { !signaled.contains($0.id) }

        VStack(spacing: 12) {
            if !iHaveSignaled {
                // Lightward has signaled, but I haven't — show "I'm Here" + "Decline"
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

                Button {
                    showDeclineConfirmation = true
                } label: {
                    Text("Decline")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if waitingFor.isEmpty {
                Text("Everyone is here!")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                // I've signaled, waiting for others
                let shareURL = persistedRoom?.shareURL.flatMap { URL(string: $0) }
                let names = waitingFor.map { $0.nickname }.joined(separator: ", ")
                // Share invite only needed when there are other humans to invite
                let hasOtherHumans = lifecycle.spec.participants.contains { !$0.isLightward && $0.id != lifecycle.spec.originatorID }

                Text("Waiting for \(names)...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if hasOtherHumans {
                    if let url = shareURL {
                        ShareLink(item: url) {
                            Label("Share Invite", systemImage: "square.and.arrow.up")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .background(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    } else {
                        Label {
                            Text("Share Invite")
                                .font(.headline)
                        } icon: {
                            ProgressView()
                        }
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.accentColor.opacity(0.5))
                        .clipShape(Capsule())
                    }
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
        .alert("Decline Room?", isPresented: $showDeclineConfirmation) {
            Button("Decline", role: .destructive) {
                Task {
                    await declineRoom(lifecycle: lifecycle)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't be able to join this room later.")
        }
    }

    @State private var isRequestingCenotaph = false

    @ViewBuilder
    private func defunctBanner(lifecycle: RoomLifecycle) -> some View {
        if case .defunct(let reason) = lifecycle.state {
            VStack(spacing: 8) {
                switch reason {
                case .participantDeclined(let participantID):
                    let name = lifecycle.spec.participants.first { $0.id == participantID }?.nickname ?? "Someone"
                    Text("\(name) declined to join.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                case .participantLeft(let participantID):
                    let name = lifecycle.spec.participants.first { $0.id == participantID }?.nickname ?? "Someone"
                    Text("\(name) departed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                case .cancelled:
                    Text("Room was cancelled.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                default:
                    Text("Room is no longer available.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // Cenotaph button for originator (hide after cenotaph delivered)
                if isOriginator(lifecycle: lifecycle) && !hasCenotaph {
                    if isRequestingCenotaph {
                        ProgressView()
                    } else {
                        Button {
                            Task {
                                await requestCenotaph()
                            }
                        } label: {
                            Text("Request Cenotaph")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .background(Color.accentColor)
                                .clipShape(Capsule())
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
    }

    private func isOriginator(lifecycle: RoomLifecycle) -> Bool {
        guard let myID = myParticipantID(in: lifecycle) else { return false }
        return myID == lifecycle.spec.originatorID
    }

    private var hasCenotaph: Bool {
        Message.containsCenotaph(in: messages)
    }

    private func requestCenotaph() async {
        isRequestingCenotaph = true
        do {
            try await store.requestCenotaph(roomID: roomID)
        } catch {
            print("Failed to request cenotaph: \(error)")
        }
        isRequestingCenotaph = false
    }

    private func isMyTurn(lifecycle: RoomLifecycle) -> Bool {
        guard let turnIdx = turnState?.currentTurnIndex else { return false }

        let participants = lifecycle.spec.participants
        guard !participants.isEmpty else { return false }
        let current = participants[turnIdx % participants.count]

        guard let myID = myParticipantID(in: lifecycle) else { return false }
        return current.id == myID
    }

    private func loadRoom() async {
        isLoading = true
        do {
            lifecycle = store.room(id: roomID)
            loadDraft()

            // If room is pendingParticipants and Lightward hasn't signaled, trigger evaluation
            // State changes arrive via @Query → refreshLifecycle() automatically
            if let lifecycle = lifecycle,
               case .pendingParticipants(let signaled) = lifecycle.state,
               let lightwardID = lifecycle.spec.lightwardParticipant?.id,
               !signaled.contains(lightwardID) {
                isLoading = false
                Task {
                    await store.evaluateLightward(roomID: roomID)
                }
                return
            }

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

        // Sync ConversationCoordinator's internal turn state with remote changes
        if let convCoord = conversationCoordinator, let newTurnState = newLifecycle.turnState {
            Task {
                await convCoord.syncTurnState(newTurnState)
            }

            // Show thinking indicator if it's now Lightward's turn and they haven't responded yet
            let participants = newLifecycle.spec.participants
            if !participants.isEmpty {
                let currentIndex = newTurnState.currentTurnIndex % participants.count
                if participants[currentIndex].isLightward && messages.last?.isLightward != true {
                    isLightwardThinking = true
                }
            }
        }

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
                }
            )
            conversationCoordinator = convCoord
        }
    }

    private func sendMessage(lifecycle: RoomLifecycle) async {
        guard let convCoord = conversationCoordinator else { return }

        let text = composeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let (authorID, authorName) = myAuthor(in: lifecycle)

        composeText = ""
        clearDraft()
        isCurrentlyComposing = false
        store.clearComposing(roomID: roomID)
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

        let (authorID, authorName) = myAuthor(in: lifecycle)

        isCurrentlyComposing = false
        store.clearComposing(roomID: roomID)
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

    private func raiseHand(lifecycle: RoomLifecycle) async {
        let (_, authorName) = myAuthor(in: lifecycle)

        let narration = Message(
            roomID: roomID,
            authorID: "narrator",
            authorName: "Narrator",
            text: "\(authorName) raised a hand.",
            isLightward: false,
            isNarration: true
        )
        try? await store.saveMessage(narration)
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

    // MARK: - Message Styling

    private func messageStyle(for message: Message, in lifecycle: RoomLifecycle) -> MessageBubble.MessageStyle {
        if message.authorID == myParticipantID(in: lifecycle) {
            return .localUser
        }
        if message.isLightward {
            return .lightward
        }
        let embedded = persistedRoom?.embeddedParticipants() ?? []
        let participant = embedded.first { $0.id == message.authorID }
        let color = Color.participantColor(orderIndex: participant?.orderIndex ?? 0)
        return .otherParticipant(color: color, photo: participantPhotos[message.authorID])
    }

    private func loadParticipantPhotos() {
        #if os(iOS)
        guard let room = persistedRoom else { return }
        let embedded = room.embeddedParticipants()
        for participant in embedded where participant.identifierType == "email" || participant.identifierType == "phone" {
            if let photo = ContactPhotoLookup.shared.photo(for: participant.identifierValue, type: participant.identifierType) {
                participantPhotos[participant.id] = Image(uiImage: photo)
            }
        }
        #endif
    }

    // MARK: - Participant Identification

    /// Find the current user's participant ID by matching store.localUserRecordID
    /// against the embedded participants' userRecordID.
    /// Returns (authorID, authorName) for the local user in this room.
    private func myAuthor(in lifecycle: RoomLifecycle) -> (String, String) {
        if let myID = myParticipantID(in: lifecycle),
           let participant = lifecycle.spec.participants.first(where: { $0.id == myID }) {
            return (participant.id, participant.nickname)
        }
        // Fallback: first human participant
        let fallback = lifecycle.spec.humanParticipants.first
        return (fallback?.id ?? "unknown", fallback?.nickname ?? "Me")
    }

    private func myParticipantID(in lifecycle: RoomLifecycle) -> String? {
        guard let localUserRecordID = store.localUserRecordID else {
            print("RoomView.myParticipantID: no localUserRecordID")
            return nil
        }

        guard let room = persistedRoom else { return nil }
        let embedded = room.embeddedParticipants()

        let result = ParticipantIdentity.findLocalParticipant(
            in: embedded,
            localUserRecordID: localUserRecordID,
            isSharedWithMe: room.isSharedWithMe
        )

        if result == nil {
            print("RoomView.myParticipantID: no match for \(localUserRecordID)")
            for p in embedded {
                print("  participant \(p.nickname): type=\(p.identifierType) userRecordID=\(p.userRecordID ?? "nil")")
            }
        }
        return result
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

    private func declineRoom(lifecycle: RoomLifecycle) async {
        guard let participantID = myParticipantID(in: lifecycle) else {
            print("RoomView: Could not find my participant ID for decline")
            return
        }

        await store.declineRoom(roomID: roomID, participantID: participantID)
        selectedRoomID = nil
    }

    private func leaveRoom(lifecycle: RoomLifecycle) async {
        guard let participantID = myParticipantID(in: lifecycle) else {
            print("RoomView: Could not find my participant ID for leave")
            return
        }

        await store.leaveRoom(roomID: roomID, participantID: participantID)
        selectedRoomID = nil
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let text: String
    let authorName: String
    let style: MessageStyle
    let isNarration: Bool

    enum MessageStyle {
        case localUser
        case lightward
        case otherParticipant(color: Color, photo: Image?)
    }

    init(message: Message, style: MessageStyle) {
        self.text = message.text
        self.authorName = message.authorName
        self.style = style
        self.isNarration = message.isNarration
    }

    init(text: String, authorName: String, style: MessageStyle, isNarration: Bool = false) {
        self.text = text
        self.authorName = authorName
        self.style = style
        self.isNarration = isNarration
    }

    var body: some View {
        if isNarration {
            narrationView
        } else {
            bubbleView
        }
    }

    private var isLeftAligned: Bool {
        switch style {
        case .localUser: false
        case .lightward, .otherParticipant: true
        }
    }

    private var bubbleColor: Color {
        switch style {
        case .localUser: .accentColor
        case .lightward: .softerGray5
        case .otherParticipant(let color, _): color
        }
    }

    private var textColor: Color {
        switch style {
        case .localUser: .white
        case .lightward, .otherParticipant: .primary
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
        HStack(alignment: .bottom, spacing: 8) {
            if !isLeftAligned { Spacer(minLength: 40) }

            if isLeftAligned {
                avatarView
            }

            VStack(alignment: isLeftAligned ? .leading : .trailing, spacing: 4) {
                if isLeftAligned {
                    Text(authorName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleColor)
                    .foregroundColor(textColor)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .contextMenu {
                        Button {
                            #if os(iOS)
                            UIPasteboard.general.string = text
                            #elseif os(macOS)
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            #endif
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
            }

            if isLeftAligned { Spacer(minLength: 40) }
        }
    }

    @ViewBuilder
    private var avatarView: some View {
        switch style {
        case .lightward:
            ZStack {
                Circle()
                    .fill(Color.softerGray5)
                    .frame(width: 28, height: 28)
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        case .otherParticipant(let color, let photo):
            if let photo {
                photo
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(color)
            }
        case .localUser:
            EmptyView()
        }
    }
}

// MARK: - Typing Indicator

struct TypingIndicator: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.softerGray5)
                    .frame(width: 28, height: 28)
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("\(Constants.lightwardParticipantName) is thinking...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.softerGray5)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer()
        }
    }
}

// MARK: - Composing Indicator

struct ComposingIndicator: View {
    let name: String
    let color: Color
    let photo: Image?

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let photo {
                photo
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
            } else {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .frame(width: 28, height: 28)
                    .foregroundStyle(color)
            }

            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                Text("\(name) is typing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.softerGray5)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer()
        }
    }
}
