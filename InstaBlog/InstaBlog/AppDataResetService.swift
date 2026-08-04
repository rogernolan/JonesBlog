import CloudKit
import Foundation

nonisolated struct AppDataResetService {
    let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func eraseCloudData() async throws {
        guard let containerIdentifier = AppCloudKitConfiguration.containerIdentifier else { return }
        let container = CKContainer(identifier: containerIdentifier)
        try await eraseSQLiteDataZone(in: container.privateCloudDatabase)
        try await eraseSQLiteDataZone(in: container.sharedCloudDatabase)
        try await createEmptySQLiteDataZone(in: container.privateCloudDatabase)
    }

    func eraseLocalData() throws {
        let applicationSupportDirectory = try AppDatabase.applicationSupportDirectory(
            fileManager: fileManager
        )
        try eraseLocalData(in: applicationSupportDirectory)
    }

    func eraseLocalData(in applicationSupportDirectory: URL) throws {
        for url in AppDatabase.liveDatabaseURLs(in: applicationSupportDirectory) {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            try fileManager.removeItem(at: url)
        }

        let mediaDirectoryURL = applicationSupportDirectory
            .appendingPathComponent("BlogItemMedia", isDirectory: true)
        if fileManager.fileExists(atPath: mediaDirectoryURL.path) {
            try fileManager.removeItem(at: mediaDirectoryURL)
        }
    }

    private func eraseSQLiteDataZone(in database: CKDatabase) async throws {
        let zoneIDs = try await database.allRecordZones()
            .map(\.zoneID)
            .filter { $0.zoneName == AppCloudKitConfiguration.defaultZoneName }
        guard !zoneIDs.isEmpty else { return }

        let results = try await database.modifyRecordZones(
            saving: [],
            deleting: zoneIDs
        )
        for result in results.deleteResults.values {
            _ = try result.get()
        }
    }

    private func createEmptySQLiteDataZone(in database: CKDatabase) async throws {
        let zone = AppCloudKitConfiguration.defaultZone
        let results = try await database.modifyRecordZones(
            saving: [zone],
            deleting: []
        )
        for result in results.saveResults.values {
            _ = try result.get()
        }
    }
}
