import Foundation

enum ShellRunner {
    /// Hard ceiling on how long a single command may run before it's killed.
    static let timeoutSeconds: Double = 30

    static func run(_ command: String) async -> [String: String] {
        if isDestructive(command) {
            return ["error": "refused: command looks destructive"]
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
                cont.resume(returning: result)
            }
        }
    }

    /// Best-effort guard against obviously destructive commands. A denylist is
    /// inherently leaky — the durable fix is a user-confirmation gate before any
    /// shell call — but this normalizes whitespace and catches the common forms.
    private static func isDestructive(_ cmd: String) -> Bool {
        // Lowercase and collapse runs of whitespace so "rm   -rf" / "rm  -fr"
        // can't slip past a literal "rm -rf" check.
        let collapsed = cmd.lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let banned = [
            "rm -rf", "rm -fr", "rm -r -f", "rm -f -r", "rm --no-preserve-root",
            "sudo ", "doas ",
            "mkfs", "dd if=", "of=/dev/", "> /dev/",
            "shutdown", "halt", "reboot",
            "diskutil erase", "diskutil reformat",
            ":(){:|:&};:", ":(){ :|:& };:",
            "csrutil disable", "spctl --master-disable"
        ]
        if banned.contains(where: collapsed.contains) { return true }
        // Pipe-to-shell is the classic injection→RCE pattern; block it.
        let pipedToShell = (collapsed.contains("curl ") || collapsed.contains("wget "))
            && (collapsed.contains("| sh") || collapsed.contains("| bash") || collapsed.contains("|sh") || collapsed.contains("|bash"))
        return pipedToShell
    }
}
