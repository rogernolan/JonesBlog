import Testing
@testable import InstaBlog

struct AppRuntimeEnvironmentTests {
    @Test func developmentSignedBuildIsIdentifiedAsXcode() {
        #expect(
            AppRuntimeEnvironment.buildSource(
                isDevelopmentSigned: true,
                receiptName: "sandboxReceipt"
            ) == .xcode
        )
    }

    @Test func distributionBuildWithSandboxReceiptIsIdentifiedAsTestFlight() {
        #expect(
            AppRuntimeEnvironment.buildSource(
                isDevelopmentSigned: false,
                receiptName: "sandboxReceipt"
            ) == .testFlight
        )
    }

    @Test func productionBuildDoesNotRequireAReceipt() {
        #expect(
            AppRuntimeEnvironment.buildSource(
                isDevelopmentSigned: false,
                receiptName: nil
            ) == .production
        )
    }
}
