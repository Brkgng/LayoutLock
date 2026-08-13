import Foundation

struct AppSupportDirectoryBootstrapper {
    let rootURL: URL
    let snapshotsURL: URL
    let logsURL: URL
    let integrationsURL: URL

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) throws {
        guard let appSupportBaseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw BootstrapError.applicationSupportUnavailable
        }

        self.init(
            applicationSupportBaseURL: appSupportBaseURL,
            directoryName: Self.configuredDirectoryName,
            fileManager: fileManager
        )
    }

    init(
        applicationSupportBaseURL: URL,
        directoryName: String = "LayoutLock",
        fileManager: FileManager = .default
    ) {
        let rootURL = applicationSupportBaseURL.appendingPathComponent(directoryName, isDirectory: true)

        self.rootURL = rootURL
        snapshotsURL = rootURL.appendingPathComponent("Snapshots", isDirectory: true)
        logsURL = rootURL.appendingPathComponent("Logs", isDirectory: true)
        integrationsURL = rootURL.appendingPathComponent("Integrations", isDirectory: true)
        self.fileManager = fileManager
    }

    private static var configuredDirectoryName: String {
        Bundle.main.object(forInfoDictionaryKey: "LayoutLockApplicationSupportDirectoryName") as? String
            ?? "LayoutLock"
    }

    func prepare() throws {
        for directoryURL in [rootURL, snapshotsURL, logsURL] {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
    }
}

extension AppSupportDirectoryBootstrapper {
    enum BootstrapError: LocalizedError {
        case applicationSupportUnavailable

        var errorDescription: String? {
            switch self {
            case .applicationSupportUnavailable:
                return "Application Support directory could not be resolved."
            }
        }
    }
}
