import Foundation
import SQLiteData
import Testing

@testable import InstaBlog

@Suite("Blog archive transfer")
struct BlogArchiveServiceTests {
    @Test func archiveRoundTripPreservesRecordsAndMediaWithoutCloudState() async throws {
        let source = try ArchiveFixture()
        let itemID = try source.journal.createBlogItem(
            blogText: "Recent trip",
            date: source.now,
            timeZoneIdentifier: "Europe/London",
            photos: [source.photoDraft]
        )
        let tripID = try source.journal.createTrip(
            title: "Scotland",
            description: "Summer trip",
            startLocalDay: "2026-07-01",
            endLocalDay: "2026-07-12"
        )
        let exported = try await source.archive.exportBlog(
            blogID: source.workspace.blog.id,
            selectedBloggerID: source.workspace.blogger.id
        )
        let summary = try source.archive.summary(of: exported.url)

        let destination = try ArchiveFixture()
        try await destination.archive.importBlog(from: exported.url)

        let snapshot = try await destination.database.read { db in
            (
                try Blog.find(db, key: source.workspace.blog.id),
                try BlogItem.find(db, key: itemID),
                try Trip.find(db, key: tripID),
                try MediaAsset.all.fetchOne(db),
                try AppWorkspace.find(db, key: AppWorkspace.singletonID),
                try AppBlogIdentity.find(db, key: source.workspace.blog.id)
            )
        }
        let mediaAsset = try #require(snapshot.3)
        let localPath = try #require(mediaAsset.localOriginalPath)

        #expect(snapshot.0.id == source.workspace.blog.id)
        #expect(snapshot.1.blogText == "Recent trip")
        #expect(snapshot.2.title == "Scotland")
        #expect(snapshot.4.activeBlogID == source.workspace.blog.id)
        #expect(snapshot.5.bloggerID == source.workspace.blogger.id)
        #expect(summary.blogTitle == source.workspace.blog.title)
        #expect(summary.tripCount == 1)
        #expect(summary.postCount == 1)
        #expect(summary.photoCount == 1)
        #expect(summary.importDescription == "This will create 1 trip and 1 post, containing 1 photo.")
        #expect(mediaAsset.cloudAssetIdentifier == nil)
        #expect(mediaAsset.cloudAssetHash == nil)
        #expect(mediaAsset.cloudAssetSyncError == nil)
        #expect(
            FileManager.default.fileExists(
                atPath: destination.mediaURL.appendingPathComponent(localPath).path
            )
        )
    }

    @Test func archiveSummaryPluralizesCounts() {
        let summary = BlogArchiveSummary(
            blogTitle: "Recent trip",
            tripCount: 3,
            postCount: 400,
            photoCount: 139
        )

        #expect(
            summary.importDescription
                == "This will create 3 trips and 400 posts, containing 139 photos."
        )
    }

    @Test func importRefusesToReplaceMeaningfulData() async throws {
        let source = try ArchiveFixture()
        _ = try source.journal.createBlogItem(
            blogText: "Export me",
            date: source.now,
            timeZoneIdentifier: "UTC"
        )
        let exported = try await source.archive.exportBlog(
            blogID: source.workspace.blog.id,
            selectedBloggerID: source.workspace.blogger.id
        )

        let destination = try ArchiveFixture()
        _ = try destination.journal.createBlogItem(
            blogText: "Do not replace me",
            date: destination.now,
            timeZoneIdentifier: "UTC"
        )

        await #expect(throws: BlogArchiveError.destinationContainsData) {
            try await destination.archive.importBlog(from: exported.url)
        }
    }
}

private final class ArchiveFixture {
    let database: any DatabaseWriter
    let workspace: BootstrapWorkspace
    let journal: JournalService
    let archive: BlogArchiveService
    let rootURL: URL
    let mediaURL: URL
    let now = Date(timeIntervalSince1970: 1_783_512_000)

    init() throws {
        database = try AppDatabase.makeInMemory()
        workspace = try BlogBootstrapService(database: database).bootstrap()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlogArchiveTests-\(UUID().uuidString)", isDirectory: true)
        mediaURL = rootURL.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        journal = JournalService(
            database: database,
            mediaDirectoryURL: mediaURL,
            blogID: workspace.blog.id,
            bloggerID: workspace.blogger.id
        )
        archive = BlogArchiveService(
            database: database,
            mediaDirectoryURL: mediaURL
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    var photoDraft: BlogItemPhotoAssetDraft {
        BlogItemPhotoAssetDraft(
            imageData: Data([0xFF, 0xD8, 0xFF, 0xD9]),
            mimeType: "image/jpeg",
            photoLibraryAssetIdentifier: "test-photo",
            pixelWidth: 1,
            pixelHeight: 1,
            photoDate: now,
            photoCaption: "Loch",
            timeZoneIdentifier: "Europe/London",
            latitude: 57.0,
            longitude: -4.0,
            locationName: "Scotland",
            countryCode: "GB"
        )
    }
}
