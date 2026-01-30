import Foundation

enum TurnPhase: Sendable {
    case waitingForTurn          // Not this user's turn
    case myTurn                  // User can compose a message or yield
    case lightwardThinking       // Lightward is generating a response
    case lightwardStreaming      // Lightward response is streaming in
    case checkingHandRaise       // Probing whether Lightward wants to speak
}
