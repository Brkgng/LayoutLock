import AppKit
import Foundation

extension NSWorkspace {
    func existingApplicationURL(withBundleIdentifier bundleIdentifier: String) -> URL? {
        guard let url = urlForApplication(withBundleIdentifier: bundleIdentifier),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }
}

extension Optional where Wrapped == String {
    var nonEmptyValue: String? {
        self?.nonEmptyValue
    }
}

extension String {
    var nonEmptyValue: String? {
        let trimmedValue = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}

extension Error {
    var userFacingDescription: String {
        let localizedDescription = (self as NSError).localizedDescription
        let genericMessages = [
            "The operation couldn’t be completed.",
            "The operation couldn't be completed."
        ]

        if localizedDescription.isEmpty || genericMessages.contains(localizedDescription) {
            return String(describing: self)
        }

        return localizedDescription
    }
}
