import CloudKit
import Foundation
import SQLiteData
import Testing
@testable import InstaBlog

@Suite("App Telemetry")
struct AppTelemetryTests {
    @Test("Entry points log without crashing")
    func entryPointsLogWithoutCrashing() {
        struct SampleError: Error, LocalizedError {
            var errorDescription: String? { "Sample localized error" }
        }
        struct CustomError: Error {}

        AppTelemetry.log("Info test message", category: "testing", level: .info)
        AppTelemetry.log("Warning test message", category: "testing", level: .warning)
        AppTelemetry.log("Error test message", category: "testing", level: .error)
        AppTelemetry.record(
            "Event occurred",
            category: "testing",
            level: .warning,
            error: SampleError(),
            data: ["user_id": "test_user", "action": "run_test"]
        )
        AppTelemetry.capture(
            CustomError(),
            message: "Failed operation",
            category: "testing",
            data: ["context": "unit-test"]
        )
    }

    @Test("Attributes add error details to the supplied data")
    func attributesAddsErrorDetails() {
        let error = NSError(
            domain: "TestDomain",
            code: 1234,
            userInfo: [NSLocalizedDescriptionKey: "Something broke"]
        )

        let attributes = AppTelemetryFormatting.attributes(
            data: ["user_id": "u1"],
            error: error
        )

        #expect(attributes["user_id"] as? String == "u1")
        #expect(attributes["error_domain"] as? String == "TestDomain")
        #expect(attributes["error_code"] as? Int == 1234)
        #expect(attributes["error_description"] as? String == "Something broke")
    }

    @Test("Attributes pass the data through unchanged when there is no error")
    func attributesPassesDataThroughWithoutError() {
        let attributes = AppTelemetryFormatting.attributes(
            data: ["action": "run"],
            error: nil
        )

        #expect(attributes.count == 1)
        #expect(attributes["action"] as? String == "run")
    }

    @Test("CloudKit details include sorted partial errors and the underlying error")
    func cloudKitErrorDetailsIncludesPartialAndUnderlyingErrors() {
        let recordAError = NSError(
            domain: CKError.errorDomain,
            code: CKError.serverRecordChanged.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Record was changed"]
        )
        let recordBError = NSError(
            domain: CKError.errorDomain,
            code: CKError.unknownItem.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Item not found"]
        )
        let underlyingError = NSError(
            domain: NSPOSIXErrorDomain,
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "No such file"]
        )
        let error = NSError(
            domain: CKError.errorDomain,
            code: CKError.partialFailure.rawValue,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    "recordB" as NSString: recordBError,
                    "recordA" as NSString: recordAError,
                ],
                NSUnderlyingErrorKey: underlyingError,
            ]
        )

        let details = AppTelemetryFormatting.cloudKitErrorDetails(error)

        #expect(details == [
            "recordA: \(recordAError.domain) code \(recordAError.code) \(recordAError.localizedDescription)",
            "recordB: \(recordBError.domain) code \(recordBError.code) \(recordBError.localizedDescription)",
            "underlying: \(underlyingError.domain) code \(underlyingError.code) \(underlyingError.localizedDescription)",
        ].joined(separator: "; "))
    }

    @Test("CloudKit details are nil when the error carries no partial or underlying errors")
    func cloudKitErrorDetailsIsNilWithoutExtras() {
        let error = NSError(
            domain: CKError.errorDomain,
            code: CKError.networkUnavailable.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "The network is unavailable."]
        )

        #expect(AppTelemetryFormatting.cloudKitErrorDetails(error) == nil)
    }

    @Test("CloudKit details ignore errors outside the CloudKit domain")
    func cloudKitErrorDetailsIgnoresOtherDomains() {
        let error = NSError(domain: "TestDomain", code: 1, userInfo: [:])

        #expect(AppTelemetryFormatting.cloudKitErrorDetails(error) == nil)
    }

    @Test("CloudKit schema failures are classified and expose affected records")
    func cloudKitSchemaFailureClassification() {
        let recordName = "\(UUID().uuidString):blogItems"
        let schemaError = NSError(
            domain: CKError.errorDomain,
            code: CKError.invalidArguments.rawValue,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Cannot create or modify field 'altitude' in record 'blogItems' in production schema"
            ]
        )
        let error = NSError(
            domain: CKError.errorDomain,
            code: CKError.partialFailure.rawValue,
            userInfo: [CKPartialErrorsByItemIDKey: [recordName as NSString: schemaError]]
        )

        #expect(AppTelemetryFormatting.cloudKitFailureKind(error) == .schemaValidation)
        #expect(AppTelemetryFormatting.cloudKitRecordNames(in: error) == [recordName])
    }

    @Test("CloudKit validation failures requeue matching local records")
    func cloudKitValidationFailureRequeuesMatchingLocalRecords() async throws {
        let database = try AppDatabase.makeInMemory()
        let workspace = try BlogBootstrapService(database: database).bootstrap()
        let itemID = UUID()
        let oldDate = Date(timeIntervalSince1970: 1_800_000_000)
        let recoveryDate = oldDate.addingTimeInterval(60)

        try await database.write { db in
            try BlogItem.insert {
                BlogItem.Draft(
                    id: itemID,
                    blogID: workspace.blog.id,
                    authorID: workspace.blogger.id,
                    blogText: "Needs recovery",
                    createdAt: oldDate,
                    updatedAt: oldDate,
                    itemDate: oldDate,
                    localDay: "2027-01-15"
                )
            }.execute(db)
        }

        let recordName = "\(itemID.uuidString):blogItems"
        let requeued = try await CloudSyncRecoveryService.requeue(
            recordNames: [recordName],
            in: database,
            now: recoveryDate
        )
        let updatedAt = try await database.read { db in
            try BlogItem.find(itemID).fetchOne(db)?.updatedAt
        }

        #expect(requeued == [recordName])
        #expect(updatedAt == recoveryDate)

        #expect(try await CloudSyncRecoveryService.requeue(
            recordNames: [recordName],
            in: database,
            now: recoveryDate.addingTimeInterval(1)
        ).isEmpty)
        #expect(try await CloudSyncRecoveryService.requeue(
            recordNames: ["\(UUID().uuidString):publishEvents"],
            in: database,
            now: recoveryDate.addingTimeInterval(1)
        ).isEmpty)
    }

    @Test("Rendered message formats the error prefix and description")
    func renderedMessageFormatsErrorAttributes() {
        let attributes: [String: Any] = [
            "error_domain": "TestDomain",
            "error_code": 7,
            "error_description": "It failed",
        ]

        let message = AppTelemetryFormatting.renderedMessage(
            "Operation failed",
            attributes: attributes
        )

        #expect(message == "Operation failed [TestDomain code 7] It failed")
    }

    @Test("Rendered message appends CloudKit error details")
    func renderedMessageAppendsCloudKitDetails() {
        let attributes: [String: Any] = [
            "error_domain": "CloudKit",
            "error_code": 2,
            "error_description": "partial failure",
            "error_details": "recordA: CloudKit code 14 Record was changed",
        ]

        let message = AppTelemetryFormatting.renderedMessage(
            "Sync failed",
            attributes: attributes
        )

        #expect(message == "Sync failed [CloudKit code 2] partial failure Details: recordA: CloudKit code 14 Record was changed")
    }

    @Test("Rendered message is unchanged without error attributes")
    func renderedMessageIsUnchangedWithoutErrorAttributes() {
        #expect(AppTelemetryFormatting.renderedMessage("Just a message", attributes: [:]) == "Just a message")
    }
}
