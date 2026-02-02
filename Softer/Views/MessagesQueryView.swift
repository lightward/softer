import SwiftUI
import SwiftData

/// A view that observes messages for a specific room using SwiftData's @Query.
/// This wrapper enables automatic message updates without polling.
struct MessagesQueryView: View {
    let roomID: String
    let lifecycle: RoomLifecycle
    @Binding var streamingText: String
    @Binding var isLightwardThinking: Bool

    @Query private var persistedMessages: [PersistedMessage]

    init(
        roomID: String,
        lifecycle: RoomLifecycle,
        streamingText: Binding<String>,
        isLightwardThinking: Binding<Bool>
    ) {
        self.roomID = roomID
        self.lifecycle = lifecycle
        self._streamingText = streamingText
        self._isLightwardThinking = isLightwardThinking
        // Filter messages by roomID and sort by creation date
        _persistedMessages = Query(
            filter: #Predicate<PersistedMessage> { message in
                message.roomID == roomID
            },
            sort: \PersistedMessage.createdAt
        )
    }

    private var messages: [Message] {
        persistedMessages.map { $0.toMessage() }
    }

    /// Clear streaming text when the matching message appears in the list
    private func clearStreamingIfSaved() {
        if !streamingText.isEmpty {
            if messages.contains(where: { $0.text == streamingText }) {
                streamingText = ""
            }
        }
    }

    var body: some View {
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
            }
            .onChange(of: streamingText) {
                if !streamingText.isEmpty {
                    withAnimation {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: persistedMessages.count) {
                clearStreamingIfSaved()
            }
        }
    }
}
