import Foundation

/// Unity's document is a scene; its independently launched Editor belongs to a project.
struct UnityProjectResolver {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    static func isUnity(bundleIdentifier: String) -> Bool {
        bundleIdentifier == "com.unity3d.UnityEditor5.x"
    }

    func resolve(processIdentifier: pid_t, documentURL: URL?) -> URL? {
        if let documentURL, let project = projectURL(containing: documentURL) {
            return project
        }
        return resolve(
            projectPaths: ProjectProcessInfo.projectPaths(processIdentifier, selecting: Self.projectPaths),
            currentDirectoryURL: ProjectProcessInfo.currentDirectoryURL(processIdentifier)
        )
    }

    func resolve(projectPaths: [String], currentDirectoryURL: URL?) -> URL? {
        let projects = Set(projectPaths.compactMap { path -> URL? in
            guard path.hasPrefix("/") || currentDirectoryURL != nil else { return nil }
            let url = URL(fileURLWithPath: path, relativeTo: currentDirectoryURL)
                .standardizedFileURL
            return editorVersion(projectURL: url) == nil ? nil : url
        })
        if projects.count == 1 {
            return projects.first
        }
        guard projects.isEmpty, let currentDirectoryURL,
              editorVersion(projectURL: currentDirectoryURL) != nil else {
            return nil
        }
        return currentDirectoryURL.standardizedFileURL
    }

    /// Accept a project itself or a document inside that project's Assets directory.
    func projectURL(containing url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        let document = url.standardizedFileURL
        if editorVersion(projectURL: document) != nil {
            return document
        }
        var ancestor = document.deletingLastPathComponent()
        while ancestor.path != "/" {
            if ancestor.lastPathComponent == "Assets" {
                let project = ancestor.deletingLastPathComponent()
                if editorVersion(projectURL: project) != nil {
                    return project
                }
            }
            ancestor.deleteLastPathComponent()
        }
        return nil
    }

    func editorVersion(projectURL: URL) -> String? {
        guard projectURL.isFileURL,
              isDirectory(projectURL.appendingPathComponent("Assets", isDirectory: true)),
              let contents = try? String(
                  contentsOf: projectURL.appendingPathComponent("ProjectSettings/ProjectVersion.txt"),
                  encoding: .utf8
              ),
              let line = contents.split(whereSeparator: \.isNewline).first(where: {
                  $0.hasPrefix("m_EditorVersion:")
              }) else {
            return nil
        }
        let version = line.dropFirst("m_EditorVersion:".count)
            .trimmingCharacters(in: .whitespaces)
        // This value becomes a Hub directory component. Never accept a path from metadata.
        guard version.first?.isNumber == true,
              version.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_")).contains($0)
              }) else {
            return nil
        }
        return version
    }

    func editorURL(projectURL: URL, preferredApplicationURL: URL?) -> URL? {
        guard let version = editorVersion(projectURL: projectURL) else { return nil }
        var candidates: [URL] = []
        if let preferredApplicationURL {
            candidates.append(preferredApplicationURL)
            candidates.append(
                preferredApplicationURL.deletingLastPathComponent().deletingLastPathComponent()
                    .appendingPathComponent(version, isDirectory: true)
                    .appendingPathComponent("Unity.app", isDirectory: true)
            )
        }
        candidates.append(
            URL(fileURLWithPath: "/Applications/Unity/Hub/Editor", isDirectory: true)
                .appendingPathComponent(version, isDirectory: true)
                .appendingPathComponent("Unity.app", isDirectory: true)
        )
        return candidates.first { candidate in
            guard let bundle = Bundle(url: candidate),
                  let identifier = bundle.bundleIdentifier,
                  Self.isUnity(bundleIdentifier: identifier),
                  bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == version,
                  let executable = bundle.executableURL else {
                return false
            }
            return fileManager.isExecutableFile(atPath: executable.path)
        }
    }

    static func projectPaths(arguments: [String]) -> [String] {
        arguments.indices.compactMap { index in
            guard ["-projectpath", "-createproject"].contains(arguments[index].lowercased()),
                  arguments.indices.contains(index + 1),
                  !arguments[index + 1].isEmpty,
                  !arguments[index + 1].hasPrefix("-") else {
                return nil
            }
            return arguments[index + 1]
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

}
