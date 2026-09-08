import AppKit
import BridgeCore
import Foundation
import Observation
import SwiftUI

/// Everything the menu bar and windows read from, and the only place that
/// coordinates the server, the profile store, and Claude Desktop's config.
@MainActor
@Observable
final class AppState {

    // MARK: - Persisted state

    var settings: BridgeSettings {
        didSet { scheduleSave() }
    }

    // MARK: - Live state

    private(set) var serverRunning = false
    private(set) var serverError: String?
    private(set) var health: HealthChecker.Health = .unknown
    private(set) var claudeStatus: ClaudeDesktopConfig.Status
    /// Read from macOS rather than persisted, so the toggle cannot claim a
    /// setting the system has since revoked. Refreshed when the app becomes
    /// active, because the user can change it in System Settings while we run.
    private(set) var loginItemState: LoginItem.State = LoginItem.state
    private(set) var entries: [LogEntry] = []
    /// Set when a background action wants to say something in the menu.
    var notice: Notice?

    struct Notice: Identifiable, Equatable {
        enum Kind { case info, warning, error }
        let id = UUID()
        var kind: Kind
        var text: String
    }

    // MARK: - Collaborators

    private let store = ProfileStore()
    private let claudeConfig = ClaudeDesktopConfig()
    private let log: RequestLog
    private let router: BridgeRouter
    private let server: BridgeServer

    private var saveTask: Task<Void, Never>?
    private var logObservation: UUID?
    private var configWatch: DispatchSourceFileSystemObject?

    init() {
        let loaded = ProfileStore().load()
        self.settings = loaded
        self.claudeStatus = ClaudeDesktopConfig().status()

        let profile = loaded.activeProfile ?? Profile(name: "Empty")
        let log = RequestLog(capacity: loaded.logCapacity)
        self.log = log
        // No credential yet on purpose. Reading it can block on a keychain
        // authorisation prompt, and doing that here would stall the app before
        // it ever binds a port; `onLaunch` loads it off the main actor.
        self.router = BridgeRouter(
            profile: profile, apiKey: nil, token: loaded.gatewayToken, log: log
        )
        self.server = BridgeServer(router: router)

        observeLog()

        // Not a `.task` on any view: the menu bar app has no window open at
        // launch, so a view-attached task would leave the bridge stopped until
        // the user opened Settings.
        Task { await onLaunch() }
    }

    // MARK: - Lifecycle

    func onLaunch() async {
        // Bind first. Loading the backend credential can sit behind a keychain
        // authorisation prompt the user may never answer, and the bridge being
        // up matters more than it having a credential the instant it starts —
        // a request made in the gap fails visibly in the log.
        if settings.startServerAtLaunch {
            await startServer()
        }
        await pushProfileToRouter()
        // Reconcile the active profile's models with what its backend currently
        // serves on every launch, so repointing a profile at a new backend (or
        // bringing one back up) prunes the old one's models instead of leaving
        // them in the picker forever. This is what keeps a profile honest after
        // its base URL changes: without it, only profiles with an empty model list
        // ever auto-populate. An unreachable backend at launch is a no-op, so it
        // just waits until the next time one is up. Skipped when discovery is off.
        if let profile = settings.activeProfile, profile.autoDiscoverModels {
            await discoverModels(for: profile.id)
        }
        await refreshHealth()
        watchClaudeConfig()
        refreshLoginItemState()
    }

    func onQuit() async {
        configWatch?.cancel()
        configWatch = nil
        await server.shutdown()
        try? store.save(settings)
    }

    // MARK: - Watching Claude Desktop's config

    /// Keeps `claudeStatus` in step with the config library on disk.
    ///
    /// Claude Desktop rewrites that directory whenever the user adds, renames
    /// or deletes a configuration, and the bridge's own menu reads it. Without
    /// this the status is whatever it was when the app launched, so a
    /// configuration deleted in Claude Desktop went on being offered in our
    /// menu — and picking it wrote an `appliedId` pointing at a file that no
    /// longer exists.
    private func watchClaudeConfig() {
        configWatch?.cancel()

        let directory = claudeConfig.configDirectory
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            // Entries are written as a temporary file and renamed, so adding or
            // removing one shows up as a write on the directory.
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                let events = source.data
                self.refreshClaudeStatus()
                // The directory itself was replaced, so this descriptor now
                // points at something no one will write to again.
                if events.contains(.delete) || events.contains(.rename) {
                    self.watchClaudeConfig()
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        configWatch = source
    }

    // MARK: - Server

    func startServer() async {
        serverError = nil
        do {
            try await server.start(port: settings.port)
            serverRunning = true
        } catch {
            serverRunning = false
            serverError = error.localizedDescription
        }
    }

    func stopServer() async {
        try? await server.stop()
        serverRunning = false
    }

    func toggleServer() async {
        if serverRunning { await stopServer() } else { await startServer() }
    }

    /// Applies a port change, which needs a rebind and a rewrite of Claude
    /// Desktop's config if the bridge is currently wired up.
    func applyPortChange(to port: UInt16) async {
        settings.port = port
        if serverRunning {
            await startServer()
        }
        if claudeStatus.bridgeEntryApplied {
            connectClaudeDesktop(announce: false)
        }
    }

    // MARK: - Profiles

    var activeProfile: Profile? { settings.activeProfile }

    func selectProfile(_ profile: Profile) async {
        settings.activeProfileID = profile.id
        await pushProfileToRouter()
        await refreshHealth()
        // The model picker is populated once, when Claude Desktop launches, so
        // a profile switch is not visible in it until the app restarts.
        if claudeStatus.bridgeEntryApplied, claudeConfig.isClaudeRunning() {
            notice = Notice(
                kind: .info,
                text: "Switched to “\(profile.name)”. Restart Claude Desktop to refresh its model list."
            )
        }
    }

    func upsert(profile: Profile) {
        if let index = settings.profiles.firstIndex(where: { $0.id == profile.id }) {
            settings.profiles[index] = profile
        } else {
            settings.profiles.append(profile)
        }
        Task {
            await pushProfileToRouter()
            await refreshHealth()
        }
    }

    func delete(profile: Profile) {
        if let account = profile.backend.keychainAccount {
            Task { try? await Keychain.remove(account: account) }
        }
        settings.profiles.removeAll { $0.id == profile.id }
        if settings.activeProfileID == profile.id {
            settings.activeProfileID = settings.profiles.first?.id
            Task { await pushProfileToRouter() }
        }
    }

    func duplicate(profile: Profile) {
        var copy = profile
        copy.id = UUID()
        copy.name = profile.name + " copy"
        // A duplicate must not share the original's keychain item, or deleting
        // one would pull the key out from under the other.
        if let source = profile.backend.keychainAccount {
            let account = UUID().uuidString
            copy.backend.keychainAccount = account
            Task {
                if let secret = await Keychain.get(account: source) {
                    try? await Keychain.set(secret, account: account)
                }
            }
        }
        copy.models = profile.models.map { model in
            var m = model
            m.id = UUID()
            return m
        }
        settings.profiles.append(copy)
    }

    /// Removes a profile's stored credential and its keychain slot.
    func forgetStoredKey(for profileID: UUID) {
        guard let index = settings.profiles.firstIndex(where: { $0.id == profileID }),
              let account = settings.profiles[index].backend.keychainAccount else { return }
        settings.profiles[index].backend.keychainAccount = nil
        Task {
            try? await Keychain.remove(account: account)
            await pushProfileToRouter()
        }
    }

    private func pushProfileToRouter() async {
        guard let profile = settings.activeProfile else { return }
        let key = await apiKey(for: profile)
        await router.update(profile: profile, apiKey: key, token: settings.gatewayToken)
    }

    // MARK: - Health and discovery

    func refreshHealth() async {
        guard let profile = settings.activeProfile else {
            health = .unknown
            return
        }
        health = .checking
        health = await HealthChecker.check(backend: profile.backend, apiKey: await apiKey(for: profile))
    }

    func health(of profile: Profile) async -> HealthChecker.Health {
        await HealthChecker.check(backend: profile.backend, apiKey: await apiKey(for: profile))
    }

    /// The backend credential, or nil when the profile does not use one.
    ///
    /// The auth scheme is checked before the keychain is touched. A profile
    /// that once had a key and was later switched to no-auth still carries the
    /// keychain account, and reading it would put up an authorisation prompt to
    /// fetch a secret that is then never sent anywhere — which is exactly what
    /// a local Ollama or LM Studio profile looks like after being pointed at a
    /// keyed backend for a while.
    private func apiKey(for profile: Profile) async -> String? {
        guard profile.backend.authScheme != .none,
              let account = profile.backend.keychainAccount else { return nil }
        return await Keychain.get(account: account)
    }

    /// What a discovery pass found.
    struct DiscoveryResult: Equatable {
        var added: Int = 0
        /// Entries discovery had added and the backend has stopped listing.
        /// Already gone from the profile by the time this is returned.
        var removed: [String] = []
        /// Hand-added entries the backend does not list. Kept, and reported so
        /// the editor can flag them: a backend with no `/v1/models` endpoint
        /// legitimately lists nothing while its models still work.
        var unavailable: [String] = []
        var failed = false
    }

    /// Models the active backend confirmed it serves, keyed by profile.
    /// Populated by discovery and used to flag stale rows in the editor.
    private(set) var servedModelIDs: [UUID: Set<String>] = [:]

    func servedModels(for profileID: UUID) -> Set<String>? { servedModelIDs[profileID] }

    /// Reconciles the profile's model list with what the backend reports.
    ///
    /// Adds anything new, keeps existing entries' tier and label, and records
    /// which configured models the backend did not list — which is how a
    /// profile whose URL was changed ends up advertising the old backend's
    /// models to Claude Desktop.
    @discardableResult
    func discoverModels(for profileID: UUID) async -> DiscoveryResult {
        guard let index = settings.profiles.firstIndex(where: { $0.id == profileID }) else {
            return DiscoveryResult(failed: true)
        }
        let profile = settings.profiles[index]
        let key = await apiKey(for: profile)

        let discovered = (try? await ModelCatalog.discover(backend: profile.backend, apiKey: key)) ?? []
        guard !discovered.isEmpty else {
            // Unreachable, or a backend that does not implement the endpoint.
            // Either way the existing list is the best information available,
            // so nothing is flagged.
            servedModelIDs[profileID] = nil
            return DiscoveryResult(failed: true)
        }

        let reconciled = ModelCatalog.reconcile(
            existing: settings.profiles[index].models,
            discovered: discovered
        )
        settings.profiles[index].models = reconciled.models
        servedModelIDs[profileID] = Set(discovered.map(\.id))

        let result = DiscoveryResult(
            added: reconciled.added,
            removed: reconciled.removed,
            unavailable: reconciled.unavailable
        )
        if settings.activeProfileID == profileID || settings.activeProfileID == nil {
            await pushProfileToRouter()
        }
        return result
    }

    /// Drops the hand-added models the backend does not list.
    ///
    /// Discovery removes what it added itself; this covers entries the user
    /// typed, which are kept by default because some backends serve models
    /// their `/v1/models` never mentions.
    func removeUnavailableModels(for profileID: UUID) {
        guard let index = settings.profiles.firstIndex(where: { $0.id == profileID }),
              let served = servedModelIDs[profileID] else { return }

        var models = settings.profiles[index].models
        models.removeAll { !$0.upstreamID.isEmpty && !served.contains($0.upstreamID) }
        settings.profiles[index].models = ModelCatalog.withFamilyDefaults(models)
        Task { await pushProfileToRouter() }
    }

    /// Records what a backend serves without altering the profile.
    ///
    /// Used when a profile is merely opened: the editor needs the list to
    /// offer it as a dropdown, but opening a profile should not quietly
    /// rewrite its models.
    func refreshServedModels(for profileID: UUID) async {
        guard let profile = settings.profiles.first(where: { $0.id == profileID }) else { return }
        let key = await apiKey(for: profile)
        let discovered = (try? await ModelCatalog.discover(backend: profile.backend, apiKey: key)) ?? []
        guard !discovered.isEmpty else { return }
        servedModelIDs[profileID] = Set(discovered.map(\.id))
    }

    /// Forgets what a backend was last known to serve.
    ///
    /// Called when the base URL or protocol changes: the recorded set belongs
    /// to the old backend, and keeping it would flag exactly the wrong rows.
    func invalidateDiscovery(for profileID: UUID) {
        servedModelIDs[profileID] = nil
    }

    // MARK: - Launch at login

    func refreshLoginItemState() {
        loginItemState = LoginItem.state
    }

    /// Turns launch-at-login on or off, then re-reads what macOS actually did.
    ///
    /// Registering while the user has revoked approval succeeds and still
    /// leaves the item switched off, so the result is reported from `status`
    /// rather than assumed from the call returning.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            refreshLoginItemState()

            if loginItemState == .requiresApproval {
                notice = Notice(kind: .warning, text: """
                    macOS is holding this back. Allow “Claude Bridge” under Login Items \
                    in System Settings for it to start automatically.
                    """)
            }
        } catch {
            refreshLoginItemState()
            notice = Notice(
                kind: .error,
                text: "Could not change launch at login: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Claude Desktop wiring

    func refreshClaudeStatus() {
        claudeStatus = claudeConfig.status()
    }

    /// Points Claude Desktop at the bridge.
    func connectClaudeDesktop(announce: Bool = true) {
        do {
            try claudeConfig.applyBridgeEntry(
                port: settings.port, apiKey: settings.gatewayToken
            )
            refreshClaudeStatus()

            if claudeStatus.managedProfilePresent {
                notice = Notice(kind: .warning, text: """
                    Written, but this Mac has an MDM configuration profile for Claude Desktop, \
                    which takes precedence. The bridge will not be used until that profile is removed.
                    """)
            } else if announce {
                notice = Notice(kind: .info, text: "Claude Desktop is pointed at the bridge. Restart it to take effect.")
            }
        } catch {
            notice = Notice(kind: .error, text: error.localizedDescription)
        }
    }

    /// Configurations the user can send Claude Desktop back to.
    var restorableEntries: [ClaudeDesktopConfig.ConfigEntry] {
        claudeStatus.restorableEntries
    }

    /// Somewhere Claude Desktop can send inference, as the user thinks of it.
    ///
    /// A profile is a destination in its own right: picking one means "use that
    /// backend", and whether the bridge is already applied is plumbing the user
    /// should not have to think about.
    enum Destination: Equatable {
        case anthropicModels
        case bridge(Profile)
        case otherEntry(ClaudeDesktopConfig.ConfigEntry)

        var name: String {
            switch self {
            case .anthropicModels: return "Anthropic's models"
            case .bridge(let profile): return profile.name
            case .otherEntry(let entry): return entry.name
            }
        }
    }

    /// Everywhere Claude Desktop could be pointed, in the order the menu shows.
    var destinations: [Destination] {
        [.anthropicModels]
            + settings.profiles.map(Destination.bridge)
            + restorableEntries.map(Destination.otherEntry)
    }

    func isCurrent(_ destination: Destination) -> Bool {
        switch destination {
        case .anthropicModels:
            return claudeStatus.usingAnthropicModels
        case .bridge(let profile):
            return claudeStatus.bridgeEntryApplied && activeProfile?.id == profile.id
        case .otherEntry(let entry):
            return claudeStatus.appliedEntryName == entry.name
        }
    }

    /// Performs a switch end to end: select the profile behind it, point Claude
    /// Desktop at the right place, and restart it so the change takes effect.
    ///
    /// Doing all three from one click is the point. Separately these were three
    /// trips through the menu for what the user experiences as a single choice,
    /// and forgetting the restart left Claude Desktop showing the old models
    /// with no hint why.
    func switchClaudeDesktop(to destination: Destination, restart: Bool) async {
        switch destination {
        case .anthropicModels:
            useAnthropicModels()
        case .bridge(let profile):
            if activeProfile?.id != profile.id {
                await selectProfile(profile)
            }
            connectClaudeDesktop(announce: false)
        case .otherEntry(let entry):
            useClaudeDesktopEntry(entry)
        }

        // A failed switch leaves a notice explaining why; restarting on top of
        // it would only replace that with a misleading success.
        guard notice?.kind != .error else { return }

        if restart, claudeConfig.isClaudeRunning() {
            await restartClaudeDesktop()
            notice = Notice(kind: .info, text: "Claude Desktop is now using \(destination.name).")
        } else {
            notice = Notice(
                kind: .info,
                text: "Claude Desktop is set to \(destination.name). Restart it to take effect."
            )
        }
    }

    /// Takes Claude Desktop off the bridge and back to Anthropic's own models.
    func useAnthropicModels() {
        do {
            try claudeConfig.applyAnthropicModels()
            refreshClaudeStatus()
            notice = Notice(kind: .info, text: "Claude Desktop is back on Anthropic's models. Restart it to take effect.")
        } catch {
            notice = Notice(kind: .error, text: error.localizedDescription)
        }
    }

    /// Points Claude Desktop at a named entry the user chose, for when the
    /// bridge has no remembered entry to fall back to or the user wants a
    /// different one than the one it displaced.
    func useClaudeDesktopEntry(_ entry: ClaudeDesktopConfig.ConfigEntry) {
        do {
            try claudeConfig.applyEntry(id: entry.id)
            refreshClaudeStatus()
            notice = Notice(kind: .info, text: "Claude Desktop is now using \(entry.name). Restart it to take effect.")
        } catch {
            notice = Notice(kind: .error, text: error.localizedDescription)
        }
    }

    /// Quits and reopens Claude Desktop. Destructive enough to confirm first,
    /// which the caller does.
    func restartClaudeDesktop() async {
        do {
            try await claudeConfig.restartClaudeDesktop()
            refreshClaudeStatus()
        } catch {
            notice = Notice(kind: .error, text: "Could not restart Claude Desktop: \(error.localizedDescription)")
        }
    }

    var claudeDesktopIsRunning: Bool { claudeConfig.isClaudeRunning() }

    // MARK: - Log

    private func observeLog() {
        Task { [log] in
            let token = await log.observe { snapshot in
                Task { @MainActor [weak self] in self?.entries = snapshot }
            }
            await MainActor.run { self.logObservation = token }
        }
    }

    func clearLog() {
        Task { await log.clear() }
    }

    var captureBodies = false {
        didSet {
            let value = captureBodies
            Task { [log] in await log.setCaptureBodies(value) }
        }
    }

    // MARK: - Saving

    /// Debounced: the settings object is rewritten on every keystroke in the
    /// editor, and each write is an atomic file replace.
    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = settings
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            try? store.save(snapshot)
            await pushProfileToRouter()
        }
    }

    // MARK: - Derived display

    enum ConnectionState {
        case stopped
        case running
        case failing

        var symbolName: String {
            switch self {
            case .stopped: return "bolt.horizontal"
            case .running: return "bolt.horizontal.fill"
            case .failing: return "bolt.horizontal.circle"
            }
        }
    }

    var connectionState: ConnectionState {
        guard serverRunning else { return .stopped }
        if case .unreachable = health { return .failing }
        if serverError != nil { return .failing }
        return .running
    }

    var statusSummary: String {
        guard serverRunning else { return serverError ?? "Bridge stopped" }
        guard let profile = activeProfile else { return "No profile" }
        return "\(profile.name) · \(health.summary)"
    }
}
