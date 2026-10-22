import Testing
@testable import V2Vfolder

/// Smoke test: proves the unit test bundle is hosted by the app and can see its internals.
struct AppHostingTests {
    @Test func appModuleIsVisibleToTests() {
        _ = AppDependencies.live()
    }
}
