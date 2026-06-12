import Foundation

/// A message in a room conversation.
struct Message: Identifiable, Sendable, Codable, Equatable {
    let id: String
    let roomID: String
    let authorID: String
    let authorName: String
    let text: String
    let createdAt: Date
    let isLightward: Bool
    let isNarration: Bool  // System/narrator messages (e.g., "Lightward chose to keep listening")

    init(
        id: String = UUID().uuidString,
        roomID: String,
        authorID: String,
        authorName: String,
        text: String,
        createdAt: Date = Date(),
        isLightward: Bool = false,
        isNarration: Bool = false
    ) {
        self.id = id
        self.roomID = roomID
        self.authorID = authorID
        self.authorName = authorName
        self.text = text
        self.createdAt = createdAt
        self.isLightward = isLightward
        self.isNarration = isNarration
    }

    /// Whether this message consumes a turn slot: speech (human or Lightward)
    /// or a yield. Other narrations — intros, arrivals, hand raises,
    /// departures — are commentary; they don't move the wheel.
    var isTurnConsuming: Bool {
        !isNarration || id.hasSuffix(":yield")
    }

    /// The current turn index of a conversation: a fold over the ledger.
    /// Derived, never stored — the message log is the only source of truth,
    /// so devices that share a ledger agree on the turn with no merge policy
    /// and nothing to repair.
    static func turnIndex(in messages: [Message]) -> Int {
        messages.filter(\.isTurnConsuming).count
    }

    /// Deterministic IDs for machine-generated messages, keyed by causal position.
    ///
    /// Two devices racing to generate the same event (a Lightward response, a
    /// narration) mint the same ID, so the union-by-ID message merge collapses
    /// the duplicates to a single survivor — firings are idempotent and the
    /// merge itself is the brake. Human speech keeps random UUIDs: duplicate
    /// human messages are visible and attributed, but machine firings must
    /// collapse.
    enum StableID {
        /// Lightward's speech occupying a turn slot (normal response, horizon
        /// speech, or DEPART farewell — exactly one outcome per slot survives).
        static func lightwardSpeech(roomID: String, turnIndex: Int) -> String {
            "\(roomID):turn:\(turnIndex):lightward"
        }

        /// "X is listening." — the holder of a turn slot yielded it.
        static func yieldNarration(roomID: String, turnIndex: Int) -> String {
            "\(roomID):turn:\(turnIndex):yield"
        }

        /// "X, it's your turn." — first-round orientation for a turn slot.
        static func turnIntro(roomID: String, turnIndex: Int) -> String {
            "\(roomID):turn:\(turnIndex):intro"
        }

        /// "X raised a hand." — at most one per participant per turn slot.
        static func handRaise(roomID: String, participantID: String, turnIndex: Int) -> String {
            "\(roomID):turn:\(turnIndex):hand:\(participantID)"
        }

        /// "X opened a room with $N." — one per room.
        static func opening(roomID: String) -> String {
            "\(roomID):opening"
        }

        /// "X arrived." — one per participant per room.
        static func arrival(roomID: String, participantID: String) -> String {
            "\(roomID):arrival:\(participantID)"
        }

        /// "X declined." — one per participant per room.
        static func declined(roomID: String, participantID: String) -> String {
            "\(roomID):declined:\(participantID)"
        }

        /// "X departed." — one per participant per room (departure is terminal).
        static func departure(roomID: String, participantID: String) -> String {
            "\(roomID):departed:\(participantID)"
        }

        /// The ceremonial closing — one per room.
        static func cenotaph(roomID: String) -> String {
            "\(roomID):cenotaph"
        }
    }

    /// Whether a message list contains a cenotaph (a Lightward-written ceremonial closing).
    /// Cenotaphs are narration messages that don't match standard departure/decline patterns.
    static func containsCenotaph(in messages: [Message]) -> Bool {
        guard let lastNarration = messages.last(where: { $0.isNarration }) else { return false }
        let text = lastNarration.text
        return !text.hasSuffix("departed.") &&
               !text.hasSuffix("declined to join.") &&
               text != "Room was cancelled." &&
               text != "Room is no longer available."
    }
}
