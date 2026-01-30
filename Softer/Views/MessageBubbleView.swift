import SwiftUI

struct MessageBubbleView: View {
    let message: Message
    let isLocal: Bool

    var body: some View {
        HStack {
            if isLocal { Spacer(minLength: 60) }

            VStack(alignment: isLocal ? .trailing : .leading, spacing: 4) {
                if !isLocal {
                    Text(message.authorName)
                        .font(.caption)
                        .foregroundStyle(message.isLightward ? .blue : .secondary)
                }

                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(backgroundColor)
                    .foregroundStyle(foregroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .modifier(LightwardGlassModifier(isLightward: message.isLightward))

                Text(message.createdAt, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if !isLocal { Spacer(minLength: 60) }
        }
    }

    private var backgroundColor: Color {
        if message.isLightward {
            return .blue.opacity(0.15)
        }
        return isLocal ? .blue : Color(.systemGray5)
    }

    private var foregroundColor: Color {
        if message.isLightward {
            return .primary
        }
        return isLocal ? .white : .primary
    }
}

/// Applies liquid glass effect to Lightward's message bubbles on iOS 26+.
/// On older devices, the standard background color provides the visual distinction.
private struct LightwardGlassModifier: ViewModifier {
    let isLightward: Bool

    func body(content: Content) -> some View {
        #if compiler(>=6.1)
        if #available(iOS 26.0, *), isLightward {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 18))
        } else {
            content
        }
        #else
        content
        #endif
    }
}
