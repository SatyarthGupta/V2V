import SwiftUI

/// Animated status orb (PRD F5). Pulses while the conversation is live.
struct OrbView: View {
    let state: OrbState

    var body: some View {
        VStack(spacing: 16) {
            TimelineView(.animation(paused: !state.isAnimated)) { context in
                let time = context.date.timeIntervalSinceReferenceDate
                let pulse = state.isAnimated ? 1 + 0.07 * sin(time * state.pulseSpeed) : 1
                Circle()
                    .fill(state.color.gradient)
                    .frame(width: 160, height: 160)
                    .scaleEffect(pulse)
                    .shadow(color: state.color.opacity(0.5), radius: 24)
            }
            Text(state.label)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
        }
        .animation(.easeInOut(duration: 0.3), value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Assistant status")
        .accessibilityValue(state.label)
        .accessibilityIdentifier("orbStatus")
    }
}

private extension OrbState {
    var color: Color {
        switch self {
        case .idle: .gray
        case .connecting, .reconnecting: .orange
        case .listening: .blue
        case .userSpeaking: .green
        case .thinking: .purple
        case .aiSpeaking: .indigo
        case .paused: .yellow
        case .error: .red
        }
    }

    var isAnimated: Bool {
        switch self {
        case .idle, .error, .paused: false
        default: true
        }
    }

    /// Radians per second; speaking states pulse faster.
    var pulseSpeed: Double {
        switch self {
        case .userSpeaking, .aiSpeaking: 7
        default: 3
        }
    }
}

#Preview {
    VStack(spacing: 40) {
        OrbView(state: .listening)
        OrbView(state: .error)
    }
}
