import Testing

@testable import InstaBlog

@Suite("App runtime environment")
struct AppRuntimeEnvironmentTests {
    @Test func debugProductionBuildRequiresWarning() {
        let environment = AppRuntimeEnvironment(
            cloudKitEnvironment: .production,
            isDebugBuild: true
        )

        #expect(environment.requiresProductionDataWarning)
    }

    @Test func ordinaryDebugBuildDoesNotRequireWarning() {
        let environment = AppRuntimeEnvironment(
            cloudKitEnvironment: .development,
            isDebugBuild: true
        )

        #expect(!environment.requiresProductionDataWarning)
    }

    @Test func releaseBuildDoesNotRequireDebugWarning() {
        let environment = AppRuntimeEnvironment(
            cloudKitEnvironment: .production,
            isDebugBuild: false
        )

        #expect(!environment.requiresProductionDataWarning)
    }

    @Test func buildInformationIncludesVersionBuildAndVariant() {
        let information = AppBuildInformation(
            version: "1.2",
            build: "47",
            variant: .migrationExport
        )

        #expect(information.displayText == "Version 1.2 (47) · Migration Export")
    }

    @Test func releaseBuildInformationOmitsVariant() {
        let information = AppBuildInformation(
            version: "1.2",
            build: "47",
            variant: .release
        )

        #expect(information.displayText == "Version 1.2 (47)")
    }
}
