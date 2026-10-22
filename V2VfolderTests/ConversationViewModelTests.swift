import Foundation
import Testing
@testable import V2Vfolder

@MainActor
struct ConversationViewModelTests {
    private func makeViewModel(mic: MicPermission = .granted, tokenError: Error? = nil) -> (ConversationViewModel, UserDefaults) {
        let defaults = UserDefaults(suiteName: "ConversationViewModelTests-\(UUID().uuidString)")!
        let tokens = FakeTokenService(error: tokenError)
        let controller = VoiceSessionController(dependencies: VoiceSessionDependencies(
            permissions: FakePermissionService(status: mic),
            tokens: tokens,
            audioSession: FakeAudioSessionManager(),
            makeRealtimeClient: { FakeRealtimeClient() },
            makeAudioEngine: { FakeAudioEngine() }))
        return (ConversationViewModel(controller: controller, defaults: defaults), defaults)
    }

    @Test("U-50: every SessionState maps to the right orb state", arguments: [
        (SessionState.idle, OrbState.idle),
        (.checkingPermission, .connecting),
        (.connecting, .connecting),
        (.listening, .listening),
        (.userSpeaking, .userSpeaking),
        (.thinking, .thinking),
        (.aiSpeaking, .aiSpeaking),
        (.paused(.interruption(canAutoResume: true)), .paused),
        (.reconnecting(attempt: 2), .reconnecting),
        (.permissionDenied, .error),
        (.failed(.reconnectExhausted), .error),
    ])
    func orbMapping(state: SessionState, expected: OrbState) {
        #expect(OrbState(state) == expected)
        #expect(!OrbState(state).label.isEmpty)
    }

    @Test("U-52: denied mic → permission card, no error banner")
    func permissionDenied() async {
        let (viewModel, _) = makeViewModel(mic: .denied)
        await viewModel.startTapped()
        #expect(viewModel.showPermissionDenied)
        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.canRetry)
    }

    @Test("U-51: failure → actionable message + Retry")
    func failureOffersRetry() async {
        let (viewModel, _) = makeViewModel(tokenError: SessionError.tokenServerUnreachable)
        await viewModel.startTapped()
        #expect(viewModel.canRetry)
        #expect(viewModel.errorMessage?.contains("token server") == true)
        #expect(viewModel.errorMessage?.contains("Local Network") == true)
    }

    @Test("Error messages are distinct for the cases a demo hits", arguments: [
        SessionError.tokenServerUnreachable, .noInternet, .tokenRejected(status: 401),
        .tokenRejected(status: 429), .socketFailed("x"), .reconnectExhausted,
    ])
    func messagesExist(error: SessionError) {
        #expect(ConversationViewModel.message(for: error).count > 10)
    }

    @Test("Persona defaults to Quick and persists across launches")
    func personaPersistence() {
        let (viewModel, defaults) = makeViewModel()
        #expect(viewModel.persona == .quick)
        viewModel.persona = .storyteller

        let controller = VoiceSessionController(dependencies: VoiceSessionDependencies(
            permissions: FakePermissionService(), tokens: FakeTokenService(), audioSession: FakeAudioSessionManager(),
            makeRealtimeClient: { FakeRealtimeClient() }, makeAudioEngine: { FakeAudioEngine() }))
        #expect(ConversationViewModel(controller: controller, defaults: defaults).persona == .storyteller)
    }
}
