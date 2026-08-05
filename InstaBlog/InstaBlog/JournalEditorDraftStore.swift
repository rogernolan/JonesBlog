import Foundation

/// A persisted snapshot of an in-progress journal post being edited.
///
/// The journal editor writes this when the app moves to the background and restores it
/// on the next launch, so edits survive iOS terminating the app while it is suspended
/// (or the user swiping it away from the app switcher).
nonisolated struct JournalEditorDraft: Codable, Equatable, Sendable {
    nonisolated struct Photo: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case existing
            case added
        }

        var kind: Kind
        var editablePhotoID: UUID
        var existingPhotoID: UUID?
        var existingCaption: String?
        var existingDate: Date?
        var addedPhoto: BlogItemPhotoAssetDraft?
        var addedPhotoPreviewData: Data?
    }

    var itemID: UUID
    var isNewItem: Bool
    var sourceID: UUID?
    var blogText: String
    var date: Date
    var location: String
    var latitude: Double?
    var longitude: Double?
    var temperature: Double
    var temperatureText: String
    var condition: String
    var photos: [Photo]
    var updatedAt: Date
}

/// Stores one `JournalEditorDraft` file per editor destination under Application Support
/// (or a test-provided directory).
@MainActor
final class JournalEditorDraftStore {
    /// Identifies which editor a draft belongs to.
    ///
    /// - `.editing(itemID)`: editing the existing post `itemID`.
    /// - `.newItem(sourceID)`: composing a new post inserted after the post `sourceID`.
    ///   The new post's own `id` is random, so the draft is keyed by the stable source.
    enum Destination: Hashable, Sendable {
        case editing(itemID: UUID)
        case newItem(sourceID: UUID)
    }

    private let directoryURL: URL
    private let fileManager: FileManager

    init(
        directoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        let resolved: URL
        if let override = ProcessInfo.processInfo.environment["UI_TEST_DRAFT_DIRECTORY"] {
            resolved = URL(fileURLWithPath: override, isDirectory: true)
        } else if let directoryURL {
            resolved = directoryURL
        } else if ProcessInfo.processInfo.arguments.contains("-ui-testing-in-memory-database") {
            // UI tests re-seed an in-memory database on every launch, so drafts must not
            // linger in the real Application Support container where the next test launch
            // would auto-restore them.
            resolved = fileManager.temporaryDirectory
                .appendingPathComponent("JournalEditorDrafts", isDirectory: true)
        } else {
            resolved = Self.defaultDirectoryURL(fileManager: fileManager)
        }
        self.directoryURL = resolved
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: resolved, withIntermediateDirectories: true)
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-reset-drafts") {
            removeAllDrafts()
        }
    }

    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JournalEditorDrafts", isDirectory: true)
    }

    func load(_ destination: Destination) -> JournalEditorDraft? {
        let url = fileURL(for: destination)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(JournalEditorDraft.self, from: data)
        } catch {
            logFailure("Could not load journal editor draft", error: error)
            return nil
        }
    }

    func save(_ draft: JournalEditorDraft) {
        do {
            let data = try JSONEncoder().encode(draft)
            try data.write(to: fileURL(for: destination(for: draft)), options: .atomic)
        } catch {
            logFailure("Could not save journal editor draft", error: error)
        }
    }

    func remove(_ destination: Destination) {
        let url = fileURL(for: destination)
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            logFailure("Could not remove journal editor draft", error: error)
        }
    }

    func pendingDrafts() -> [JournalEditorDraft] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                do {
                    let data = try Data(contentsOf: url)
                    return try JSONDecoder().decode(JournalEditorDraft.self, from: data)
                } catch {
                    logFailure("Could not decode journal editor draft", error: error)
                    return nil
                }
            }
    }

    func destination(for draft: JournalEditorDraft) -> Destination {
        if draft.isNewItem {
            return .newItem(sourceID: draft.sourceID ?? draft.itemID)
        }
        return .editing(itemID: draft.itemID)
    }

    private func fileURL(for destination: Destination) -> URL {
        directoryURL.appendingPathComponent(fileName(for: destination))
    }

    private func fileName(for destination: Destination) -> String {
        switch destination {
        case .editing(let itemID):
            "edit-\(itemID.uuidString).json"
        case .newItem(let sourceID):
            "new-\(sourceID.uuidString).json"
        }
    }

    private func removeAllDrafts() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in urls where url.pathExtension == "json" {
            try? fileManager.removeItem(at: url)
        }
    }

    private func logFailure(_ message: String, error: Error) {
        AppTelemetry.log(message, category: "journal.drafts", level: .error, error: error)
    }
}

extension TripDisplay {
    func journalItem(withID id: UUID) -> BlogItemDisplay? {
        for day in days {
            if let item = day.blogItems.first(where: { $0.id == id }) {
                return item
            }
        }
        return nil
    }

    func containsJournalItem(withID id: UUID) -> Bool {
        days.contains { day in
            day.blogItems.contains { $0.id == id }
        }
    }
}

extension BlogItemDisplay {
    /// Returns a copy with a different `id`, used when restoring a new-post draft so the
    /// rebuilt blank item keeps the identity the draft was persisted under.
    func withID(_ newID: UUID) -> BlogItemDisplay {
        BlogItemDisplay(
            id: newID,
            author: author,
            lastEditor: lastEditor,
            date: date,
            createdAt: createdAt,
            lastEditedAt: lastEditedAt,
            timeZoneIdentifier: timeZoneIdentifier,
            blogText: blogText,
            location: location,
            latitude: latitude,
            longitude: longitude,
            weather: weather,
            photos: photos,
            syncStatus: syncStatus
        )
    }
}

extension JournalEditorDraftStore {
    /// Resolves a pending draft to the trip and journal destination that should be shown on
    /// relaunch. Returns `nil` when the referenced post no longer exists.
    func restoredJournalDestination(
        for draft: JournalEditorDraft,
        in trips: [TripDisplay],
        makeBlankAfterSource: (BlogItemDisplay) -> BlogItemDisplay?
    ) -> (trip: TripDisplay, destination: JournalDestination)? {
        if draft.isNewItem {
            guard let sourceID = draft.sourceID,
                  let sourceTrip = trips.first(where: { $0.containsJournalItem(withID: sourceID) }),
                  let source = sourceTrip.journalItem(withID: sourceID),
                  let blank = makeBlankAfterSource(source)
            else { return nil }
            return (sourceTrip, .newBlogItem(blank.withID(draft.itemID), after: source))
        }
        guard let trip = trips.first(where: { $0.containsJournalItem(withID: draft.itemID) }),
              let item = trip.journalItem(withID: draft.itemID)
        else { return nil }
        return (trip, .blogItem(item))
    }
}
