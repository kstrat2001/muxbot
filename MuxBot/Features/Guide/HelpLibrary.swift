import Foundation
import NaturalLanguage

/// A help article bundled with the app (`Guide/Help/<id>.md`): a `# Title`,
/// then `## Section`s.
struct HelpArticle: Identifiable, Equatable, Sendable {
    struct Section: Equatable, Sendable {
        var heading: String
        var body: String
    }

    var id: String
    var title: String
    /// The text under the title, before the first section.
    var intro: String
    var sections: [Section]

    init(id: String, markdown: String) {
        self.id = id
        var title = id
        var intro: [String] = []
        var sections: [Section] = []
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("# ") {
                title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("## ") {
                sections.append(Section(heading: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces), body: ""))
            } else if sections.isEmpty {
                intro.append(line)
            } else {
                sections[sections.count - 1].body += line + "\n"
            }
        }
        self.title = title
        self.intro = intro.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        self.sections = sections.map { Section(heading: $0.heading, body: $0.body.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// The intro (under the title) and each section, as the parts search looks at.
    var parts: [(heading: String, body: String)] {
        (intro.isEmpty ? [] : [(title, intro)]) + sections.map { ($0.heading, $0.body) }
    }
}

/// Sentence vectors for ranking. On device: NaturalLanguage's sentence
/// embedding.
protocol SentenceEmbedder: Sendable {
    func vector(for text: String) -> [Double]?
}

struct NLSentenceEmbedder: SentenceEmbedder, @unchecked Sendable {
    private let embedding = NLEmbedding.sentenceEmbedding(for: .english)
    func vector(for text: String) -> [Double]? { embedding?.vector(for: text) }
}

/// Finds the help that answers a question, on device. What's known is decided
/// by the question's words (lemmas, weighted by how rare they are in the
/// help): at least half of its weight must appear in a part. Sentence
/// vectors only order what passes. Measured on the bundled articles: covered
/// questions score 0.5 to 1, off-topic ones 0 to 0.33; vectors alone didn't
/// separate them (a poem request scored above real questions).
final class HelpLibrary: @unchecked Sendable {
    struct Hit: Equatable {
        var article: HelpArticle
        var section: String
        var text: String
        var coverage: Double
        var score: Double
    }

    let articles: [HelpArticle]
    private let embedder: (any SentenceEmbedder)?
    private struct Part {
        var article: HelpArticle
        var heading: String
        var body: String
        var words: Set<String>
        var headingWords: Set<String>
        var titleWords: Set<String>
        var vectors: [[Double]]
    }
    private lazy var parts: [Part] = buildParts()
    private lazy var documentFrequency: [String: Int] = {
        var df: [String: Int] = [:]
        for part in parts { for w in part.words { df[w, default: 0] += 1 } }
        return df
    }()
    private let lock = NSLock()

    static let threshold = 0.5

    init(articles: [HelpArticle], embedder: (any SentenceEmbedder)? = NLSentenceEmbedder()) {
        self.articles = articles
        self.embedder = embedder
    }

    static let bundled: HelpLibrary = {
        let urls = Bundle.main.urls(forResourcesWithExtension: "md", subdirectory: "Help") ?? []
        let articles = urls.compactMap { url -> HelpArticle? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return HelpArticle(id: url.deletingPathExtension().lastPathComponent, markdown: text)
        }
        return HelpLibrary(articles: articles.sorted { $0.id < $1.id })
    }()

    func article(_ id: String) -> HelpArticle? { articles.first { $0.id == id } }

    /// The parts that answer `question`, best first; empty when the help
    /// doesn't cover it. `in` limits it to one article.
    func search(_ question: String, in articleId: String? = nil, limit: Int = 2, minCoverage: Double = HelpLibrary.threshold) -> [Hit] {
        lock.lock(); defer { lock.unlock() }
        let words = Self.lemmas(question)
        guard !words.isEmpty else { return [] }
        let n = Double(max(parts.count, 1))
        func weight(_ w: String) -> Double { log(n / Double(max(documentFrequency[w] ?? 0, 1))) + 1 }
        let total = words.map(weight).reduce(0, +)
        let query = embedder?.vector(for: question)
        let hits = parts.filter { articleId == nil || $0.article.id == articleId }.compactMap { part -> Hit? in
            let coverage = words.filter(part.words.contains).map(weight).reduce(0, +) / total
            guard coverage >= minCoverage, coverage > 0 else { return nil }
            let inHeading = Double(words.filter(part.headingWords.contains).count) / Double(words.count)
            let similarity = query.map { q in part.vectors.map { Self.cosine(q, $0) }.max() ?? 0 } ?? 0
            // The article the question names ("what is a bot" → Bots).
            let named = !part.titleWords.isEmpty && part.titleWords.isSubset(of: words) ? 0.3 : 0
            return Hit(article: part.article, section: part.heading, text: part.body, coverage: coverage,
                       score: coverage + 0.5 * similarity + 0.3 * inHeading + named)
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    private func buildParts() -> [Part] {
        articles.flatMap { article in
            article.parts.map { heading, body in
                let tokenizer = NLTokenizer(unit: .sentence)
                tokenizer.string = body
                var sentences = ["\(article.title): \(heading)"]
                tokenizer.enumerateTokens(in: body.startIndex..<body.endIndex) { range, _ in
                    sentences.append(String(body[range])); return true
                }
                return Part(article: article, heading: heading, body: body,
                            words: Self.lemmas("\(article.title) \(heading) \(body)"),
                            headingWords: Self.lemmas("\(article.title) \(heading)"),
                            titleWords: Self.lemmas(article.title),
                            vectors: sentences.compactMap { embedder?.vector(for: $0) })
            }
        }
    }

    /// Words that carry meaning, as lemmas ("runs" → "run").
    static func lemmas(_ text: String) -> Set<String> {
        let lower = text.lowercased()
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = lower
        var out = Set<String>()
        tagger.enumerateTags(in: lower.startIndex..<lower.endIndex, unit: .word, scheme: .lemma,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            // The tagger has no lemma for some words out of context ("bots",
            // "models"): a plain plural then drops its s.
            var word = (tag?.rawValue ?? String(lower[range])).lowercased()
            if tag == nil, word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { word.removeLast() }
            if word.count > 1, !stopwords.contains(word) { out.insert(word) }
            return true
        }
        return out
    }

    private static let stopwords: Set<String> = [
        "the", "an", "do", "does", "did", "is", "are", "was", "be", "it", "its", "to", "of", "and", "or", "in", "on", "at",
        "my", "me", "mine", "we", "our", "you", "your", "what", "how", "can", "could", "for", "with", "this", "that",
        "when", "which", "should", "would", "will", "get", "use", "mean", "make", "have", "has", "there", "about",
        "why", "where", "who", "tell", "write", "need", "want", "give", "show", "know", "like", "good", "best",
        "thing", "some", "any", "if", "so", "not", "no", "yes", "just", "one", "from", "by", "as", "but", "up",
        "out", "into", "than", "then", "too", "very", "also", "please", "let", "much", "many", "way",
    ]

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, x = 0.0, y = 0.0
        for i in 0..<min(a.count, b.count) { dot += a[i] * b[i]; x += a[i] * a[i]; y += b[i] * b[i] }
        return x == 0 || y == 0 ? 0 : dot / (x * y).squareRoot()
    }
}
