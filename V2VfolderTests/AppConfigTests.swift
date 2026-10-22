import Foundation
import Testing
@testable import V2Vfolder

struct AppConfigTests {
    @Test func buildsHTTPURLFromLocalHostAndPort() {
        let config = AppConfig(host: "My-Mac.local", port: 8787, appSharedSecret: "s")
        #expect(config.tokenServerURL?.absoluteString == "http://My-Mac.local:8787")
    }

    @Test func currentConfigPointsAtALocalHostWithASecret() {
        let config = AppConfig.current
        #expect(config.tokenServerURL?.host()?.hasSuffix(".local") == true)
        #expect(config.tokenServerURL?.port == 8787)
        #expect(!config.appSharedSecret.isEmpty)
        #expect(config.appSharedSecret != "PASTE_APP_SHARED_SECRET_HERE")
    }
}
