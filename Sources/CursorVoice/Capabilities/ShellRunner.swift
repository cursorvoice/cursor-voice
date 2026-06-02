import Foundation

enum ShellRunner {
    /// Hard ceiling on how long a single command may run before it's killed.
    static let timeoutSeconds: Double = 30

    /// UserDefaults key for the opt-in that lets risky commands run.
    static let allowRiskyKey = "allowRiskyShellCommands"

    static func run(_ command: String) async -> [String: String] {
        // Risk model (not a hard denylist): a command that matches a risky
        // pattern is BLOCKED by default, but the user can opt in via
        // Settings → Advanced → "Allow risky shell commands". When opted in,
        // the command runs and the result carries a warning so the model can
        // tell the user what it did.
        let risk = riskReason(command)
        let allowRisky = UserDefaults.standard.bool(forKey: allowRiskyKey)
        if let risk = risk, !allowRisky {
            return [
                "blocked": "true",
                "risk": risk,
                "error": "blocked: this command looks risky (\(risk)). It was NOT run. The user can allow risky commands in Settings → Advanced → “Allow risky shell commands”, then ask again."
            ]
        }

        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", command]
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    cont.resume(returning: ["error": error.localizedDescription])
                    return
                }

                // Watchdog: kill the process if it outlives the timeout so a
                // hung command (waiting on stdin, ping with no count, …) can't
                // freeze the agent forever.
                var timedOut = false
                let watchdog = DispatchWorkItem {
                    if process.isRunning { timedOut = true; process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: watchdog)

                process.waitUntilExit()
                watchdog.cancel()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                var out = String(data: data, encoding: .utf8) ?? ""
                if out.count > 4000 { out = String(out.prefix(4000)) + "\n…(truncated)" }
                var result: [String: String] = [
                    "exit": String(process.terminationStatus),
                    "output": out
                ]
                if timedOut { result["error"] = "timed out after \(Int(timeoutSeconds))s" }
                if let risk = risk {
                    result["warning"] = "ran a risky command (\(risk)) — permitted by the user's “Allow risky shell commands” setting"
                }
                cont.resume(returning: result)
            }
        }
    }

    /// Returns a short human-readable reason if the command matches a risky
    /// pattern, or nil if it looks safe. "Risky" ≠ "always blocked": whether a
    /// risky command actually runs depends on the user's opt-in setting.
    ///
    /// A pattern list is inherently leaky (it can't catch every dangerous
    /// command), and is paired with the opt-in so users aren't hard-walled —
    /// the durable fix remains a per-command confirmation gate.
    static func riskReason(_ cmd: String) -> String? {
        // Lowercase and collapse runs of whitespace so "rm   -rf" / "rm  -fr"
        // can't slip past a literal "rm -rf" check.
        let collapsed = cmd.lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        let patterns: [(needle: String, reason: String)] = [
            ("rm -rf",                 "recursive force-delete"),
            ("rm -fr",                 "recursive force-delete"),
            ("rm -r -f",               "recursive force-delete"),
            ("rm -f -r",               "recursive force-delete"),
            ("rm --no-preserve-root",  "delete from the filesystem root"),
            ("sudo ",                  "runs as root"),
            ("doas ",                  "runs as root"),
            ("mkfs",                   "formats a filesystem"),
            ("dd if=",                 "raw disk read/write"),
            ("of=/dev/",               "raw disk write"),
            ("> /dev/",                "writes to a device file"),
            ("shutdown",               "powers off the machine"),
            ("halt",                   "powers off the machine"),
            ("reboot",                 "reboots the machine"),
            ("diskutil erase",         "erases a disk"),
            ("diskutil reformat",      "reformats a disk"),
            (":(){:|:&};:",            "fork bomb"),
            (":(){ :|:& };:",          "fork bomb"),
            ("csrutil disable",        "disables System Integrity Protection"),
            ("spctl --master-disable", "disables Gatekeeper")
        ]
        for p in patterns where collapsed.contains(p.needle) { return p.reason }

        // Pipe-to-shell is the classic injection→RCE pattern.
        let pipedToShell = (collapsed.contains("curl ") || collapsed.contains("wget "))
            && (collapsed.contains("| sh") || collapsed.contains("| bash")
                || collapsed.contains("|sh") || collapsed.contains("|bash"))
        if pipedToShell { return "pipes a download straight into a shell" }

        return nil
    }
}
