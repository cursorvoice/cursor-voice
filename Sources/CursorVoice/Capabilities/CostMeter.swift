import Foundation
import Combine

/// Tracks OpenAI Realtime API token usage and estimates spend, both for the
/// current session and cumulatively. The Realtime API reports a `usage` object
/// on every `response.done`; we accumulate the token details and multiply by a
/// per-model price table.
///
/// Figures are an ESTIMATE. Prices are published per 1M tokens and may change;
/// only OpenAI's dashboard is authoritative. The point here is live feedback so
/// a BYO-key user isn't surprised by their bill.
@MainActor
final class CostMeter: ObservableObject {
    static let shared = CostMeter()

    // Live, resets when a new orb session begins.
    @Published private(set) var sessionCost: Double = 0
    @Published private(set) var sessionInputTokens: Int = 0
    @Published private(set) var sessionOutputTokens: Int = 0
    @Published private(set) var sessionRequests: Int = 0

    // Cumulative across all sessions, persisted.
    @Published private(set) var lifetimeCost: Double = 0
    @Published private(set) var lifetimeInputTokens: Int = 0
    @Published private(set) var lifetimeOutputTokens: Int = 0

    private let defaults = UserDefaults.standard
    private let kCost = "usage.lifetimeCost"
    private let kIn = "usage.lifetimeInputTokens"
    private let kOut = "usage.lifetimeOutputTokens"

    private init() {
        lifetimeCost = defaults.double(forKey: kCost)
        lifetimeInputTokens = defaults.integer(forKey: kIn)
        lifetimeOutputTokens = defaults.integer(forKey: kOut)
    }

    /// Per-1M-token pricing. text/audio split because Realtime audio tokens cost
    /// far more than text tokens, and cached input is steeply discounted.
    struct Pricing {
        var textIn: Double, textCachedIn: Double, textOut: Double
        var audioIn: Double, audioCachedIn: Double, audioOut: Double
    }

    /// Approximate published prices (USD per 1M tokens). Falls back to the
    /// flagship rate for unknown models so an estimate is always shown.
    static func pricing(for model: String) -> Pricing {
        let m = model.lowercased()
        if m.contains("mini") {
            return Pricing(textIn: 0.60, textCachedIn: 0.06, textOut: 2.40,
                           audioIn: 10.0, audioCachedIn: 0.30, audioOut: 20.0)
        }
        // gpt-realtime / -2 / -1.5 / -translate flagship tier.
        return Pricing(textIn: 4.0, textCachedIn: 0.40, textOut: 16.0,
                       audioIn: 32.0, audioCachedIn: 0.40, audioOut: 64.0)
    }

    /// Begin a fresh session — zero the live counters (lifetime is untouched).
    func startSession() {
        sessionCost = 0
        sessionInputTokens = 0
        sessionOutputTokens = 0
        sessionRequests = 0
    }

    /// Accumulate one `response.usage` payload.
    func record(usage: [String: Any], model: String) {
        let p = Self.pricing(for: model)

        let inDetails = usage["input_token_details"] as? [String: Any] ?? [:]
        let outDetails = usage["output_token_details"] as? [String: Any] ?? [:]
        let cachedDetails = inDetails["cached_tokens_details"] as? [String: Any] ?? [:]

        let inText = Self.intVal(inDetails["text_tokens"])
        let inAudio = Self.intVal(inDetails["audio_tokens"])
        var cachedText = Self.intVal(cachedDetails["text_tokens"])
        let cachedAudio = Self.intVal(cachedDetails["audio_tokens"])
        // If only a flat cached_tokens is given, treat it as cached text.
        if cachedText == 0 && cachedAudio == 0 {
            cachedText = Self.intVal(inDetails["cached_tokens"])
        }
        let outText = Self.intVal(outDetails["text_tokens"])
        let outAudio = Self.intVal(outDetails["audio_tokens"])

        let freshInText = max(0, inText - cachedText)
        let freshInAudio = max(0, inAudio - cachedAudio)

        let cost =
            Double(freshInText)   / 1_000_000 * p.textIn +
            Double(cachedText)    / 1_000_000 * p.textCachedIn +
            Double(freshInAudio)  / 1_000_000 * p.audioIn +
            Double(cachedAudio)   / 1_000_000 * p.audioCachedIn +
            Double(outText)       / 1_000_000 * p.textOut +
            Double(outAudio)      / 1_000_000 * p.audioOut

        // Fall back to top-level totals if the detail breakdown was absent.
        let totalIn = (inText + inAudio) > 0
            ? inText + inAudio : Self.intVal(usage["input_tokens"])
        let totalOut = (outText + outAudio) > 0
            ? outText + outAudio : Self.intVal(usage["output_tokens"])

        sessionCost += cost
        sessionInputTokens += totalIn
        sessionOutputTokens += totalOut
        sessionRequests += 1

        lifetimeCost += cost
        lifetimeInputTokens += totalIn
        lifetimeOutputTokens += totalOut
        defaults.set(lifetimeCost, forKey: kCost)
        defaults.set(lifetimeInputTokens, forKey: kIn)
        defaults.set(lifetimeOutputTokens, forKey: kOut)

        NSLog("CostMeter: +$\(String(format: "%.5f", cost)) (session $\(String(format: "%.4f", sessionCost)), in=\(totalIn) out=\(totalOut))")
    }

    /// Zero the cumulative totals (e.g. user clicks "Reset" in Settings).
    func resetLifetime() {
        lifetimeCost = 0
        lifetimeInputTokens = 0
        lifetimeOutputTokens = 0
        defaults.removeObject(forKey: kCost)
        defaults.removeObject(forKey: kIn)
        defaults.removeObject(forKey: kOut)
    }

    private static func intVal(_ any: Any?) -> Int {
        if let n = any as? NSNumber { return n.intValue }
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        return 0
    }

    /// Compact money string for tight spots (orb): "$0.042" / "$1.20".
    static func short(_ d: Double) -> String {
        if d >= 1 { return String(format: "$%.2f", d) }
        if d >= 0.001 { return String(format: "$%.3f", d) }
        return d > 0 ? "<$0.001" : "$0.00"
    }

    /// Token count with thousands grouping: "12,407".
    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
