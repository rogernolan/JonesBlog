import Foundation
import Testing
import UIKit

@testable import InstaBlog

@Suite("Remote notification sync results")
@MainActor
struct RemoteNotificationSyncHandlerTests {
    private enum TestError: Error {
        case failed
    }

    @Test("successful media sync reports new data")
    func successfulMediaSyncReportsNewData() async {
        let blogID = Blog.ID()
        var synchronizedBlogID: Blog.ID?

        let result = await RemoteNotificationSyncHandler.run(
            synchronizeCloudState: {},
            loadActiveBlogID: { blogID },
            synchronizeMedia: { synchronizedBlogID = $0 },
            logFailure: { _ in }
        )

        #expect(result == .newData)
        #expect(synchronizedBlogID == blogID)
    }

    @Test("missing active blog completes without pretending media changed")
    func missingActiveBlogReportsNoData() async {
        var didSynchronizeMedia = false

        let result = await RemoteNotificationSyncHandler.run(
            synchronizeCloudState: {},
            loadActiveBlogID: { nil },
            synchronizeMedia: { _ in didSynchronizeMedia = true },
            logFailure: { _ in }
        )

        #expect(result == .noData)
        #expect(!didSynchronizeMedia)
    }

    @Test("active-blog lookup failure is logged and reported")
    func activeBlogLookupFailureIsReported() async {
        var loggedMessage: String?

        let result = await RemoteNotificationSyncHandler.run(
            synchronizeCloudState: {},
            loadActiveBlogID: { throw TestError.failed },
            synchronizeMedia: { _ in },
            logFailure: { loggedMessage = $0 }
        )

        #expect(result == .failed)
        #expect(loggedMessage?.contains("active blog") == true)
        #expect(loggedMessage?.contains("failed") == true)
    }

    @Test("media sync failure is logged and reported")
    func mediaSyncFailureIsReported() async {
        var loggedMessage: String?

        let result = await RemoteNotificationSyncHandler.run(
            synchronizeCloudState: {},
            loadActiveBlogID: { Blog.ID() },
            synchronizeMedia: { _ in throw TestError.failed },
            logFailure: { loggedMessage = $0 }
        )

        #expect(result == .failed)
        #expect(loggedMessage?.contains("media") == true)
        #expect(loggedMessage?.contains("failed") == true)
    }
}
