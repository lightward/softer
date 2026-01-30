import SwiftUI

struct TurnIndicatorView: View {
    let phase: TurnPhase
    let currentTurnName: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(indicatorColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var statusText: String {
        switch phase {
        case .waitingForTurn:
            return "\(currentTurnName)'s turn"
        case .myTurn:
            return "Your turn"
        case .lightwardThinking:
            return "Lightward is thinking..."
        case .lightwardStreaming:
            return "Lightward is speaking..."
        case .checkingHandRaise:
            return "Checking if Lightward wants to speak..."
        }
    }

    private var indicatorColor: Color {
        switch phase {
        case .waitingForTurn:
            return .gray
        case .myTurn:
            return .green
        case .lightwardThinking, .lightwardStreaming:
            return .blue
        case .checkingHandRaise:
            return .orange
        }
    }
}
