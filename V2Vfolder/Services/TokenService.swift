import Foundation

/// Short-lived Realtime client secret plus the persona config the server resolved (D-013, D-020).
nonisolated struct EphemeralToken: Equatable, Sendable {
    let value: String
    let expiresAt: Date
    let personaID: String
    let voice: String
    let instructions: String
}

nonisolated protocol TokenProviding: Sendable {
    func fetchToken(persona: Persona) async throws -> EphemeralToken
}

/// Fetches tokens from the local token server: `POST {base}/session` (docs/LLD.md §9).
nonisolated struct TokenService: TokenProviding {
    /// Performs the HTTP request. Injected so tests don't need a server.
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let timeout: Duration = .seconds(8)

    private let config: AppConfig
    private let transport: Transport

    init(config: AppConfig, transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.config = config
        self.transport = transport
    }

    func fetchToken(persona: Persona) async throws -> EphemeralToken {
        guard let baseURL = config.tokenServerURL else {
            throw SessionError.tokenServerUnreachable
        }

        var request = URLRequest(url: baseURL.appending(path: "session"))
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue(config.appSharedSecret, forHTTPHeaderField: "x-app-secret")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["personaId": persona.rawValue])

        let (data, response): (Data, URLResponse)
        do {
            let transport = transport
            let finalRequest = request
            (data, response) = try await withTimeout(Self.timeout) { try await transport(finalRequest) }
        } catch let error as URLError {
            throw Self.map(error)
        } catch is TimeoutError {
            throw SessionError.tokenServerUnreachable
        }

        guard let http = response as? HTTPURLResponse else {
            throw SessionError.tokenServerUnreachable
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SessionError.tokenRejected(status: http.statusCode)
        }

        do {
            let body = try JSONDecoder().decode(ResponseBody.self, from: data)
            return EphemeralToken(
                value: body.value,
                expiresAt: Date(timeIntervalSince1970: TimeInterval(body.expires_at)),
                personaID: body.personaId,
                voice: body.voice,
                instructions: body.instructions
            )
        } catch {
            throw SessionError.tokenRejected(status: http.statusCode)
        }
    }

    /// First-pass mapping. v2v-h28.10 refines `.tokenServerUnreachable` vs `.noInternet`
    /// using NetworkMonitor, since a Local Network denial can also surface as "not connected".
    static func map(_ error: URLError) -> SessionError {
        switch error.code {
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            .noInternet
        default:
            .tokenServerUnreachable
        }
    }

    private struct ResponseBody: Decodable {
        let value: String
        let expires_at: Int
        let personaId: String
        let voice: String
        let instructions: String
    }
}
