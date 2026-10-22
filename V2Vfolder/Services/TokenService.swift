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
    /// Used to tell "the Mac's server is unreachable" from "the phone is offline" (D-021, PRD E10).
    private let network: NetworkMonitoring?

    init(config: AppConfig,
         network: NetworkMonitoring? = nil,
         transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.config = config
        self.network = network
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
            throw Self.map(error, internetReachable: network?.isInternetReachable())
        } catch is TimeoutError {
            throw network?.isInternetReachable() == false ? SessionError.noInternet : SessionError.tokenServerUnreachable
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

    /// Maps a transport failure to what the user should fix (PRD E10).
    ///
    /// A denied Local Network permission surfaces as `.notConnectedToInternet` even though the
    /// phone is online, so when the network path is known to be up, every connection failure means
    /// "can't reach the Mac". Without a monitor, fall back to the URL error code.
    static func map(_ error: URLError, internetReachable: Bool? = nil) -> SessionError {
        switch internetReachable {
        case false?:
            return .noInternet
        case true?:
            return .tokenServerUnreachable
        case nil:
            switch error.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return .noInternet
            default:
                return .tokenServerUnreachable
            }
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
