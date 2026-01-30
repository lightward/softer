import SwiftUI

struct StreamingTextView: View {
    let text: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(Constants.lightwardParticipantName)
                    .font(.caption)
                    .foregroundStyle(.blue)

                HStack(alignment: .bottom, spacing: 4) {
                    Text(text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.blue.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .modifier(StreamingGlassModifier())

                    TypingIndicator()
                }
            }

            Spacer(minLength: 60)
        }
    }
}

private struct TypingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(.blue.opacity(0.5))
                    .frame(width: 5, height: 5)
                    .offset(y: animating ? -3 : 0)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever()
                            .delay(Double(index) * 0.15),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
    }
}

private struct StreamingGlassModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if compiler(>=6.1)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 18))
        } else {
            content
        }
        #else
        content
        #endif
    }
}
