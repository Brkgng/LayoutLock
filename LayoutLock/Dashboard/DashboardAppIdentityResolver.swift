import AppKit
import SwiftUI

struct DashboardAppIdentity {
    let bundleIdentifier: String
    let name: String
    let icon: NSImage
    let accentColor: Color
}

final class DashboardAppIdentityResolver {
    static let shared = DashboardAppIdentityResolver()

    private let workspace: NSWorkspace
    private var cache: [String: DashboardAppIdentity] = [:]

    init(workspace: NSWorkspace = .shared) {
        self.workspace = workspace
    }

    func identity(for bundleIdentifier: String) -> DashboardAppIdentity {
        if let cachedIdentity = cache[bundleIdentifier] {
            return cachedIdentity
        }

        let identity = makeIdentity(for: bundleIdentifier)
        cache[bundleIdentifier] = identity
        return identity
    }

    private func makeIdentity(for bundleIdentifier: String) -> DashboardAppIdentity {
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return DashboardAppIdentity(
                bundleIdentifier: bundleIdentifier,
                name: bundleIdentifier,
                icon: workspace.icon(forFileType: "app"),
                accentColor: Self.accentColor(for: bundleIdentifier)
            )
        }

        return DashboardAppIdentity(
            bundleIdentifier: bundleIdentifier,
            name: Self.appName(at: appURL) ?? bundleIdentifier,
            icon: workspace.icon(forFile: appURL.path),
            accentColor: Self.accentColor(for: bundleIdentifier)
        )
    }

    private static func appName(at appURL: URL) -> String? {
        let bundle = Bundle(url: appURL)
        let displayName = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        let bundleName = bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
        let fileName = appURL.deletingPathExtension().lastPathComponent

        return [displayName, bundleName, fileName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private static func accentColor(for bundleIdentifier: String) -> Color {
        var hash: UInt32 = 5381
        for scalar in bundleIdentifier.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ scalar.value
        }

        let hue = Double(hash % 360) / 360

        return Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [
                .darkAqua,
                .vibrantDark,
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastVibrantDark
            ]) != nil

            return NSColor(
                colorSpace: .sRGB,
                hue: CGFloat(hue),
                saturation: CGFloat(isDark ? 0.68 : 0.72),
                brightness: CGFloat(isDark ? 0.78 : 0.88),
                alpha: 1
            )
        })
    }
}
