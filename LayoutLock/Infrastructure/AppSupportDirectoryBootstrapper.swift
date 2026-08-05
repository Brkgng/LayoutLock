import Foundation

struct AppSupportDirectoryBootstrapper {
    let rootURL: URL
    let snapshotsURL: URL
    let logsURL: URL

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) throws {
        guard let appSupportBaseURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw BootstrapError.applicationSupportUnavailable
        }

        let rootURL = appSupportBaseURL.appendingPathComponent("LayoutLock", isDirectory: true)

        self.rootURL = rootURL
        snapshotsURL = rootURL.appendingPathComponent("Snapshots", isDirectory: true)
        logsURL = rootURL.appendingPathComponent("Logs", isDirectory: true)
        self.fileManager = fileManager
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
