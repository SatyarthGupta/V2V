import SwiftUI
import UIKit

/// The main screen: orb, transcript, and Start/End (PRD F1–F6, E3).
struct ConversationView: View {
    @State var viewModel: ConversationViewModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                OrbView(state: viewModel.orb)
                    .padding(.top, 8)

                statusCard

                TranscriptView(turns: viewModel.turns)

                controls
            }
            .padding()
            .navigationTitle("V2V")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { personaMenu }
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        if viewModel.showPermissionDenied {
            PermissionDeniedCard(onOpenSettings: openSettings)
        } else if let message = viewModel.errorMessage {
            ErrorBanner(message: message, onRetry: retryAction)
        }
    }

    /// Retry is offered only for fatal failures.
    private var retryAction: (() -> Void)? {
        guard viewModel.canRetry else { return nil }
        return { Task { await viewModel.startTapped() } }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            if viewModel.isSessionActive {
                Button(viewModel.isMuted ? "Unmute" : "Mute",
                       systemImage: viewModel.isMuted ? "mic.slash.fill" : "mic.fill") {
                    viewModel.toggleMute()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button("End", systemImage: "stop.fill", role: .destructive) {
                    Task { await viewModel.endTapped() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("endButton")
            } else {
                Button("Start", systemImage: "waveform") {
                    Task { await viewModel.startTapped() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("startButton")
            }
        }
    }

    private var personaMenu: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Persona", selection: $viewModel.persona) {
                    ForEach(Persona.allCases) { persona in
                        Label(persona.displayName, systemImage: "person.wave.2")
                            .tag(persona)
                    }
                }
            } label: {
                Label(viewModel.persona.displayName, systemImage: "person.wave.2")
            }
            // Voice can't change mid-session (D-020).
            .disabled(viewModel.isSessionActive)
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
}

/// Explains a denied microphone and links to Settings (PRD E3).
private struct PermissionDeniedCard: View {
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Label("Microphone access is off", systemImage: "mic.slash")
                .font(.headline)
            Text("V2V needs the microphone so you can talk with the assistant. Turn it on in Settings, then tap Start.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Settings", action: onOpenSettings)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("openSettingsButton")
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 16))
    }
}

/// Error with an optional Retry (PRD E7, E10).
private struct ErrorBanner: View {
    let message: String
    let onRetry: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
            if let onRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("retryButton")
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.12), in: .rect(cornerRadius: 16))
        .accessibilityIdentifier("errorBanner")
    }
}
