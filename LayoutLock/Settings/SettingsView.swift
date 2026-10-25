import AppKit
import SwiftUI

enum LayoutLockSupport {
    static let emailAddress = "support@layoutlock.app"
    static let privacyPolicyURL = URL(string: "https://layoutlock.app/privacy")!
    static let termsOfServiceURL = URL(string: "https://layoutlock.app/terms")!
    static let raycastURL = URL(string: "https://layoutlock.app/raycast")!
    static let supportEmailBody = "\n\n"
    static let refundEmailSubject = "LayoutLock Refund Request"
    static let refundEmailBody = "Purchase email or Creem order ID:\n\n"

    static func mailtoURL(subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = emailAddress
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "body", value: body)
        ]
        return components.url
    }
}

enum SettingsTab: Hashable {
    case general
    case integrations
    case pro
    case diagnostics
    case about
}

@MainActor
final class SettingsNavigationController: ObservableObject {
    @Published var selectedTab: SettingsTab = .general

    func showPro() {
        selectedTab = .pro
    }
}

struct SettingsView: View {
    @ObservedObject var launchAtLoginController: LaunchAtLoginController
    @ObservedObject var permissionCoordinator: PermissionCoordinator
    @ObservedObject var browserAutomationController: BrowserAutomationController
    let diagnosticLogController: DiagnosticLogController?
    @ObservedObject var entitlementController: EntitlementController
    @ObservedObject var settingsNavigationController: SettingsNavigationController
    @ObservedObject var updateController: AppUpdateController
    @ObservedObject var raycastRecommendationController: RaycastRecommendationController

    @AppStorage(LayoutLockSettings.suggestRestoreOnDisplayChangeKey)
    private var suggestRestoreOnDisplayChange = true
    @AppStorage(LayoutLockSettings.appearancePreferenceKey)
    private var appearancePreference = AppearancePreference.default
    @AppStorage(LayoutLockSettings.showsDockIconKey)
    private var showsDockIcon = false
    @State private var diagnosticLogStatus: DiagnosticLogStatus?
    @State private var hasDiagnosticLog = false
    @State private var licenseKey = ""
    @State private var isLicenseKeyVisible = false
    @State private var proActionMessage: String?
    @State private var isShowingDeactivationConfirmation = false
    @State private var browserInfo: BrowserAutomationBrowser?
    @State private var isRaycastInstalled = false

    var body: some View {
        TabView(selection: $settingsNavigationController.selectedTab) {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            integrationsTab
                .tabItem {
                    Label("Integrations", systemImage: "puzzlepiece.extension")
                }
                .tag(SettingsTab.integrations)

            proTab
                .tabItem {
                    Label("Pro", systemImage: "sparkles")
                }
                .tag(SettingsTab.pro)

            diagnosticsTab
                .tabItem {
                    Label("Diagnostics", systemImage: "wrench.and.screwdriver")
                }
                .tag(SettingsTab.diagnostics)

            aboutTab
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
                .tag(SettingsTab.about)
        }
        .frame(width: 560, height: 460)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .navigationTitle("Settings")
        .onAppear {
            launchAtLoginController.refreshStatus()
            permissionCoordinator.refreshTrust(trigger: .manualCheckAgain)
            browserAutomationController.refresh()
            refreshRaycastAvailability()
            refreshDiagnosticLogAvailability()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLoginController.refreshStatus()
            refreshRaycastAvailability()
        }
        .onChange(of: settingsNavigationController.selectedTab) { _, selectedTab in
            if selectedTab == .diagnostics {
                diagnosticLogStatus = nil
                refreshDiagnosticLogAvailability()
            }
        }
        .onChange(of: appearancePreference) { _, newValue in
            NSApp.appearance = newValue.nsAppearance
        }
        .onChange(of: showsDockIcon) { _, newValue in
            NSApp.setActivationPolicy(LayoutLockSettings.dockActivationPolicy(showsDockIcon: newValue))
        }
        .confirmationDialog(
            "Deactivate Pro on This Mac?",
            isPresented: $isShowingDeactivationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Deactivate Pro", role: .destructive) {
                deactivateLicense()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("LayoutLock will return to the Free plan on this Mac. You can then activate the license on another Mac.")
        }
    }

    private var generalTab: some View {
        Form {
            Section {
                SettingsValueRow(
                    title: "Launch at Login:",
                    systemImage: "power",
                    value: nil
                ) {
                    Toggle("", isOn: launchAtLoginBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!launchAtLoginController.state.canToggle)
                }

                if let message = launchAtLoginController.state.message {
                    SettingsStatusRow(
                        message: message,
                        systemImage: launchAtLoginStatusIcon,
                        tint: launchAtLoginStatusTint
                    )
                }

                if launchAtLoginController.state.requiresApproval {
                    SettingsActionRow(
                        title: "Open Login Items Settings",
                        systemImage: "arrow.up.forward",
                        action: launchAtLoginController.openLoginItemsSettings
                    )
                } else if launchAtLoginController.state.isError {
                    SettingsActionRow(
                        title: "Retry Launch at Login",
                        systemImage: "arrow.clockwise",
                        action: launchAtLoginController.refreshStatus
                    )
                }
            }

            Section {
                SettingsValueRow(
                    title: "Appearance:",
                    systemImage: "circle.lefthalf.filled",
                    value: nil
                ) {
                    Picker("", selection: $appearancePreference) {
                        ForEach(AppearancePreference.allCases, id: \.self) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }
            }

            Section {
                SettingsValueRow(
                    title: "Show in Dock:",
                    systemImage: "dock.rectangle",
                    value: nil
                ) {
                    Toggle("", isOn: $showsDockIcon)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            Section {
                SettingsValueRow(
                    title: "Suggest Layouts When Displays Change:",
                    systemImage: "display.2",
                    value: nil
                ) {
                    Toggle("", isOn: displayChangeSuggestionsBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(!entitlementController.isProUnlocked)
                }

                if !entitlementController.isProUnlocked {
                    SettingsStatusRow(
                        message: ProFeature.displayChangeSuggestions.requiredPlanMessage,
                        systemImage: "sparkles",
                        tint: .secondary
                    )
                }
            }

            if permissionCoordinator.authorizationState == .unauthorized {
                Section {
                    SettingsValueRow(
                        title: "Accessibility Access:",
                        systemImage: "hand.raised.fill",
                        value: "Missing",
                        valueTint: .orange
                    )

                    SettingsActionRow(
                        title: "Open System Settings",
                        systemImage: "arrow.up.forward",
                        action: permissionCoordinator.openAccessibilitySettings
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    private var integrationsTab: some View {
        Form {
            Section {
                Text("Save Safari and Chrome tabs with layouts.")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(BrowserAutomationBrowser.allCases) { browser in
                    browserAutomationRow(for: browser)
                }
            } header: {
                Text("Browsers")
            } footer: {
                Text("macOS asks for Automation access only when you click Connect.")
            }

            Section {
                HStack(spacing: 12) {
                    Image(systemName: "command")
                        .font(.title2)
                        .foregroundStyle(.blue)
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Raycast")
                            .fontWeight(.medium)
                        Text(isRaycastInstalled ? "Raycast is installed on this Mac" : "Install Raycast to use the extension")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Get Extension") {
                        raycastRecommendationController.extensionSetupRequested()
                        NSWorkspace.shared.open(LayoutLockSupport.raycastURL)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Raycast")
            } footer: {
                Text("Raycast asks you to confirm extension installation. LayoutLock cannot detect whether the extension itself is installed.")
            }
        }
        .formStyle(.grouped)
        .popover(item: $browserInfo) { browser in
            VStack(alignment: .leading, spacing: 8) {
                Text(browser.displayName)
                    .font(.headline)
                Text(browserPrivacyDescription(for: browser))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Captured tab titles and URLs stay in the layout on this Mac.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Restore creates separate windows for saved tab groups.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Tabs already open stay in their current window.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(width: 300, alignment: .leading)
        }
    }

    private func refreshRaycastAvailability() {
        isRaycastInstalled = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.raycast.macos"
        ) != nil
    }

    @ViewBuilder
    private func browserAutomationRow(
        for browser: BrowserAutomationBrowser
    ) -> some View {
        let status = browserAutomationController.status(for: browser)

        HStack(spacing: 12) {
            Image(nsImage: browserIcon(for: browser))
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(browser.displayName)
                        .fontWeight(.medium)

                    Button {
                        browserInfo = browser
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("About \(browser.displayName) integration")
                    .accessibilityLabel("About \(browser.displayName) Integration")
                }

                Text(browserStatusDescription(status))
                    .font(.caption)
                    .foregroundStyle(browserAutomationTint(for: status.connectionState))

            }

            Spacer()

            if status.isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Connecting \(browser.displayName)")
            } else {
                browserAutomationActions(for: browser, status: status)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func browserAutomationActions(
        for browser: BrowserAutomationBrowser,
        status: BrowserAutomationStatus
    ) -> some View {
        switch status.connectionState {
        case .notInstalled:
            EmptyView()
        case .notConnected:
            Button("Connect") {
                browserAutomationController.connect(browser)
            }
            .disabled(!status.canConnect)
            .accessibilityLabel("Connect \(browser.displayName)")
        case .connected:
            Button("Disconnect") {
                browserAutomationController.disconnect(browser)
            }
            .disabled(!status.canDisconnect)
            .accessibilityLabel("Disconnect \(browser.displayName)")
        case .permissionDenied, .revoked:
            HStack(spacing: 8) {
                Button("Disconnect") {
                    browserAutomationController.disconnect(browser)
                }
                Button("Open Settings") {
                    browserAutomationController.openAutomationSettings()
                }
                .accessibilityLabel("Open Automation Settings")
            }
        }
    }

    private func browserStatusDescription(_ status: BrowserAutomationStatus) -> String {
        if status.isWorking {
            return "Waiting for macOS…"
        }
        if status.connectionState == .notConnected, !status.isRunning {
            return "Open the browser to connect"
        }
        return status.connectionState.title
    }

    private func browserPrivacyDescription(
        for browser: BrowserAutomationBrowser
    ) -> String {
        switch browser {
        case .safari:
            return "Safari may include private tabs because it cannot reliably identify private windows."
        case .chrome:
            return "Chrome incognito windows are not captured."
        }
    }

    private func browserIcon(for browser: BrowserAutomationBrowser) -> NSImage {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: browser.bundleIdentifier
        ) else {
            return NSImage(
                systemSymbolName: browser.systemImage,
                accessibilityDescription: browser.displayName
            ) ?? NSImage()
        }
        return NSWorkspace.shared.icon(forFile: applicationURL.path)
    }

    private func browserAutomationTint(
        for state: BrowserAutomationConnectionState
    ) -> Color {
        switch state {
        case .connected:
            return .green
        case .permissionDenied, .revoked:
            return .orange
        case .notConnected, .notInstalled:
            return .secondary
        }
    }

    private var proTab: some View {
        Form {
            Section {
                SettingsValueRow(
                    title: "Plan:",
                    systemImage: entitlementController.isProUnlocked ? "checkmark.seal.fill" : "sparkles",
                    value: entitlementController.isProUnlocked ? "Pro" : "Free",
                    valueTint: entitlementController.isProUnlocked ? .green : .secondary
                )

                if entitlementController.isProUnlocked,
                   let lastValidatedAt = entitlementController.entitlementState.lastValidatedAt {
                    SettingsValueRow(
                        title: "Last Validated:",
                        systemImage: "clock",
                        value: validationDateFormatter.string(from: lastValidatedAt)
                    )
                }

                if entitlementController.isProUnlocked,
                   !entitlementController.requiresLicenseKeyEntry,
                   let message = proStatusMessage {
                    SettingsStatusRow(
                        message: message,
                        systemImage: proStatusIcon,
                        tint: proStatusTint
                    )
                }
            }

            if !entitlementController.isProUnlocked {
                Section {
                    if let testModeMessage = LayoutLockProConfiguration.current.testModeMessage {
                        SettingsStatusRow(
                            message: testModeMessage,
                            systemImage: "testtube.2",
                            tint: .orange
                        )
                    }

                    SettingsActionRow(
                        title: LayoutLockProConfiguration.current.purchaseActionTitle,
                        systemImage: "arrow.up.forward",
                        leadingSystemImage: "cart",
                        action: openProPurchase,
                        isDisabled: LayoutLockProConfiguration.purchaseURL == nil
                    )

                    if LayoutLockProConfiguration.purchaseURL == nil {
                        Text("Purchases are unavailable in this build.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Includes a 14-day money-back guarantee.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !entitlementController.isProUnlocked || entitlementController.requiresLicenseKeyEntry {
                Section {
                    HStack(spacing: 8) {
                        Group {
                            if isLicenseKeyVisible {
                                TextField("License key", text: $licenseKey)
                            } else {
                                SecureField("License key", text: $licenseKey)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                        .disabled(entitlementController.isWorking)

                        Button {
                            isLicenseKeyVisible.toggle()
                        } label: {
                            Image(systemName: isLicenseKeyVisible ? "eye.slash" : "eye")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.borderless)
                        .disabled(entitlementController.isWorking)
                        .accessibilityLabel(isLicenseKeyVisible ? "Hide license key" : "Show license key")
                        .help(isLicenseKeyVisible ? "Hide License Key" : "Show License Key")
                    }

                    HStack {
                        Group {
                            if entitlementController.isProUnlocked {
                                Button {
                                    validateLicense()
                                } label: {
                                    Label("Retry License", systemImage: "arrow.clockwise")
                                }
                            } else {
                                Button {
                                    activateLicense()
                                } label: {
                                    Label("Activate Pro", systemImage: "checkmark.seal")
                                }
                            }
                        }
                        .disabled(
                            entitlementController.isWorking ||
                                licenseKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )

                        if entitlementController.isWorking {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    if let message = proStatusMessage {
                        SettingsStatusRow(
                            message: message,
                            systemImage: proStatusIcon,
                            tint: proStatusTint
                        )
                    }
                }
            }

            if entitlementController.isProUnlocked {
                Section {
                    SettingsActionRow(
                        title: "Deactivate Pro on This Mac…",
                        systemImage: "chevron.right",
                        leadingSystemImage: "minus.circle",
                        action: { isShowingDeactivationConfirmation = true },
                        isDisabled: entitlementController.isWorking
                    )
                }
            }

            Section {
                SettingsActionRow(
                    title: "Request a Refund…",
                    systemImage: "arrow.up.forward",
                    leadingSystemImage: "envelope",
                    action: openRefundEmail
                )

                Text("Request a full refund within 14 days of purchase. No reason required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        Form {
            VStack(spacing: 8) {
                Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 64, height: 64)

                Text(appName)
                    .font(.title2.bold())

                if let versionText {
                    Text(versionText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 16)
            .padding(.bottom, 8)

            Section {
                SettingsActionRow(
                    title: updateController.actionTitle,
                    systemImage: "chevron.right",
                    leadingSystemImage: "arrow.down.circle",
                    action: updateController.checkForUpdates,
                    isDisabled: !updateController.canCheckForUpdates
                )

                SettingsActionRow(
                    title: "Contact Support",
                    systemImage: "arrow.up.forward",
                    leadingSystemImage: "envelope",
                    action: openSupportEmail
                )
                .help(LayoutLockSupport.emailAddress)

                Text("A local diagnostic log is attached when available.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SettingsActionRow(
                    title: "Privacy Policy",
                    systemImage: "arrow.up.forward",
                    leadingSystemImage: "hand.raised",
                    action: openPrivacyPolicy
                )

                SettingsActionRow(
                    title: "Terms of Service",
                    systemImage: "arrow.up.forward",
                    leadingSystemImage: "doc.text",
                    action: openTermsOfService
                )
            }
        }
        .formStyle(.grouped)
    }

    private var diagnosticsTab: some View {
        Form {
            Section {
                Text(
                    "LayoutLock stores diagnostic logs locally on this Mac to help troubleshoot layout capture and restore issues. Logs are never uploaded automatically. Entries older than 7 days are removed, and the log file is capped at 5 MiB."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if diagnosticLogController != nil {
                if !hasDiagnosticLog {
                    Section {
                        SettingsStatusRow(
                            message: "No diagnostic log has been created yet.",
                            systemImage: "info.circle",
                            tint: .secondary
                        )
                    }
                }

                Section {
                    SettingsActionRow(
                        title: "Reveal Diagnostic Log in Finder",
                        systemImage: "arrow.up.forward",
                        action: revealDiagnosticLog
                    )

                    SettingsActionRow(
                        title: "Export Diagnostic Log...",
                        systemImage: "square.and.arrow.up",
                        action: exportDiagnosticLog,
                        isDisabled: !hasDiagnosticLog
                    )

                    SettingsActionRow(
                        title: "Delete Diagnostic Log",
                        systemImage: "trash",
                        action: deleteDiagnosticLog,
                        isDisabled: !hasDiagnosticLog
                    )
                }
            } else {
                Section {
                    SettingsStatusRow(
                        message: "Diagnostic logs are unavailable because the app's support directory could not be prepared.",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }
            }

            if let diagnosticLogStatus {
                Section {
                    SettingsStatusRow(
                        message: diagnosticLogStatus.message,
                        systemImage: diagnosticLogStatus.systemImage,
                        tint: diagnosticLogStatus.tint
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginController.isEnabled },
            set: { launchAtLoginController.setEnabled($0) }
        )
    }

    private var displayChangeSuggestionsBinding: Binding<Bool> {
        Binding(
            get: {
                LayoutLockSettings.displayChangeSuggestionsAreEnabled(
                    preference: suggestRestoreOnDisplayChange,
                    isProUnlocked: entitlementController.isProUnlocked
                )
            },
            set: { suggestRestoreOnDisplayChange = $0 }
        )
    }

    private var launchAtLoginStatusTint: Color {
        if launchAtLoginController.state.isError && !launchAtLoginController.state.requiresApproval {
            return .red
        }

        if launchAtLoginController.state.requiresApproval {
            return .orange
        }

        return .secondary
    }

    private var launchAtLoginStatusIcon: String {
        if launchAtLoginController.state.isError && !launchAtLoginController.state.requiresApproval {
            return "exclamationmark.triangle.fill"
        }

        return "info.circle"
    }

    private var proStatusMessage: String? {
        entitlementController.entitlementState.statusMessage ?? proActionMessage
    }

    private var proStatusIcon: String {
        if entitlementController.isProUnlocked, proStatusMessage != nil {
            return "exclamationmark.triangle.fill"
        }

        switch entitlementController.entitlementState.status {
        case .active:
            return "checkmark.circle"
        case .inactive:
            return "xmark.circle.fill"
        case .free:
            return "info.circle"
        }
    }

    private var proStatusTint: Color {
        if entitlementController.isProUnlocked, proStatusMessage != nil {
            return .orange
        }

        switch entitlementController.entitlementState.status {
        case .active:
            return .green
        case .inactive:
            return .red
        case .free:
            return .secondary
        }
    }

    private var validationDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "LayoutLock"
    }

    private var versionNumber: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private var buildNumber: String? {
        Bundle.main.object(forInfoDictionaryKey: kCFBundleVersionKey as String) as? String
    }

    private var versionText: String? {
        guard let versionNumber else { return nil }
        guard let buildNumber else { return "Version \(versionNumber)" }
        return "Version \(versionNumber) (\(buildNumber))"
    }

    private var supportSubject: String {
        guard let versionNumber else {
            return "LayoutLock Feedback"
        }

        return "LayoutLock Feedback (v\(versionNumber))"
    }

    private func openSupportEmail() {
        if diagnosticLogController?.composeSupportEmail(
            to: LayoutLockSupport.emailAddress,
            subject: supportSubject,
            body: LayoutLockSupport.supportEmailBody
        ) == true {
            return
        }

        guard let url = LayoutLockSupport.mailtoURL(
            subject: supportSubject,
            body: LayoutLockSupport.supportEmailBody
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openRefundEmail() {
        guard let url = LayoutLockSupport.mailtoURL(
            subject: LayoutLockSupport.refundEmailSubject,
            body: LayoutLockSupport.refundEmailBody
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openPrivacyPolicy() {
        NSWorkspace.shared.open(LayoutLockSupport.privacyPolicyURL)
    }

    private func openTermsOfService() {
        NSWorkspace.shared.open(LayoutLockSupport.termsOfServiceURL)
    }

    private func openProPurchase() {
        guard let purchaseURL = LayoutLockProConfiguration.purchaseURL else {
            proActionMessage = "Pro purchase is not configured yet."
            return
        }

        NSWorkspace.shared.open(purchaseURL)
    }

    private func activateLicense() {
        proActionMessage = nil
        Task { @MainActor in
            await entitlementController.activate(licenseKey: licenseKey)
            if entitlementController.isProUnlocked, !entitlementController.requiresLicenseKeyEntry {
                licenseKey = ""
            }
        }
    }

    private func validateLicense() {
        proActionMessage = nil
        Task { @MainActor in
            await entitlementController.validateLicense(licenseKey: licenseKey)
            if entitlementController.isProUnlocked, !entitlementController.requiresLicenseKeyEntry {
                licenseKey = ""
            }
        }
    }

    private func deactivateLicense() {
        proActionMessage = nil
        Task { @MainActor in
            await entitlementController.deactivateLicense(licenseKey: licenseKey)
            if !entitlementController.isProUnlocked {
                licenseKey = ""
            }
        }
    }

    private func refreshDiagnosticLogAvailability() {
        hasDiagnosticLog = diagnosticLogController?.hasLog == true
    }

    private func revealDiagnosticLog() {
        diagnosticLogController?.revealInFinder()
        refreshDiagnosticLogAvailability()
    }

    private func exportDiagnosticLog() {
        guard let diagnosticLogController else { return }

        do {
            switch try diagnosticLogController.export() {
            case .exported:
                diagnosticLogStatus = DiagnosticLogStatus(
                    message: "Diagnostic log exported.",
                    systemImage: "checkmark.circle",
                    tint: .green
                )
            case .cancelled:
                break
            case .noLog:
                diagnosticLogStatus = DiagnosticLogStatus(
                    message: "No diagnostic log is available to export.",
                    systemImage: "info.circle",
                    tint: .secondary
                )
            }
        } catch {
            diagnosticLogStatus = DiagnosticLogStatus(
                message: "Diagnostic log could not be exported: \(error.localizedDescription)",
                systemImage: "exclamationmark.triangle.fill",
                tint: .red
            )
        }
        refreshDiagnosticLogAvailability()
    }

    private func deleteDiagnosticLog() {
        guard let diagnosticLogController else { return }

        do {
            try diagnosticLogController.clear()
            diagnosticLogStatus = DiagnosticLogStatus(
                message: "Diagnostic log deleted.",
                systemImage: "checkmark.circle",
                tint: .green
            )
        } catch {
            diagnosticLogStatus = DiagnosticLogStatus(
                message: "Diagnostic log could not be deleted: \(error.localizedDescription)",
                systemImage: "exclamationmark.triangle.fill",
                tint: .red
            )
        }
        refreshDiagnosticLogAvailability()
    }
}

private struct DiagnosticLogStatus {
    let message: String
    let systemImage: String
    let tint: Color
}

private struct SettingsValueRow<Trailing: View>: View {
    let title: String
    let systemImage: String
    let value: String?
    var valueTint: Color = .secondary
    @ViewBuilder var trailing: () -> Trailing

    init(
        title: String,
        systemImage: String,
        value: String?,
        valueTint: Color = .secondary,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.systemImage = systemImage
        self.value = value
        self.valueTint = valueTint
        self.trailing = trailing
    }

    init(
        title: String,
        systemImage: String,
        value: String?,
        valueTint: Color = .secondary
    ) where Trailing == EmptyView {
        self.init(
            title: title,
            systemImage: systemImage,
            value: value,
            valueTint: valueTint
        ) {
            EmptyView()
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            SettingsIcon(systemImage: systemImage)

            Text(title)
                .font(.body.weight(.semibold))

            Spacer()

            if let value {
                Text(value)
                    .foregroundStyle(valueTint)
            }

            trailing()
        }
    }
}

private struct SettingsActionRow: View {
    let title: String
    let systemImage: String
    var leadingSystemImage: String?
    let action: () -> Void
    var isDisabled = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let leadingSystemImage {
                    SettingsIcon(systemImage: leadingSystemImage)
                }

                Text(title)
                    .font(.body.weight(.semibold))

                Spacer()

                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

private struct SettingsStatusRow: View {
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.secondary)
            .frame(width: 18)
    }
}
