import Foundation
import AppKit
import Combine

/// Polls GitHub Releases for newer versions and offers an in-place update.
/// On install:
///   1. Downloads the new DMG to /tmp.
///   2. Writes a small bash script that waits for this process to die,
///      mounts the DMG, replaces /Applications/CursorVoice.app, removes
///      the quarantine attribute, relaunches the app, and self-cleans.
///   3. Spawns the script detached and terminates the running app.
/// No background services, no XPC helpers, no Sparkle dependency.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var availableUpdate: Release?
    @Published private(set) var checking: Bool = false
    @Published private(set) var installing: Bool = false
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastError: String?

    struct Release: Equatable {
        let version: String
        let tag: String
        let downloadURL: URL
        let notesURL: URL
        let publishedAt: Date
        let body: String
    }

    private let repo = "cursorvoice/cursor-voice"
    private var timer: Timer?

    /// Reads CFBundleShortVersionString from Info.plist. Defaults to "0.0.0"
    /// so a missing key always shows updates as available.
    var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    // MARK: - Lifecycle

    func startPeriodicCheck() {
        Task { await check() }
        timer?.invalidate()
        // Re-check every 6 hours while the app is running.
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { await self?.check() }
        }
    }

    // MARK: - Check

    /// Check only if we haven't checked within `gap` seconds — used for frequent
    /// triggers (app activation) so we stay current without hammering the API.
    func checkThrottled(_ gap: TimeInterval = 3600) async {
        if let t = lastCheckedAt, Date().timeIntervalSince(t) < gap { return }
        await check()
    }

    func check() async {
        guard !checking else { return }
        checking = true
        lastError = nil
        defer { checking = false; lastCheckedAt = Date() }

        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("CursorVoice/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                lastError = "GitHub returned HTTP \(http.statusCode)"
                NSLog("UpdateChecker: \(lastError!)")
                return
            }
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String,
                  let assets = obj["assets"] as? [[String: Any]] else {
                lastError = "malformed release response"
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            NSLog("UpdateChecker: latest=\(version) installed=\(currentVersion)")

            guard Self.isNewer(version, than: currentVersion) else {
                availableUpdate = nil
                return
            }

            guard let dmgAsset = assets.first(where: {
                      let n = $0["name"] as? String ?? ""
                      return n.hasSuffix(".dmg")
                  }),
                  let dmgURLString = dmgAsset["browser_download_url"] as? String,
                  let dmgURL = URL(string: dmgURLString) else {
                lastError = "no DMG asset in latest release"
                return
            }

            let notesURL = URL(string: "https://github.com/\(repo)/releases/tag/\(tag)")!
            let publishedAt: Date = {
                guard let s = obj["published_at"] as? String else { return Date() }
                return ISO8601DateFormatter().date(from: s) ?? Date()
            }()
            let body = (obj["body"] as? String) ?? ""

            availableUpdate = Release(
                version: version,
                tag: tag,
                downloadURL: dmgURL,
                notesURL: notesURL,
                publishedAt: publishedAt,
                body: body
            )
            NSLog("UpdateChecker: update available \(version)")
        } catch {
            lastError = error.localizedDescription
            NSLog("UpdateChecker: error \(error)")
        }
    }

    // MARK: - Install

    /// Download the new DMG, write an updater script, quit the app and let the
    /// script swap out the bundle and relaunch.
    func installNow() {
        guard let release = availableUpdate, !installing else { return }
        installing = true

        Task {
            do {
                let dmgPath = "/tmp/CursorVoice-update-\(UUID().uuidString).dmg"

                NSLog("UpdateChecker: downloading \(release.downloadURL)")
                let (tmpURL, response) = try await URLSession.shared.download(from: release.downloadURL)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    throw NSError(domain: "Update", code: http.statusCode,
                                  userInfo: [NSLocalizedDescriptionKey: "Download HTTP \(http.statusCode)"])
                }
                try? FileManager.default.removeItem(atPath: dmgPath)
                try FileManager.default.moveItem(at: tmpURL, to: URL(fileURLWithPath: dmgPath))

                let pid = ProcessInfo.processInfo.processIdentifier
                let bundlePath = Bundle.main.bundlePath
                let scriptPath = "/tmp/cursorvoice-updater-\(UUID().uuidString).sh"
                let script = Self.updaterScript(pid: pid, dmgPath: dmgPath, bundlePath: bundlePath)
                try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

                NSLog("UpdateChecker: spawning updater \(scriptPath)")
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/bash")
                proc.arguments = [scriptPath]
                // Detach from our stdio so the script outlives us cleanly.
                proc.standardInput = FileHandle.nullDevice
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try proc.run()

                // Give launchd a beat to reparent the child, then quit.
                try? await Task.sleep(nanoseconds: 250_000_000)
                NSApp.terminate(nil)
            } catch {
                NSLog("UpdateChecker: install failed \(error)")
                lastError = "install failed: \(error.localizedDescription)"
                installing = false
            }
        }
    }

    private static func updaterScript(pid: Int32, dmgPath: String, bundlePath: String) -> String {
        // NB: paths are shell-escaped with single quotes; any single quote in
        // bundlePath would break — but app bundles can't contain '.
        return #"""
        #!/bin/bash
        set -u

        OLD_PID=\#(pid)
        DMG='\#(dmgPath)'
        APP='\#(bundlePath)'
        SELF="$0"

        # Wait for the old app to quit (up to 30s).
        for _ in $(seq 1 150); do
            if ! kill -0 "$OLD_PID" 2>/dev/null; then break; fi
            sleep 0.2
        done

        # Mount DMG.
        MNT=$(/usr/bin/hdiutil attach -nobrowse -noautoopen "$DMG" \
              | awk '/Apple_HFS|Apple_APFS/ {for(i=NF;i>=1;i--){if($i ~ /^\//){print $i; exit}}}')
        if [ -z "$MNT" ] || [ ! -d "$MNT/CursorVoice.app" ]; then
            echo "updater: mount failed" >&2
            /usr/bin/open '\#(dmgPath)'
            exit 1
        fi

        # Swap the app.
        /bin/rm -rf "$APP"
        /bin/cp -R "$MNT/CursorVoice.app" "$APP"
        /usr/bin/hdiutil detach "$MNT" -quiet 2>/dev/null || true

        # Clear extended attributes: quarantine (self-signed, not notarized) and the
        # com.apple.FinderInfo detritus `cp -R` leaves, which fails strict codesign.
        /usr/bin/xattr -cr "$APP" 2>/dev/null || true

        # Relaunch.
        /usr/bin/open "$APP"

        # Self-cleanup.
        /bin/rm -f "$DMG" "$SELF"
        """#
    }

    // MARK: - Helpers

    func openReleaseNotes() {
        guard let r = availableUpdate else { return }
        NSWorkspace.shared.open(r.notesURL)
    }

    /// Compare two dotted version strings ("0.2.0" > "0.1.0"). Non-numeric
    /// components are treated as 0. Different-length versions are padded
    /// with zeros ("1.0" == "1.0.0").
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").map { Int($0) ?? 0 }
        let l = local.split(separator:  ".").map { Int($0) ?? 0 }
        let n = Swift.max(r.count, l.count)
        for i in 0..<n {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}
