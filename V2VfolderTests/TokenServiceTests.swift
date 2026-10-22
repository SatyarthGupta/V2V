import Foundation
import Testing
@testable import V2Vfolder

struct TokenServiceTests {
    private let config = AppConfig(host: "Test-Mac.local", port: 8787, appSharedSecret: "secret-123")

    private func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "http://Test-Mac.local:8787/session")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private let okBody = Data("""
    {"value":"ek_abc","expires_at":1900000000,"personaId":"coach","voice":"coral","instructions":"Be a coach."}
    """.utf8)

    @Test("Sends POST /session with the secret header and personaId")
    func buildsRequest() async throws {
        let captured = RequestBox()
        let service = TokenService(config: config) { request in
            captured.request = request
            return (okBody, response(status: 200))
        }

        _ = try await service.fetchToken(persona: .coach)

        let request = try #require(captured.request)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "http://Test-Mac.local:8787/session")
        #expect(request.value(forHTTPHeaderField: "x-app-secret") == "secret-123")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["personaId": "coach"])
    }

    @Test("Decodes the token and persona config")
    func decodesToken() async throws {
        let service = TokenService(config: config) { _ in (okBody, response(status: 200)) }
        let token = try await service.fetchToken(persona: .coach)
        #expect(token == EphemeralToken(value: "ek_abc", expiresAt: Date(timeIntervalSince1970: 1_900_000_000),
                                        personaID: "coach", voice: "coral", instructions: "Be a coach."))
    }

    @Test("U-39: non-2xx → tokenRejected(status)", arguments: [401, 429, 502, 504])
    func rejectedStatus(status: Int) async {
        let service = TokenService(config: config) { _ in (Data(#"{"error":"x"}"#.utf8), response(status: status)) }
        await #expect(throws: SessionError.tokenRejected(status: status)) {
            try await service.fetchToken(persona: .quick)
        }
    }

    @Test("U-39: connection failures → tokenServerUnreachable", arguments: [
        URLError.Code.cannotFindHost, .cannotConnectToHost, .timedOut, .networkConnectionLost, .dnsLookupFailed,
    ])
    func unreachable(code: URLError.Code) async {
        let service = TokenService(config: config) { _ in throw URLError(code) }
        await #expect(throws: SessionError.tokenServerUnreachable) {
            try await service.fetchToken(persona: .quick)
        }
    }

    @Test("Offline → noInternet")
    func offline() async {
        let service = TokenService(config: config) { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: SessionError.noInternet) {
            try await service.fetchToken(persona: .quick)
        }
    }

    @Test("Malformed 200 body → tokenRejected, not a crash")
    func malformedBody() async {
        let service = TokenService(config: config) { _ in (Data("not json".utf8), response(status: 200)) }
        await #expect(throws: SessionError.tokenRejected(status: 200)) {
            try await service.fetchToken(persona: .quick)
        }
    }

    @Test("Missing server URL → tokenServerUnreachable without a request")
    func missingURL() async {
        let broken = AppConfig(host: "", port: 8787, appSharedSecret: "s")
        let service = TokenService(config: broken) { _ in
            Issue.record("transport must not be called")
            throw URLError(.badURL)
        }
        await #expect(throws: SessionError.self) {
            try await service.fetchToken(persona: .quick)
        }
    }
}

private final class RequestBox: @unchecked Sendable {
    var request: URLRequest?
}
