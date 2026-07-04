import Foundation
import SQLiteData

nonisolated enum BootstrapDefaults {
    static let blogTitle = "My Blog"
    static let bloggerDisplayName = "Me"
    static let mailingListName = "Subscribers"
    static let galleryIntervalSeconds = 900
    static let galleryDistanceMeters = 500.0
}

@Table
nonisolated struct Blog: Hashable, Identifiable {
    let id: UUID
    var title: String = BootstrapDefaults.blogTitle
    var createdAt: Date
    var updatedAt: Date
    var galleryIntervalSeconds: Int = BootstrapDefaults.galleryIntervalSeconds
    var galleryDistanceMeters: Double = BootstrapDefaults.galleryDistanceMeters
}

@Table
nonisolated struct Blogger: Hashable, Identifiable {
    let id: UUID
    var blogID: Blog.ID
    var displayName: String = BootstrapDefaults.bloggerDisplayName
    var createdAt: Date
    var updatedAt: Date
    var cloudKitParticipantIdentifier: String?
}

@Table
nonisolated struct BlogItem: Hashable, Identifiable {
    let id: UUID
    var blogID: Blog.ID
    var authorID: Blogger.ID
    var caption: String?
    var createdAt: Date
    var updatedAt: Date
    var itemDate: Date
    var itemTimeZoneIdentifier: String?
    var localDay: String
    var latitude: Double?
    var longitude: Double?
    var locationName: String?
    var countryCode: String?
    var weatherTemperatureCelsius: Double?
    var weatherConditionCode: String?
    var photoAssetID: MediaAsset.ID?
    var deletedAt: Date?
}

@Table
nonisolated struct MediaAsset: Hashable, Identifiable {
    let id: UUID
    var blogID: Blog.ID
    var kind: String = "photo"
    var localOriginalPath: String?
    var cloudAssetIdentifier: String?
    var contentHash: String?
    var cloudAssetHash: String?
    var cloudAssetSyncError: String?
    var filename: String
    var mimeType: String
    var pixelWidth: Int?
    var pixelHeight: Int?
    var createdAt: Date
    var updatedAt: Date

    var externalSyncState: SyncDependencyState {
        if let cloudAssetIdentifier,
           !cloudAssetIdentifier.isEmpty,
           let contentHash,
           cloudAssetHash == contentHash {
            return .synced
        }
        return cloudAssetSyncError == nil ? .pending : .failed
    }
}

@Table
nonisolated struct AppWorkspace: Hashable, Identifiable {
    let id: String
    var activeBlogID: Blog.ID?

    static let singletonID = "default"
}

@Table
nonisolated struct AppBlogIdentity: Hashable, Identifiable {
    @Column(primaryKey: true)
    var blogID: Blog.ID
    var bloggerID: Blogger.ID
    var id: Blog.ID { blogID }
}

@Table
nonisolated struct Trip: Hashable, Identifiable {
    let id: UUID
    var blogID: Blog.ID
    var title: String
    var description: String
    var startLocalDay: String
    var endLocalDay: String?
    var heroImageAssetID: MediaAsset.ID?
    var createdAt: Date
    var updatedAt: Date
    var closedAt: Date?
    var deletedAt: Date? = nil
}

@Table
nonisolated struct MailingList: Hashable, Identifiable {
    let id: UUID
    var blogID: Blog.ID
    var name: String = BootstrapDefaults.mailingListName
    var createdAt: Date
    var updatedAt: Date
}

@Table
nonisolated struct Subscriber: Hashable, Identifiable {
    let id: UUID
    var blogID: Blog.ID
    var mailingListID: MailingList.ID
    var emailAddress: String
    var displayName: String?
    var createdAt: Date
    var updatedAt: Date
}

@Table
nonisolated struct PublishEvent: Hashable, Identifiable {
    let id: UUID
    var blogID: Blog.ID
    var tripID: Trip.ID?
    var localDay: String
    var mailingListID: MailingList.ID
    var initiatedAt: Date
    var initiatedByBloggerID: Blogger.ID
    var recipientCount: Int
}
