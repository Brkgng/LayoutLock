import Foundation

struct UnrealProjectResolver {
    static func isUnreal(bundleIdentifier: String) -> Bool {
        bundleIdentifier == "com.epicgames.UnrealEditor"
    }

    static func isUntitledHelperWindow(_ window: DiscoveredWindow, bundleIdentifier: String) -> Bool {
        isUnreal(bundleIdentifier: bundleIdentifier) && window.role == "AXWindow" &&
            window.subrole == "AXUnknown" && window.title.nonEmptyValue == nil
    }

    func resolve(processIdentifier: pid_t, documentURL: URL? = nil) -> URL? {
        if let documentURL, let project = projectURL(documentURL) { return project }
        return resolve(
            projectPaths: ProjectProcessInfo.projectPaths(processIdentifier, selecting: Self.projectPaths),
            currentDirectoryURL: ProjectProcessInfo.currentDirectoryURL(processIdentifier)
        )
    }

    func resolve(projectPaths: [String], currentDirectoryURL: URL?) -> URL? {
        let directory = currentDirectoryURL.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
        let projects = Set(projectPaths.compactMap { path -> URL? in
            guard path.hasPrefix("/") || directory != nil else { return nil }
            return projectURL(URL(fileURLWithPath: path, relativeTo: directory))
        })
        return projects.count == 1 ? projects.first : nil
    }

    func projectURL(_ url: URL) -> URL? {
        guard url.isFileURL, url.pathExtension.lowercased() == "uproject",
              let data = try? Data(contentsOf: url),
              let project = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = project["FileVersion"] as? Int, version > 0 else { return nil }
        return url.standardizedFileURL
    }

    static func projectPaths(arguments: [String]) -> [String] {
        var paths: [String] = []
        // Unreal's positional project follows the executable; do not inspect unrelated flag values.
        if let first = arguments.dropFirst().first, !first.hasPrefix("-"),
           (first as NSString).pathExtension.lowercased() == "uproject" { paths.append(first) }
        for index in arguments.indices {
            let argument = arguments[index]
            if argument.lowercased() == "-project", arguments.indices.contains(index + 1),
               !arguments[index + 1].hasPrefix("-") {
                paths.append(arguments[index + 1])
            } else if argument.lowercased().hasPrefix("-project=") {
                paths.append(String(argument.dropFirst("-project=".count)))
            }
        }
        return paths
    }
}
