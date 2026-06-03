import Foundation
import NaturalLanguage

/// Persistent memory for the assistant. Stored as a JSON array at
/// ~/Library/Application Support/CursorVoice/memory.json. The model
/// writes facts via the `remember` tool and reads them via `recall`.
/// At session start, all current memories are appended to the system
/// instructions so the model knows what it already knows.
final class MemoryStore {
    static let shared = MemoryStore()

    private let url: URL
    private let queue = DispatchQueue(label: "CursorVoice.MemoryStore")
    private var items: [Item] = []

    struct Item: Codable, Equatable {
        let content: String
        let timestamp: TimeInterval
    }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("CursorVoice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("memory.json")
        load()
    }

    func remember(_ content: String) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.sync {
            // Dedup case-insensitive; refresh timestamp instead of duplicating.
            if let idx = items.firstIndex(where: { $0.content.lowercased() == trimmed.lowercased() }) {
                items.remove(at: idx)
            }
            items.append(Item(content: trimmed, timestamp: Date().timeIntervalSince1970))
            // Cap to last 200 items to keep the file reasonable.
            if items.count > 200 {
                items.removeFirst(items.count - 200)
            }
            save()
        }
    }

    /// Recall memories relevant to a query. Ranks by on-device semantic
    /// similarity (Apple NLEmbedding) so synonyms/paraphrases match, with a
    /// boost for literal substring hits. Falls back to plain substring match
    /// if the embedding model isn't available.
    func recall(matching query: String?) -> [Item] {
        queue.sync {
            guard let raw = query?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
                return items
            }
            let substringHits = Set(items.indices.filter { items[$0].content.localizedCaseInsensitiveContains(raw) })

            guard let emb = NLEmbedding.wordEmbedding(for: .english),
                  let qv = Self.sentenceVector(raw, emb) else {
                return substringHits.sorted().map { items[$0] }   // no embeddings → substring only
            }

            var scored: [(idx: Int, score: Double)] = []
            for i in items.indices {
                var score = substringHits.contains(i) ? 1.0 : 0.0
                if let v = Self.sentenceVector(items[i].content, emb) {
                    score += Self.cosine(qv, v)
                }
                if score > 0.45 { scored.append((i, score)) }   // relevance threshold
            }
            return scored.sorted { $0.score > $1.score }.prefix(25).map { items[$0.idx] }
        }
    }

    func all() -> [Item] {
        queue.sync { items }
    }

    func forget(matching query: String) -> Int {
        queue.sync {
            let before = items.count
            items.removeAll { $0.content.localizedCaseInsensitiveContains(query) }
            save()
            return before - items.count
        }
    }

    // MARK: - Semantic helpers

    /// Average word-embedding vector for a phrase (a simple sentence vector).
    private static func sentenceVector(_ text: String, _ emb: NLEmbedding) -> [Double]? {
        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        var sum: [Double]? = nil
        var n = 0
        for t in tokens where t.count > 2 {
            if let v = emb.vector(for: t) {
                if sum == nil { sum = v } else { for k in 0..<sum!.count { sum![k] += v[k] } }
                n += 1
            }
        }
        guard var s = sum, n > 0 else { return nil }
        for k in 0..<s.count { s[k] /= Double(n) }
        return s
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count else { return 0 }
        var dot = 0.0, na = 0.0, nb = 0.0
        for k in 0..<a.count { dot += a[k]*b[k]; na += a[k]*a[k]; nb += b[k]*b[k] }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (sqrt(na) * sqrt(nb))
    }

    // MARK: - Private

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONDecoder().decode([Item].self, from: data) else { return }
        items = arr
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
