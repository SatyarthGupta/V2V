import Foundation

/// Runtime configuration for reaching the local token server (D-019, D-021).
/// Values come from the git-ignored `Secrets.swift`.
nonisolated struct AppConfig: Sendable, Equatable {
    /// Base URL of the token server, e.g. `http://Satyarths-MacBook-Air.local:8787`.
    /// `nil` only if the host in Secrets.swift is malformed; TokenService reports that as unreachable.
    let tokenServerURL: URL?
    let appSharedSecret: String

    init(host: String, port: Int, appSharedSecret: String) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        self.tokenServerURL = host.isEmpty ? nil : components.url
        self.appSharedSecret = appSharedSecret
    }

    static let current = AppConfig(
        host: Secrets.tokenServerHost,
        port: Secrets.tokenServerPort,
        appSharedSecret: Secrets.appSharedSecret
    )
}
