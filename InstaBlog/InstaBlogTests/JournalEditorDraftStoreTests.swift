import Foundation
import Testing
@testable import InstaBlog

@MainActor
struct JournalEditorDraftStoreTests {
    private func makeStore() throws -> (JournalEditorDraftStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JournalEditorDraftStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (JournalEditorDraftStore(directoryURL: directory), directory)
    }

    private func makeDraft(
        itemID: UUID = UUID(),
        isNewItem: Bool = false,
        sourceID: UUID? = nil,
        blogText: String = "Draft text",
        updatedAt: Date = Date()
    ) -> JournalEditorDraft {
        JournalEditorDraft(
            itemID: itemID,
            isNewItem: isNewItem,
            sourceID: sourceID,
            blogText: blogText,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            location: "Paris",
            latitude: 48.8566,
            longitude: 2.3522,
            temperature: 18.5,
            temperatureText: "18",
            condition: "Clear",
            photos: [],
            updatedAt: updatedAt
        )
    }

    private func makeItem(id: UUID = UUID(), location: String = "Paris") -> BlogItemDisplay {
        BlogItemDisplay(
            id: id,
            author: "Rog",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            blogText: "Seed post",
            location: location,
            weather: WeatherDisplay()
        )
    }

    @Test
    func saveThenLoadRoundTripsEditingDraft() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let itemID = UUID()
        let draft = makeDraft(itemID: itemID)
        store.save(draft)

        let loaded = store.load(.editing(itemID: itemID))
        #expect(loaded == draft)
    }

    @Test
    func saveThenLoadRoundTripsNewItemDraftKeyedBySourceID() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceID = UUID()
        let draft = makeDraft(itemID: UUID(), isNewItem: true, sourceID: sourceID)
        store.save(draft)

        #expect(store.load(.newItem(sourceID: sourceID)) == draft)
    }

    @Test
    func draftWithPhotosRoundTripsAddedPhotoData() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let itemID = UUID()
        var draft = makeDraft(itemID: itemID)
        draft.photos = [
            JournalEditorDraft.Photo(
                kind: .added,
                editablePhotoID: UUID(),
                existingPhotoID: nil,
                existingCaption: nil,
                existingDate: nil,
                addedPhoto: BlogItemPhotoAssetDraft(
                    imageData: Data([0x01, 0x02, 0x03]),
                    mimeType: "image/jpeg",
                    photoLibraryAssetIdentifier: "asset-1",
                    pixelWidth: 100,
                    pixelHeight: 200,
                    photoDate: Date(timeIntervalSince1970: 1_700_000_000),
                    photoCaption: "Sunset"
                ),
                addedPhotoPreviewData: Data([0xaa, 0xbb])
            ),
            JournalEditorDraft.Photo(
                kind: .existing,
                editablePhotoID: UUID(),
                existingPhotoID: UUID(),
                existingCaption: "Old caption",
                existingDate: Date(timeIntervalSince1970: 1_700_000_000),
                addedPhoto: nil,
                addedPhotoPreviewData: nil
            ),
        ]
        store.save(draft)

        #expect(store.load(.editing(itemID: itemID)) == draft)
    }

    @Test
    func loadReturnsNilWhenNoDraftExists() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(store.load(.editing(itemID: UUID())) == nil)
    }

    @Test
    func removeDeletesDraft() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let itemID = UUID()
        store.save(makeDraft(itemID: itemID))
        store.remove(.editing(itemID: itemID))

        #expect(store.load(.editing(itemID: itemID)) == nil)
        #expect(store.pendingDrafts().isEmpty)
    }

    @Test
    func pendingDraftsReturnsEverySavedDestination() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstID = UUID()
        let secondID = UUID()
        let newSourceID = UUID()
        store.save(makeDraft(itemID: firstID, blogText: "First"))
        store.save(makeDraft(itemID: secondID, blogText: "Second"))
        store.save(makeDraft(itemID: UUID(), isNewItem: true, sourceID: newSourceID, blogText: "New"))

        let pending = store.pendingDrafts()
        #expect(pending.count == 3)
        #expect(pending.contains { $0.blogText == "First" })
        #expect(pending.contains { $0.blogText == "Second" })
        #expect(pending.contains { $0.blogText == "New" })
    }

    @Test
    func saveOverwritesDraftForSameDestination() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let itemID = UUID()
        store.save(makeDraft(itemID: itemID, blogText: "First"))
        store.save(makeDraft(itemID: itemID, blogText: "Second"))

        let pending = store.pendingDrafts()
        #expect(pending.count == 1)
        #expect(pending.first?.blogText == "Second")
    }

    @Test
    func destinationMapsDraftKind() throws {
        let (store, _) = try makeStore()

        let itemID = UUID()
        #expect(store.destination(for: makeDraft(itemID: itemID)) == .editing(itemID: itemID))

        let sourceID = UUID()
        #expect(store.destination(for: makeDraft(itemID: UUID(), isNewItem: true, sourceID: sourceID)) == .newItem(sourceID: sourceID))
    }

    @Test
    func newItemDraftWithoutSourceFallsBackToItemID() throws {
        let (store, _) = try makeStore()

        let itemID = UUID()
        let draft = makeDraft(itemID: itemID, isNewItem: true, sourceID: nil)
        #expect(store.destination(for: draft) == .newItem(sourceID: itemID))
    }

    @Test
    func restoredDestinationResolvesEditingDraft() throws {
        let (store, _) = try makeStore()

        let item = makeItem()
        let trip = TripDisplay(
            title: "Provence",
            days: [DayPostDisplay(date: item.date, route: [], blogItems: [item])]
        )

        let draft = makeDraft(itemID: item.id)
        let restored = store.restoredJournalDestination(for: draft, in: [trip]) { _ in nil }
        #expect(restored?.trip == trip)
        #expect(restored?.destination == .blogItem(item))
    }

    @Test
    func restoredDestinationReturnsNilWhenEditingPostMissing() throws {
        let (store, _) = try makeStore()

        let trip = TripDisplay(
            title: "Provence",
            days: [DayPostDisplay(date: Date(), route: [], blogItems: [makeItem()])]
        )

        let draft = makeDraft(itemID: UUID())
        let restored = store.restoredJournalDestination(for: draft, in: [trip]) { _ in nil }
        #expect(restored == nil)
    }

    @Test
    func restoredDestinationResolvesNewItemDraft() throws {
        let (store, _) = try makeStore()

        let source = makeItem(location: "Arles")
        let trip = TripDisplay(
            title: "Provence",
            days: [DayPostDisplay(date: source.date, route: [], blogItems: [source])]
        )

        let draftItemID = UUID()
        let draft = makeDraft(itemID: draftItemID, isNewItem: true, sourceID: source.id)
        let restored = store.restoredJournalDestination(for: draft, in: [trip]) { _ in
            makeItem(location: "")
        }

        guard case .newBlogItem(let restoredItem, let restoredSource)? = restored?.destination else {
            Issue.record("expected newBlogItem destination")
            return
        }
        #expect(restoredItem.id == draftItemID)
        #expect(restoredSource == source)
        #expect(restored?.trip == trip)
    }

    @Test
    func restoredDestinationReturnsNilWhenNewItemSourceMissing() throws {
        let (store, _) = try makeStore()

        let trip = TripDisplay(
            title: "Provence",
            days: [DayPostDisplay(date: Date(), route: [], blogItems: [makeItem()])]
        )

        let draft = makeDraft(itemID: UUID(), isNewItem: true, sourceID: UUID())
        let restored = store.restoredJournalDestination(for: draft, in: [trip]) { _ in nil }
        #expect(restored == nil)
    }

    @Test
    func withIDReturnsCopyWithNewIdentityOnly() throws {
        let original = makeItem()
        let newID = UUID()
        let copy = original.withID(newID)

        #expect(copy.id == newID)
        #expect(copy.author == original.author)
        #expect(copy.blogText == original.blogText)
        #expect(copy.location == original.location)
        #expect(copy.date == original.date)
        #expect(copy.weather == original.weather)
        #expect(copy.photos == original.photos)
    }

    @Test
    func tripHelpersFindAndIdentifyItems() throws {
        let present = makeItem()
        let absent = makeItem()
        let trip = TripDisplay(
            title: "Provence",
            days: [DayPostDisplay(date: present.date, route: [], blogItems: [present])]
        )

        #expect(trip.journalItem(withID: present.id) == present)
        #expect(trip.journalItem(withID: absent.id) == nil)
        #expect(trip.containsJournalItem(withID: present.id))
        #expect(!trip.containsJournalItem(withID: absent.id))
    }
}
