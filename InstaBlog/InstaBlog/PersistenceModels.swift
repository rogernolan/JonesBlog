import Foundation
import SQLiteData

nonisolated enum BootstrapDefaults {
    static let blogTitle = "My Blog"
    static let bloggerDisplayName = "Me"
    static let mailingListName = "Subscribers"
}

@Table
nonisolated struct Blog: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var title: String = BootstrapDefaults.blogTitle
    var createdAt: Date
    var updatedAt: Date
}

@Table
nonisolated struct Blogger: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var blogID: Blog.ID
    var displayName: String = BootstrapDefaults.bloggerDisplayName
    var createdAt: Date
    var updatedAt: Date
    var cloudKitParticipantIdentifier: String?
}

@Table
nonisolated struct BlogItem: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var blogID: Blog.ID
    var authorID: Blogger.ID
    var lastEditorID: Blogger.ID?
    var blogText: String?
    var createdAt: Date
    var updatedAt: Date
    var lastEditedAt: Date?
    var itemDate: Date
    var itemTimeZoneIdentifier: String?
    var localDay: String
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var showElevation: Bool = false
    var locationName: String?
    var countryCode: String?
    var weatherTemperatureCelsius: Double?
    var weatherConditionCode: String?
    var deletedAt: Date?
}

extension BlogItem {
    private enum CodingKeys: String, CodingKey {
        case id, blogID, authorID, lastEditorID, blogText, createdAt, updatedAt, lastEditedAt
        case itemDate, itemTimeZoneIdentifier, localDay, latitude, longitude, altitude
        case showElevation, locationName, countryCode, weatherTemperatureCelsius
        case weatherConditionCode, deletedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        blogID = try values.decode(UUID.self, forKey: .blogID)
        authorID = try values.decode(UUID.self, forKey: .authorID)
        lastEditorID = try values.decodeIfPresent(UUID.self, forKey: .lastEditorID)
        blogText = try values.decodeIfPresent(String.self, forKey: .blogText)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        lastEditedAt = try values.decodeIfPresent(Date.self, forKey: .lastEditedAt)
        itemDate = try values.decode(Date.self, forKey: .itemDate)
        itemTimeZoneIdentifier = try values.decodeIfPresent(String.self, forKey: .itemTimeZoneIdentifier)
        localDay = try values.decode(String.self, forKey: .localDay)
        latitude = try values.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try values.decodeIfPresent(Double.self, forKey: .longitude)
        altitude = try values.decodeIfPresent(Double.self, forKey: .altitude)
        showElevation = try values.decodeIfPresent(Bool.self, forKey: .showElevation)
            ?? (altitude.map { $0 > 800 && $0.isFinite } ?? false)
        locationName = try values.decodeIfPresent(String.self, forKey: .locationName)
        countryCode = try values.decodeIfPresent(String.self, forKey: .countryCode)
        weatherTemperatureCelsius = try values.decodeIfPresent(Double.self, forKey: .weatherTemperatureCelsius)
        weatherConditionCode = try values.decodeIfPresent(String.self, forKey: .weatherConditionCode)
        deletedAt = try values.decodeIfPresent(Date.self, forKey: .deletedAt)
    }
}

@Table
nonisolated struct PhotoItem: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var blogID: Blog.ID
    var blogItemID: BlogItem.ID
    var mediaAssetID: MediaAsset.ID
    var photoCaption: String?
    var photoDate: Date
    var createdAt: Date
    var updatedAt: Date
}

@Table
nonisolated struct MediaAsset: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var blogID: Blog.ID
    var kind: String = "photo"
    var localOriginalPath: String?
    var photoLibraryAssetIdentifier: String?
    var photoLibraryAssetUploaderID: Blogger.ID?
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
nonisolated struct Trip: Codable, Hashable, Identifiable, Sendable {
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
nonisolated struct MailingList: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var blogID: Blog.ID
    var name: String = BootstrapDefaults.mailingListName
    var createdAt: Date
    var updatedAt: Date
}

@Table
nonisolated struct Subscriber: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var blogID: Blog.ID
    var mailingListID: MailingList.ID
    var emailAddress: String
    var displayName: String?
    var createdAt: Date
    var updatedAt: Date
}

@Table
nonisolated struct PublishEvent: Codable, Hashable, Identifiable, Sendable {
    let id: UUID
    var blogID: Blog.ID
    var tripID: Trip.ID?
    var localDay: String
    var mailingListID: MailingList.ID
    var initiatedAt: Date
    var initiatedByBloggerID: Blogger.ID
    var recipientCount: Int
}
