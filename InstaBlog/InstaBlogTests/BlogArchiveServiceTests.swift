import Foundation
import SQLiteData
import Testing

@testable import InstaBlog

@Suite("Blog archive transfer")
struct BlogArchiveServiceTests {
    @Test func legacyBlogItemArchiveDefaultsElevationVisibilityFromAltitude() async throws {
        let fixture = try ArchiveFixture()
        let itemID = try fixture.journal.createBlogItem(
            blogText: "Legacy archive",
            date: fixture.now,
            timeZoneIdentifier: "Europe/London",
            photos: [fixture.photoDraft]
        )
        let item = try await fixture.database.read { db in
            try BlogItem.find(itemID).fetchOne(db)
        }
        let encoded = try JSONEncoder().encode(try #require(item))
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "showElevation")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(BlogItem.self, from: legacyData)
        #expect(decoded.altitude == 1_200)
        #expect(decoded.showElevation)
    }

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
        let importedBlogID = try await destination.archive.importBlog(from: exported.url)

        let snapshot = try await destination.database.read { db in
            (
                try Blog.find(db, key: importedBlogID),
                try BlogItem.all.fetchOne(db),
                try Trip.all.fetchOne(db),
                try MediaAsset.all.fetchOne(db),
                try AppWorkspace.find(db, key: AppWorkspace.singletonID),
                try AppBlogIdentity.find(db, key: importedBlogID),
                try PhotoItem.all.fetchOne(db),
                try Int.fetchOne(
                    db,
                    sql: "SELECT count(*) FROM sqlitedata_icloud.sqlitedata_icloud_metadata WHERE _isDeleted = 0"
                )
            )
        }
        let importedItem = try #require(snapshot.1)
        let importedTrip = try #require(snapshot.2)
        let mediaAsset = try #require(snapshot.3)
        let importedPhoto = try #require(snapshot.6)
        let localPath = try #require(mediaAsset.localOriginalPath)

        #expect(importedBlogID != source.workspace.blog.id)
        #expect(importedItem.id != itemID)
        #expect(importedTrip.id != tripID)
        #expect(snapshot.0.id == importedBlogID)
        #expect(importedItem.blogID == importedBlogID)
        #expect(importedItem.blogText == "Recent trip")
        #expect(importedItem.altitude == 1_200)
        #expect(importedItem.showElevation)
        #expect(importedTrip.blogID == importedBlogID)
        #expect(importedTrip.title == "Scotland")
        #expect(importedPhoto.blogID == importedBlogID)
        #expect(importedPhoto.blogItemID == importedItem.id)
        #expect(importedPhoto.mediaAssetID == mediaAsset.id)
        #expect(snapshot.4.activeBlogID == importedBlogID)
        #expect(snapshot.5.bloggerID != source.workspace.blogger.id)
        #expect(snapshot.7 == 7)
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

        try await destination.persistence.syncEngine.start()
        let postSyncCounts = try await destination.database.read { db in
            try ["blogs", "bloggers", "blogItems", "mediaAssets", "photoItems", "trips", "mailingLists"]
                .map { table in
                    try Int.fetchOne(db, sql: "SELECT count(*) FROM \(table)")!
                }
        }
        #expect(postSyncCounts == [1, 1, 1, 1, 1, 1, 1])
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

    @Test func stagingSummaryRejectsDamagedPhotoData() async throws {
        let source = try ArchiveFixture()
        _ = try source.journal.createBlogItem(
            blogText: "Photo",
            date: source.now,
            timeZoneIdentifier: "UTC",
            photos: [source.photoDraft]
        )
        let exported = try await source.archive.exportBlog(
            blogID: source.workspace.blog.id,
            selectedBloggerID: source.workspace.blogger.id
        )
        let mediaDirectory = exported.url.appendingPathComponent("Media", isDirectory: true)
        let mediaURL = try #require(
            FileManager.default.contentsOfDirectory(
                at: mediaDirectory,
                includingPropertiesForKeys: nil
            ).first
        )
        try Data([0x00]).write(to: mediaURL, options: .atomic)

        #expect(throws: BlogArchiveError.mediaHashMismatch(mediaURL.lastPathComponent)) {
            try source.archive.summary(of: exported.url)
        }
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
    let persistence: AppPersistence
    let workspace: BootstrapWorkspace
    let journal: JournalService
    let archive: BlogArchiveService
    let rootURL: URL
    let mediaURL: URL
    let now = Date(timeIntervalSince1970: 1_783_512_000)

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("BlogArchiveTests-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = rootURL.appendingPathComponent("Database", isDirectory: true)
        mediaURL = rootURL.appendingPathComponent("Media", isDirectory: true)
        try FileManager.default.createDirectory(at: databaseURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mediaURL, withIntermediateDirectories: true)
        database = try AppDatabase.makeLive(in: databaseURL)
        persistence = try AppPersistence(
            database: database,
            containerIdentifier: AppCloudKitConfiguration.containerIdentifier,
            startImmediately: false
        )
        workspace = try BlogBootstrapService(database: database).bootstrap()
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
        persistence.syncEngine.stop()
        try? database.close()
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
            altitude: 1_200,
            locationName: "Scotland",
            countryCode: "GB"
        )
    }
}
