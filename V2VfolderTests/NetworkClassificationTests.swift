import Foundation
import Testing
@testable import V2Vfolder

/// PRD E10 / D-021: tell "can't reach the Mac" apart from "phone is offline".
struct NetworkClassificationTests {
    private let config = AppConfig(host: "Test-Mac.local", port: 8787, appSharedSecret: "s")

    private func service(reachable: Bool, failing code: URLError.Code) -> TokenService {
        TokenService(config: config, network: FakeNetworkMonitor(reachable: reachable)) { _ in throw URLError(code) }
    }

    @Test("U-42: Local Network denied shows up as 'not connected' while online → tokenServerUnreachable")
    func localNetworkDeniedWhileOnline() async {
        await #expect(throws: SessionError.tokenServerUnreachable) {
            try await service(reachable: true, failing: .notConnectedToInternet).fetchToken(persona: .quick)
        }
    }

    @Test("U-42: server not running / Mac asleep while online → tokenServerUnreachable",
          arguments: [URLError.Code.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost])
    func serverDownWhileOnline(code: URLError.Code) async {
        await #expect(throws: SessionError.tokenServerUnreachable) {
            try await service(reachable: true, failing: code).fetchToken(persona: .quick)
        }
    }

    @Test("U-43: phone offline → noInternet, whatever the URL error says",
          arguments: [URLError.Code.notConnectedToInternet, .cannotFindHost, .timedOut])
    func offline(code: URLError.Code) async {
        await #expect(throws: SessionError.noInternet) {
            try await service(reachable: false, failing: code).fetchToken(persona: .quick)
        }
    }

    @Test("The two cases show different, actionable messages")
    func distinctMessages() {
        let server = ConversationViewModel.message(for: .tokenServerUnreachable)
        let offline = ConversationViewModel.message(for: .noInternet)
        #expect(server != offline)
        #expect(server.contains("Local Network"))
        #expect(server.contains("npm run dev"))
        #expect(offline.contains("internet"))
    }
}
