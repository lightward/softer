import SwiftUI

struct HandRaiseButton: View {
    let isRaised: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isRaised ? "hand.raised.fill" : "hand.raised")
                .font(.title3)
                .foregroundStyle(isRaised ? .yellow : .secondary)
                .padding(8)
                .background(
                    Circle()
                        .fill(isRaised ? .yellow.opacity(0.2) : .clear)
                )
        }
        .accessibilityLabel(isRaised ? "Hand raised" : "Raise hand")
    }
}
