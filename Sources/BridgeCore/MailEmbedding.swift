import Foundation
import NaturalLanguage

/// Turns text into a vector with a model on this Mac. A text in a language no model here covers gives nil.
public protocol TextEmbedding: Sendable {
    func embed(_ text: String) -> Embedded
}
public enum Embedded: Equatable, Sendable {
    case vector(model: String, [Float])
    /// No model on this Mac covers the text's language.
    case unsupported
    /// The model exists but macOS has not fetched its files yet; the text is tried again later.
    case later
}

/// Apple's contextual embedding models, which ship with macOS and run on the Mac (owner's choice, 15 November
/// 2026). A text is given to the model for its language; the model answers with one vector per word piece, and
/// their average, made a unit vector, stands for the passage. Each family of languages has a model of its own,
/// and vectors of different models are never compared.
public final class ContextualEmbedder: TextEmbedding, @unchecked Sendable {
    private let lock = NSLock()
    private var models: [NLLanguage: NLContextualEmbedding?] = [:]
    public init() {}

    private var asked: [NLLanguage: Date] = [:]
    public func embed(_ text: String) -> Embedded {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let language = NLLanguageRecognizer.dominantLanguage(for: trimmed) else { return .unsupported }
        lock.lock(); defer { lock.unlock() }
        if models[language] == nil {
            guard let candidate = NLContextualEmbedding(language: language) else { models[language] = .some(nil); return .unsupported }
            // A model whose files macOS has not fetched yet is asked for, at most once a minute, and used once it is there.
            guard candidate.hasAvailableAssets else {
                if Date().timeIntervalSince(asked[language] ?? .distantPast) > 60 { asked[language] = Date(); candidate.requestAssets { _, _ in } }
                return .later
            }
            guard (try? candidate.load()) != nil else { return .later }
            models[language] = candidate
        }
        guard let held = models[language], let model = held else { return .unsupported }
        guard let result = try? model.embeddingResult(for: trimmed, language: language) else { return .unsupported }
        var sum = [Double](repeating: 0, count: model.dimension), pieces = 0
        result.enumerateTokenVectors(in: trimmed.startIndex..<trimmed.endIndex) { vector, _ in
            for index in 0..<min(sum.count, vector.count) { sum[index] += vector[index] }
            pieces += 1
            return true
        }
        let length = sqrt(sum.reduce(0) { $0 + $1 * $1 })
        guard pieces > 0, length > 0 else { return .unsupported }
        return .vector(model: model.modelIdentifier, sum.map { Float($0 / length) })
    }
}

public enum MailEmbedding {
    /// The most passages kept for one message: what a long message says beyond them is found by its words.
    public static let partLimit = 4
    /// A passage's length in characters. The models read about 250 word pieces at once; in Chinese, Japanese and
    /// Korean a character is about one piece, elsewhere a piece is three or four characters.
    static func partLength(for text: String) -> Int {
        let sample = text.prefix(400)
        let wide = sample.unicodeScalars.filter { $0.value >= 0x2E80 }.count
        return wide * 3 > sample.unicodeScalars.count ? 220 : 700
    }
    /// A message's own text cut into passages, each ending at the end of a line or a sentence where one is near.
    public static func parts(of text: String) -> [(start: Int, length: Int)] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        let size = partLength(for: text)
        var parts: [(Int, Int)] = [], start = 0
        while start < characters.count, parts.count < partLimit {
            var end = min(start + size, characters.count)
            if end < characters.count, let stop = (start + size / 2..<end).last(where: { characters[$0].isNewline || ".。!?！？".contains(characters[$0]) }) { end = stop + 1 }
            parts.append((start, end - start))
            start = end
        }
        return parts
    }

    /// Embeds messages that have no embedding yet, newest first, and returns how many it looked at. It reads only
    /// Mail Dot's own index, so it runs whether Mail is open or not.
    @discardableResult public static func step(index: MailSearchIndex, embedder: any TextEmbedding, allowed: [String: [String]], batch: Int = 20) throws -> Int {
        let waiting = try index.unembedded(allowed: allowed, limit: batch)
        var looked = 0
        messages: for message in waiting {
            let characters = Array(message.text)
            var model = "", embedded: [MailSearchIndex.EmbeddedPart] = []
            var pieces = parts(of: message.text)
            // A message with a subject and no text of its own is known by its subject.
            if pieces.isEmpty { pieces = [(0, 0)] }
            for (number, piece) in pieces.enumerated() {
                let passage = String(characters[piece.start..<piece.start + piece.length])
                // The subject says what the first passage is about.
                switch embedder.embed(number == 0 ? message.subject + "\n" + passage : passage) {
                case .vector(let made, let vector):
                    if model.isEmpty { model = made }
                    if made == model { embedded.append(.init(start: piece.start, length: piece.length, vector: vector)) }
                case .unsupported: continue
                // The model for this message's language is still being fetched: the message is put aside for an hour,
                // and the others, which may be in a language whose model is here, go on (review of build 170, M6).
                case .later:
                    try index.deferEmbedding(row: message.row)
                    looked += 1
                    continue messages
                }
            }
            try index.setEmbedding(row: message.row, model: model, parts: embedded)
            looked += 1
        }
        return looked
    }
}

/// How far embedding has come in each account, as the background app last counted it. Settings, which runs inside
/// Mail, reads these few numbers and never the index itself.
public enum MeaningProgress {
    public struct Counts: Codable, Sendable, Equatable {
        public var embedded: Int
        public var total: Int
        public init(embedded: Int, total: Int) { self.embedded = embedded; self.total = total }
    }
    static func file(_ bridgeDirectory: URL) -> URL { bridgeDirectory.appendingPathComponent("meaning-progress.json") }
    public static func read(bridgeDirectory: URL) -> [String: Counts] {
        (try? JSONDecoder().decode([String: Counts].self, from: Data(contentsOf: file(bridgeDirectory)))) ?? [:]
    }
    public static func publish(_ counts: [String: Counts], bridgeDirectory: URL) {
        guard counts != read(bridgeDirectory: bridgeDirectory), let data = try? JSONEncoder().encode(counts) else { return }
        try? data.write(to: file(bridgeDirectory), options: .atomic)
    }
}
