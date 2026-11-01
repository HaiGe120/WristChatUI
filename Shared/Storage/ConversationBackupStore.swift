import Foundation
import SwiftData

public enum ConversationBackupStore {
    public static let iCloudContainerIdentifier = "iCloud.com.wristassistant.app"

    @MainActor
    public static func writeBackup(for conversations: [Conversation]) throws -> ConversationBackupResult {
        let payload = ConversationBackupPayload(
            schemaVersion: 2,
            exportedAt: Date(),
            appName: "WristChat",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            conversations: conversations
                .sorted { $0.updatedAt > $1.updatedAt }
                .map(ConversationSnapshot.init)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

        let data = try encoder.encode(payload)
        let directory = try backupDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fileURL = directory.appendingPathComponent(Self.fileName(exportedAt: payload.exportedAt))
        try data.write(to: fileURL, options: [.atomic])

        return ConversationBackupResult(url: fileURL, conversationCount: payload.conversations.count)
    }

    @MainActor
    public static func restoreLatestBackup(into context: ModelContext) throws -> ConversationRestoreResult {
        let fileURL = try latestBackupURL()
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(ConversationBackupPayload.self, from: data)
        SyncInbox.shared.upsertConversations(payload.conversations)
        try? context.save()
        return ConversationRestoreResult(
            url: fileURL,
            conversationCount: payload.conversations.count,
            conversations: payload.conversations
        )
    }

    private static func latestBackupURL() throws -> URL {
        let directory = try backupDirectory()
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let backups = urls.filter { $0.pathExtension.lowercased() == "json" }
        guard let latest = try backups.max(by: { lhs, rhs in
            let lhsDate = try lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            let rhsDate = try rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
            return lhsDate < rhsDate
        }) else {
            throw ConversationBackupError.noBackupsFound
        }
        return latest
    }

    private static func backupDirectory() throws -> URL {
        guard let containerURL = FileManager.default.url(forUbiquityContainerIdentifier: iCloudContainerIdentifier) else {
            throw ConversationBackupError.iCloudUnavailable
        }

        return containerURL
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
    }

    private static func fileName(exportedAt: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: exportedAt)
            .replacingOccurrences(of: ":", with: "-")
        return "WristChat-Conversations-\(stamp).json"
    }
}

public struct ConversationBackupResult {
    public let url: URL
    public let conversationCount: Int

    public var fileName: String {
        url.lastPathComponent
    }
}

public struct ConversationRestoreResult {
    public let url: URL
    public let conversationCount: Int
    public let conversations: [ConversationSnapshot]

    public var fileName: String {
        url.lastPathComponent
    }
}

public enum ConversationBackupError: LocalizedError {
    case iCloudUnavailable
    case noBackupsFound

    public var errorDescription: String? {
        switch self {
        case .iCloudUnavailable:
            return "iCloud Drive is not available for this Apple ID or device."
        case .noBackupsFound:
            return "No iCloud conversation backups were found."
        }
    }
}

private struct ConversationBackupPayload: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let appName: String
    let appVersion: String
    let conversations: [ConversationSnapshot]
}
