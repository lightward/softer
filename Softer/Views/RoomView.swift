import SwiftUI

struct RoomView: View {
    let roomID: String
    let cloudKitManager: CloudKitManager
    @State private var viewModel: RoomViewModel?

    var body: some View {
        Group {
            if let viewModel = viewModel {
                VStack(spacing: 0) {
                    TurnIndicatorView(
                        phase: viewModel.currentPhase,
                        currentTurnName: viewModel.room?.currentTurnParticipantID ?? ""
                    )

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(viewModel.messages) { message in
                                    MessageBubbleView(
                                        message: message,
                                        isLocal: message.authorID == viewModel.localParticipantID
                                    )
                                    .id(message.id)
                                }

                                if viewModel.currentPhase == .lightwardStreaming && !viewModel.streamingText.isEmpty {
                                    StreamingTextView(text: viewModel.streamingText)
                                        .id("streaming")
                                }
                            }
                            .padding()
                        }
                        .onChange(of: viewModel.messages.count) {
                            if let lastID = viewModel.messages.last?.id {
                                withAnimation {
                                    proxy.scrollTo(lastID, anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: viewModel.streamingText) {
                            withAnimation {
                                proxy.scrollTo("streaming", anchor: .bottom)
                            }
                        }
                    }

                    ComposeView(
                        text: Bindable(viewModel).composeText,
                        isEnabled: viewModel.isMyTurn,
                        onSend: {
                            Task { await viewModel.sendMessage() }
                        },
                        onYield: {
                            Task { await viewModel.yieldTurn() }
                        }
                    )
                }
                .navigationTitle(viewModel.room?.name ?? "Room")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink {
                            ParticipantListView(
                                roomID: roomID,
                                cloudKitManager: cloudKitManager
                            )
                        } label: {
                            Image(systemName: "person.2")
                        }
                    }
                }
                .onAppear {
                    viewModel.onAppear()
                }
            } else {
                ProgressView()
            }
        }
        .onAppear {
            if viewModel == nil {
                viewModel = RoomViewModel(roomID: roomID, cloudKitManager: cloudKitManager)
            }
        }
    }
}
