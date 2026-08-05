import AppKit

private let helperBundleIdentifierSuffix = ".login-helper"

guard let helperBundleIdentifier = Bundle.main.bundleIdentifier,
      helperBundleIdentifier.hasSuffix(helperBundleIdentifierSuffix) else {
    exit(EXIT_FAILURE)
}

let mainBundleIdentifier = String(
    helperBundleIdentifier.dropLast(helperBundleIdentifierSuffix.count)
)
guard NSRunningApplication.runningApplications(
    withBundleIdentifier: mainBundleIdentifier
).isEmpty else {
    exit(EXIT_SUCCESS)
}

let mainAppURL = Bundle.main.bundleURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

let configuration = NSWorkspace.OpenConfiguration()
configuration.arguments = ["--layoutlock-login-item"]
configuration.activates = false
configuration.addsToRecentItems = false
configuration.allowsRunningApplicationSubstitution = false

NSWorkspace.shared.openApplication(
    at: mainAppURL,
    configuration: configuration
) { application, error in
    if let error {
        NSLog("Unable to launch LayoutLock: \(error.localizedDescription)")
        exit(EXIT_FAILURE)
    }

    exit(application == nil ? EXIT_FAILURE : EXIT_SUCCESS)
}

RunLoop.main.run()
