import Foundation

/// The Fit order: how setups on Macs with this chip did on the public evals
/// at evals.darkmux.com (`GET /api/v1/frontier`, pass rate first), used only
/// to order the model list. It's a sort, not a ranking: the app never shows
/// a score, rank or position, and a model with no runs there keeps
/// darkmux's order after the ones that have them. A run on a bigger Mac
/// doesn't mean the model needed it, so there's no memory filter: the list
/// is only ever the models this Mac has.
enum EvalsFit {
    static let site = URL(string: "https://evals.darkmux.com")!

    /// The site's slug for a chip ("Apple M5 Max" is apple-m5-max).
    static func chipSlug(_ chip: String) -> String {
        var out = ""
        var dash = false
        for c in chip.lowercased() {
            if c.isASCII && (c.isLetter || c.isNumber) {
                if dash && !out.isEmpty { out.append("-") }
                out.append(c)
                dash = false
            } else {
                dash = true
            }
        }
        return String(out.prefix(80))
    }

    /// The setups for this chip, local runs only, best pass rate first.
    static func url(chip: String) -> URL {
        var c = URLComponents(url: site.appending(path: "api/v1/frontier"), resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "machine", value: chipSlug(chip)), URLQueryItem(name: "providers", value: "false")]
        return c.url!
    }

    /// The weights whatever the engine calls them, as the site's `modelFamily`
    /// does: `mlx-community/Qwen3.8-27B-4bit` and `qwen/qwen3.8-27b` are both
    /// qwen3.8-27b.
    static func family(_ model: String) -> String {
        var s = (ModelLabel.model(model) ?? model).lowercased()
        while let cut = quantSuffix(s) { s = String(s[..<cut]) }
        return s
    }

    /// Where a quantization suffix (`-4bit`, `-mlx`, `-gguf`,
    /// `-turboquant-mlx`, `-q4_k_m`) starts, if the id ends in one.
    private static func quantSuffix(_ s: String) -> String.Index? {
        guard let dash = s.lastIndex(of: "-") else { return nil }
        let tail = String(s[s.index(after: dash)...])
        if tail == "mlx" {
            // -turboquant-mlx is one suffix.
            let head = s[..<dash]
            if head.hasSuffix("-turboquant") { return head.index(head.endIndex, offsetBy: -"-turboquant".count) }
            return dash
        }
        if tail == "gguf" { return dash }
        if tail.hasSuffix("bit"), tail.count > 3, tail.dropLast(3).allSatisfy(\.isNumber) { return dash }
        // q4, q4_k, q4_k_m, q4_k_s
        let parts = tail.split(separator: "_", omittingEmptySubsequences: false)
        if let q = parts.first, q.count == 2, q.first == "q", q.last!.isNumber {
            if parts.count == 1 { return dash }
            if parts[1] == "k" && (parts.count == 2 || (parts.count == 3 && (parts[2] == "m" || parts[2] == "s"))) { return dash }
        }
        return nil
    }

    struct Reply: Decodable {
        struct Body: Decodable { var points: [Point] }
        struct Point: Decodable { var family: String }
        var data: Body
    }

    /// The families in the site's order, each once.
    static func families(from data: Data) throws -> [String] {
        var seen = Set<String>()
        return try JSONDecoder().decode(Reply.self, from: data).data.points
            .map { $0.family.lowercased() }
            .filter { seen.insert($0).inserted }
    }

    /// The listing in Fit order: models with evals runs on this chip first, in
    /// the site's order; the rest after, in darkmux's order.
    static func ordered(_ listed: [DarkmuxClient.ProfileInfo], by fit: [String]) -> [DarkmuxClient.ProfileInfo] {
        guard !fit.isEmpty else { return listed }
        let place = Dictionary(fit.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return listed.enumerated().sorted { a, b in
            let pa = a.element.model.flatMap { place[family($0)] } ?? Int.max
            let pb = b.element.model.flatMap { place[family($0)] } ?? Int.max
            return pa != pb ? pa < pb : a.offset < b.offset
        }.map(\.element)
    }

    /// This Mac's chip ("Apple M5 Max"); nil where it can't tell (iPhone,
    /// whose darkmux is on a Mac).
    static var thisMacChip: String? {
        #if os(macOS)
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 else { return nil }
        let chip = String(cString: bytes).trimmingCharacters(in: .whitespacesAndNewlines)
        return chip.hasPrefix("Apple") ? chip : nil
        #else
        return nil
        #endif
    }
}
