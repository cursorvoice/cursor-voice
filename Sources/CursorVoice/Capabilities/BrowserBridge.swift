import Foundation
import AppKit

/// Runs JavaScript in the user's frontmost browser tab via AppleScript.
/// This is the most reliable way to act on WEB content — far better than
/// pixel-clicking or OCR, because it targets real DOM elements.
///
/// Requires the user to enable "Allow JavaScript from Apple Events":
///   • Safari: Develop menu → Allow JavaScript from Apple Events
///   • Chrome: View → Developer → Allow JavaScript from Apple Events
enum BrowserBridge {

    enum Browser: String {
        case safari = "Safari"
        case chrome = "Google Chrome"
        case brave  = "Brave Browser"
        case edge   = "Microsoft Edge"
        case arc    = "Arc"

        /// AppleScript to evaluate `js` in the active tab and return the result as text.
        func script(forJS js: String) -> String {
            let escaped = js
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ")
            switch self {
            case .safari:
                return """
                tell application "Safari"
                    set theResult to (do JavaScript "\(escaped)" in current tab of front window)
                    return theResult as text
                end tell
                """
            case .chrome, .brave, .edge, .arc:
                return """
                tell application "\(rawValue)"
                    set theResult to (execute active tab of front window javascript "\(escaped)")
                    return theResult as text
                end tell
                """
            }
        }
    }

    /// The frontmost app, if it's a supported browser.
    static func frontmostBrowser() -> Browser? {
        let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
        return Browser(rawValue: name)
    }

    /// Run raw JS in the frontmost browser. Returns ["result": ...] or ["error": ...].
    static func runJS(_ js: String) -> [String: Any] {
        guard let browser = frontmostBrowser() else {
            return ["error": "frontmost app is not a supported browser (Safari, Chrome, Brave, Edge, Arc)"]
        }
        let out = AppleScriptRunner.run(browser.script(forJS: js))
        if let err = out["error"], !err.isEmpty {
            // Most common cause: the per-browser toggle isn't enabled.
            return ["error": err,
                    "hint": "Enable 'Allow JavaScript from Apple Events' in \(browser.rawValue)'s Develop/Developer menu."]
        }
        return ["browser": browser.rawValue, "result": out["result"] ?? ""]
    }

    /// Click the first visible element whose text/label/aria matches `query`.
    /// Runs entirely in the page DOM, so it hits the real element regardless
    /// of where it visually sits.
    static func clickText(_ query: String) -> [String: Any] {
        let q = query.replacingOccurrences(of: "'", with: "\\'")
        let js = """
        (function(){
          var q='\(q)'.toLowerCase();
          var els=[].slice.call(document.querySelectorAll('a,button,[role=button],input[type=submit],input[type=button],[onclick],summary,[tabindex]'));
          function txt(e){return ((e.innerText||e.value||e.getAttribute('aria-label')||e.title||'')+'').trim().toLowerCase();}
          var hit=els.find(function(e){var t=txt(e);return t&&t.indexOf(q)>=0&&e.offsetParent!==null;});
          if(!hit){
            var all=[].slice.call(document.querySelectorAll('*'));
            hit=all.find(function(e){return txt(e)===q&&e.offsetParent!==null;});
          }
          if(!hit) return 'NOT_FOUND';
          hit.scrollIntoView({block:'center'});
          hit.click();
          return 'CLICKED: '+txt(hit).slice(0,60);
        })();
        """
        let res = runJS(js)
        if let r = res["result"] as? String, r == "NOT_FOUND" {
            return ["error": "no clickable element matching \"\(query)\"",
                    "hint": "call browser_snapshot to see what's on the page"]
        }
        return res
    }

    /// Return a compact list of the page's interactive elements (text + tag),
    /// so the model can see what's clickable without a screenshot.
    static func snapshot() -> [String: Any] {
        let js = """
        (function(){
          var out=[];
          var els=[].slice.call(document.querySelectorAll('a,button,[role=button],input,textarea,select,summary'));
          for(var i=0;i<els.length && out.length<60;i++){
            var e=els[i]; if(e.offsetParent===null) continue;
            var t=((e.innerText||e.value||e.getAttribute('aria-label')||e.placeholder||e.title||'')+'').trim().replace(/\\s+/g,' ').slice(0,70);
            if(!t) continue;
            out.push(e.tagName.toLowerCase()+': '+t);
          }
          return out.join(' | ');
        })();
        """
        let res = runJS(js)
        if let r = res["result"] as? String {
            let items = r.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return ["browser": res["browser"] ?? "", "elements": items, "count": items.count]
        }
        return res
    }

    /// Current page URL + title, for context.
    static func pageInfo() -> [String: Any] {
        return runJS("JSON.stringify({url:location.href,title:document.title})")
    }
}
