import Foundation

/// First-class wrappers around common macOS apps, so the model doesn't have to
/// hand-write AppleScript for everyday actions. Dates are built field-by-field
/// (locale-safe) rather than parsed from a string by AppleScript.
enum NativeConnectors {

    /// Parse "YYYY-MM-DD HH:MM" (24h) into AppleScript date-setter lines.
    private static func dateSetters(_ varName: String, from string: String) -> String? {
        let parts = string.split(whereSeparator: { " -:T".contains($0) }).map(String.init)
        guard parts.count >= 5,
              let y = Int(parts[0]), let mo = Int(parts[1]), let d = Int(parts[2]),
              let h = Int(parts[3]), let mi = Int(parts[4]) else { return nil }
        return """
        set \(varName) to current date
        set year of \(varName) to \(y)
        set month of \(varName) to \(mo)
        set day of \(varName) to \(d)
        set hours of \(varName) to \(h)
        set minutes of \(varName) to \(mi)
        set seconds of \(varName) to 0
        """
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - Calendar

    /// Add an event. `start` is "YYYY-MM-DD HH:MM". Defaults to 60 min.
    static func calendarAddEvent(title: String, start: String, durationMinutes: Int, notes: String, calendar: String) -> [String: String] {
        guard let startSetter = dateSetters("startDate", from: start) else {
            return ["error": "start must be 'YYYY-MM-DD HH:MM' (24-hour)"]
        }
        let calClause = calendar.isEmpty ? "first calendar whose writable is true" : "calendar \"\(esc(calendar))\""
        let script = """
        tell application "Calendar"
          \(startSetter)
          set endDate to startDate + (\(max(1, durationMinutes)) * minutes)
          tell (\(calClause))
            make new event with properties {summary:"\(esc(title))", start date:startDate, end date:endDate, description:"\(esc(notes))"}
          end tell
          return "ok"
        end tell
        """
        return AppleScriptRunner.run(script)
    }

    /// Read today's events across all calendars.
    static func calendarToday() -> [String: String] {
        let script = """
        set output to ""
        set startOfDay to current date
        set hours of startOfDay to 0
        set minutes of startOfDay to 0
        set seconds of startOfDay to 0
        set endOfDay to startOfDay + (1 * days)
        tell application "Calendar"
          repeat with c in calendars
            repeat with e in (every event of c whose start date ≥ startOfDay and start date < endOfDay)
              set output to output & (summary of e) & " — " & (time string of (start date of e)) & linefeed
            end repeat
          end repeat
        end tell
        if output is "" then return "No events today."
        return output
        """
        return AppleScriptRunner.run(script)
    }

    // MARK: - Reminders

    static func remindersAdd(text: String, due: String, list: String) -> [String: String] {
        let listClause = list.isEmpty ? "default list" : "list \"\(esc(list))\""
        var props = "name:\"\(esc(text))\""
        var dueSetter = ""
        if !due.isEmpty {
            if let setter = dateSetters("dueDate", from: due) {
                dueSetter = setter
                props += ", due date:dueDate"
            }
        }
        let script = """
        tell application "Reminders"
          \(dueSetter)
          tell \(listClause)
            make new reminder with properties {\(props)}
          end tell
          return "ok"
        end tell
        """
        return AppleScriptRunner.run(script)
    }

    // MARK: - Notes

    static func notesCreate(title: String, body: String) -> [String: String] {
        // Notes uses HTML for the body; first line becomes the title.
        let html = "<div><b>\(esc(title))</b></div><div>\(esc(body).replacingOccurrences(of: "\n", with: "</div><div>"))</div>"
        let script = """
        tell application "Notes"
          make new note at folder "Notes" of account "iCloud" with properties {body:"\(html)"}
          return "ok"
        end tell
        """
        return AppleScriptRunner.run(script)
    }

    // MARK: - Mail

    /// Compose a DRAFT and show it — never auto-sends.
    static func mailCompose(to: String, subject: String, body: String) -> [String: String] {
        let script = """
        tell application "Mail"
          set msg to make new outgoing message with properties {subject:"\(esc(subject))", content:"\(esc(body))", visible:true}
          tell msg
            make new to recipient at end of to recipients with properties {address:"\(esc(to))"}
          end tell
          activate
          return "draft created"
        end tell
        """
        return AppleScriptRunner.run(script)
    }
}
