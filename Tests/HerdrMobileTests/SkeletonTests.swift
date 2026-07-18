import Testing
@testable import HerdrMobile

// Initially-empty test target: it exists so the headless test run has something
// to execute and hosts the Transport seam tests from #3 onward.
@Suite struct SkeletonTests {
    @Test func appModuleIsImportable() {
        _ = HerdrMobileApp.self
    }
}
