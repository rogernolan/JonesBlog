import Foundation
import Testing

@testable import InstaBlog

@Suite("Media file cleanup")
struct MediaFileCleanupTests {
    private enum TestError: Error {
        case permissionDenied
    }

    @Test("successful deletion does not log an error")
    func successfulDeletionDoesNotLog() {
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        var removedURL: URL?
        var loggedMessages: [String] = []
        let cleanup = MediaFileCleanup(
            removeItem: { removedURL = $0 },
            logFailure: { loggedMessages.append($0) }
        )

        cleanup.removeItem(at: url)

        #expect(removedURL == url)
        #expect(loggedMessages.isEmpty)
    }

    @Test("failed deletion logs the file and underlying error")
    func failedDeletionLogsError() {
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        var loggedMessage: String?
        let cleanup = MediaFileCleanup(
            removeItem: { _ in throw TestError.permissionDenied },
            logFailure: { loggedMessage = $0 }
        )

        cleanup.removeItem(at: url)

        #expect(loggedMessage?.contains(url.path) == true)
        #expect(loggedMessage?.contains("permissionDenied") == true)
    }
}
