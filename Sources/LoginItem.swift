import Foundation
import ServiceManagement

/// Launch at login. Primary: SMAppService.mainApp. This build is ad-hoc signed, so registration
/// can fail or stay in `.requiresApproval`; then a per-user LaunchAgent is written instead
/// (RunAtLoad, no KeepAlive: a crash at login must never turn into a relaunch loop).
/// Login launches go through the normal startup path, so the sentinel safe mode, the
/// "no overlays while locked/asleep" rule and the watchdog all apply.
enum LoginItem {
    static let agentLabel = "com.local.winterdesk"

    static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    enum Mechanism { case none, appService, launchAgent, pendingApproval }

    static let preferenceKey = "launchAtLogin"
    private static let registeredPathKey = "loginRegisteredFromPath"

    /// Only the copy installed in ~/Applications may touch login registration (a build/ or
    /// Downloads copy must never re-point the login item at itself).
    static var isInstalledCopy: Bool {
        let installed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return Bundle.main.bundlePath.hasPrefix(installed + "/")
    }

    /// Which mechanism is active right now (drives the menu checkmark).
    static var current: Mechanism {
        guard isInstalledCopy else { return .none }
        if SMAppService.mainApp.status == .enabled { return .appService }
        if agentIsOurs { return .launchAgent }
        if SMAppService.mainApp.status == .requiresApproval { return .pendingApproval }
        return .none
    }

    static var isEnabled: Bool { current == .appService || current == .launchAgent }

    /// True if the LaunchAgent plist exists and points at this app's executable.
    private static var agentIsOurs: Bool { agentProgram == Bundle.main.executablePath }

    private static var agentProgram: String? {
        guard let data = try? Data(contentsOf: agentURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let args = plist["ProgramArguments"] as? [String] else { return nil }
        return args.first
    }

    /// Enables launch at login for THIS (installed) copy. `repoint`: unregister first so the login
    /// item is re-pointed at this bundle even if another copy registered it. Returns a user-facing
    /// problem description, or nil on success.
    @discardableResult
    static func enable(repoint: Bool = false, defaults: UserDefaults = .standard) -> String? {
        guard isInstalledCopy else { return "설치된 앱에서만 설정 가능" }
        let svc = SMAppService.mainApp
        var smError: String?
        if repoint { try? svc.unregister() }
        do {
            if repoint || svc.status != .enabled { try svc.register() }
        } catch {
            smError = error.localizedDescription
        }
        if svc.status == .enabled {
            defaults.set(Bundle.main.bundlePath, forKey: registeredPathKey)
            removeAgent()   // never both
            return nil
        }
        // Not approved / failed: avoid a later double launch, then use the LaunchAgent with this
        // copy's executable (rewritten if it pointed anywhere else).
        try? svc.unregister()
        if let agentError = writeAgent() {
            return [smError, agentError].compactMap { $0 }.joined(separator: "\n")
        }
        defaults.set(Bundle.main.bundlePath, forKey: registeredPathKey)
        return nil
    }

    static func disable(defaults: UserDefaults = .standard) {
        guard isInstalledCopy else { return }
        try? SMAppService.mainApp.unregister()
        removeAgent()
        defaults.removeObject(forKey: registeredPathKey)
    }

    /// At launch of the installed copy: make the registration match the stored preference and
    /// point at this bundle. Re-points (unregister + register) only when the last registration
    /// came from another path; otherwise just repairs what is missing. Runs off the main thread.
    static func syncAtLaunch(defaults: UserDefaults, completion: (() -> Void)? = nil) {
        guard isInstalledCopy else { return }
        let wanted = defaults.bool(forKey: preferenceKey)
        let lastPath = defaults.string(forKey: registeredPathKey)
        DispatchQueue.global(qos: .utility).async {
            if wanted {
                let moved = lastPath != Bundle.main.bundlePath
                let agentWrong = FileManager.default.fileExists(atPath: agentURL.path) && !agentIsOurs
                if moved || agentWrong || !isEnabled {
                    if let problem = enable(repoint: moved, defaults: defaults) { NSLog("WinterDesk: launch at login: %@", problem) }
                }
            } else if isEnabled || lastPath != nil {
                disable(defaults: defaults)
            }
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// Writes ~/Library/LaunchAgents/com.local.winterdesk.plist. Loaded by launchd at the next
    /// login (not bootstrapped now, which would start a second instance).
    private static func writeAgent() -> String? {
        guard isInstalledCopy, let exe = Bundle.main.executablePath else { return "No executable path" }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        do {
            try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentURL, options: .atomic)
            return nil
        } catch {
            return "LaunchAgent: \(error.localizedDescription)"
        }
    }

    private static func removeAgent() {
        guard isInstalledCopy, FileManager.default.fileExists(atPath: agentURL.path), agentIsOurs || isLegacyAgent else { return }
        try? FileManager.default.removeItem(at: agentURL)
    }

    /// An agent with our label that points at another copy of WinterDesk (e.g. an old install path).
    private static var isLegacyAgent: Bool {
        guard let data = try? Data(contentsOf: agentURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return false }
        return (plist["Label"] as? String) == agentLabel
    }

    /// One-time (installed copy only): the stored preference defaults to ON. Separate from the
    /// SMAppService status so the intent survives re-pointing.
    static func migrateDefaultOn(defaults: UserDefaults) {
        guard isInstalledCopy, !defaults.bool(forKey: "loginMigrationV2") else { return }
        defaults.set(true, forKey: "loginMigrationV2")
        if defaults.object(forKey: preferenceKey) == nil { defaults.set(true, forKey: preferenceKey) }
    }
}
