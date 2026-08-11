import Foundation

struct LayoutIntegrationIndex: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let layouts: [Layout]

    init(summaries: [SnapshotSummary]) {
        schemaVersion = Self.currentSchemaVersion
        layouts = summaries.map(Layout.init)
    }

    struct Layout: Codable, Equatable {
        let id: UUID
        let name: String
        let updatedAt: Date
        let windowCount: Int
        let appCount: Int
        let displayCount: Int

        init(summary: SnapshotSummary) {
            id = summary.id
            name = summary.name
            updatedAt = summary.updatedAt
            windowCount = summary.windowCount
            appCount = summary.appCount
            displayCount = summary.displayCount
        }
    }
}

struct LayoutIntegrationIndexWriter {
    let indexURL: URL

    private let fileManager: FileManager

    init(indexURL: URL, fileManager: FileManager = .default) {
        self.indexURL = indexURL
        self.fileManager = fileManager
    }

    init(bootstrapper: AppSupportDirectoryBootstrapper, fileManager: FileManager = .default) {
        self.init(
            indexURL: bootstrapper.integrationsURL.appendingPathComponent("layouts-v1.json"),
            fileManager: fileManager
        )
    }

    func write(summaries: [SnapshotSummary]) throws {
        try fileManager.createDirectory(
            at: indexURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(LayoutIntegrationIndex(summaries: summaries)).write(
            to: indexURL,
            options: .atomic
        )
    }
}
