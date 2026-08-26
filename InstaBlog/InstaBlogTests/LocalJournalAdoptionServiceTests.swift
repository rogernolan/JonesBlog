import Foundation
import SQLiteData
import Testing
@testable import InstaBlog

@Suite("Local journal adoption")
struct LocalJournalAdoptionServiceTests {
    @Test func rejectsALocalDatabaseWithoutAnActiveWorkspace() throws {
        let service = LocalJournalAdoptionService(
            localDatabase: try AppDatabase.makeLocalInMemory(),
            cloudDatabase: try AppDatabase.makeInMemory()
        )

        #expect(throws: LocalJournalAdoptionService.AdoptionError.self) {
            try service.adopt(into: UUID())
        }
    }

    @Test func copiesLocalEntriesWithFreshIDsAndIsIdempotent() throws {
        let local = try AppDatabase.makeLocalInMemory()
        let cloud = try AppDatabase.makeInMemory()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let source = try BlogBootstrapService(database: local, now: { date }).bootstrap()
        let sourceItemID = UUID()
        let sourceMediaID = UUID()
        let sourcePhotoID = UUID()
        let sourceTripID = UUID()
        let destinationBlogID = UUID()
        try local.write { db in
            try BlogItem.insert {
                BlogItem.Draft(
                    id: sourceItemID,
                    blogID: source.blog.id,
                    authorID: source.blogger.id,
                    blogText: "Written offline",
                    createdAt: date,
                    updatedAt: date,
                    itemDate: date,
                    localDay: "2027-01-15",
                    altitude: 1_200,
                    showElevation: true
                )
            }.execute(db)
            try MediaAsset.insert {
                MediaAsset.Draft(
                    id: sourceMediaID,
                    blogID: source.blog.id,
                    filename: "offline.jpg",
                    mimeType: "image/jpeg",
                    createdAt: date,
                    updatedAt: date
                )
            }.execute(db)
            try PhotoItem.insert {
                PhotoItem.Draft(
                    id: sourcePhotoID,
                    blogID: source.blog.id,
                    blogItemID: sourceItemID,
                    mediaAssetID: sourceMediaID,
                    photoDate: date,
                    createdAt: date,
                    updatedAt: date
                )
            }.execute(db)
            try Trip.insert {
                Trip.Draft(
                    id: sourceTripID,
                    blogID: source.blog.id,
                    title: "Offline trip",
                    description: "",
                    startLocalDay: "2027-01-15",
                    createdAt: date,
                    updatedAt: date
                )
            }.execute(db)
        }
        try cloud.write { db in
            try Blog.insert {
                Blog.Draft(id: destinationBlogID, title: "Shared journal", createdAt: date, updatedAt: date)
            }.execute(db)
        }

        let service = LocalJournalAdoptionService(localDatabase: local, cloudDatabase: cloud)
        let firstAdoption = try service.adopt(into: destinationBlogID)
        let secondAdoption = try service.adopt(into: destinationBlogID)
        #expect(firstAdoption.sourceItemIDs == [sourceItemID])
        #expect(secondAdoption == firstAdoption)
        try service.verify(firstAdoption)

        try cloud.read { db in
            let items = try BlogItem.where { $0.blogID.eq(destinationBlogID) }.fetchAll(db)
            let assets = try MediaAsset.where { $0.blogID.eq(destinationBlogID) }.fetchAll(db)
            let photos = try PhotoItem.where { $0.blogID.eq(destinationBlogID) }.fetchAll(db)
            let bloggers = try Blogger.where { $0.blogID.eq(destinationBlogID) }.fetchAll(db)
            let trips = try Trip.where { $0.blogID.eq(destinationBlogID) }.fetchAll(db)
            #expect(items.count == 1)
            #expect(assets.count == 1)
            #expect(photos.count == 1)
            #expect(bloggers.count == 1)
            #expect(trips.isEmpty)
            #expect(items[0].id != sourceItemID)
            #expect(items[0].altitude == 1_200)
            #expect(items[0].showElevation)
            #expect(assets[0].id != sourceMediaID)
            #expect(photos[0].id != sourcePhotoID)
            #expect(photos[0].blogItemID == items[0].id)
            #expect(photos[0].mediaAssetID == assets[0].id)
        }
    }
}
