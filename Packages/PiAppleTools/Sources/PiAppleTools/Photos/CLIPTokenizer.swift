import Foundation

/// CLIP's byte-level BPE tokenizer (OpenAI CLIP, as MobileCLIP's text encoder expects): lowercased text, split into
/// words, each word's UTF-8 bytes mapped to printable characters and merged by rank, the last piece marked `</w>`.
/// Output is always `contextLength` IDs: start, tokens, end, then zeros.
public struct CLIPTokenizer: Sendable {
    public static let contextLength = 77
    static let startToken: Int32 = 49406
    static let endToken: Int32 = 49407

    private let vocab: [String: Int32]
    private let ranks: [Pair: Int]
    private let byteToChar: [Character]

    struct Pair: Hashable { let a: String; let b: String }

    /// `vocab.json` (token → ID) and `merges.txt` (one merge per line, by rank, after a version header).
    public init(vocab vocabURL: URL, merges mergesURL: URL) throws {
        let vocabObject = try JSONSerialization.jsonObject(with: Data(contentsOf: vocabURL)) as? [String: Int] ?? [:]
        vocab = vocabObject.mapValues(Int32.init)
        var ranks: [Pair: Int] = [:]
        let lines = try String(contentsOf: mergesURL, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: true)
        for line in lines where !line.hasPrefix("#version") {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            ranks[Pair(a: String(parts[0]), b: String(parts[1]))] = ranks.count
        }
        self.ranks = ranks
        byteToChar = Self.bytesToUnicode()
        guard vocab.count > 1000, ranks.count > 1000 else { throw AppleToolError("The CLIP tokenizer files are incomplete.") }
    }

    public func encode(_ text: String) -> [Int32] {
        var ids: [Int32] = [Self.startToken]
        outer: for word in Self.words(Self.clean(text)) {
            let chars = Array(word.utf8).map { String(byteToChar[Int($0)]) }
            for piece in bpe(chars) {
                guard let id = vocab[piece] else { continue }
                if ids.count == Self.contextLength - 1 { break outer }
                ids.append(id)
            }
        }
        ids.append(Self.endToken)
        return ids + Array(repeating: 0, count: Self.contextLength - ids.count)
    }

    /// Merges a word's characters by rank until no known pair is left; the last piece ends with `</w>`.
    private func bpe(_ chars: [String]) -> [String] {
        guard !chars.isEmpty else { return [] }
        var pieces = chars
        pieces[pieces.count - 1] += "</w>"
        while pieces.count > 1 {
            var best: (rank: Int, index: Int)?
            for index in 0 ..< pieces.count - 1 {
                if let rank = ranks[Pair(a: pieces[index], b: pieces[index + 1])], rank < best?.rank ?? .max {
                    best = (rank, index)
                }
            }
            guard let best else { break }
            let pair = Pair(a: pieces[best.index], b: pieces[best.index + 1])
            // Merge every occurrence of the best pair, left to right.
            var merged: [String] = []
            var index = 0
            while index < pieces.count {
                if index < pieces.count - 1, pieces[index] == pair.a, pieces[index + 1] == pair.b {
                    merged.append(pair.a + pair.b)
                    index += 2
                } else {
                    merged.append(pieces[index])
                    index += 1
                }
            }
            pieces = merged
        }
        return pieces
    }

    /// Whitespace collapsed, lowercased, as CLIP's `basic_clean` + `whitespace_clean`.
    static func clean(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// CLIP's pre-tokenizer: contractions, runs of letters, single digits, runs of other non-space characters.
    static func words(_ text: String) -> [String] {
        let pattern = #"'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    /// GPT-2's byte → printable character table: printable Latin-1 bytes map to themselves, the rest above 255.
    static func bytesToUnicode() -> [Character] {
        var printable = Array(33 ... 126) + Array(161 ... 172) + Array(174 ... 255)
        var codes = printable
        var next = 0
        for byte in 0 ..< 256 where !printable.contains(byte) {
            printable.append(byte)
            codes.append(256 + next)
            next += 1
        }
        var table = [Character](repeating: " ", count: 256)
        for (byte, code) in zip(printable, codes) { table[byte] = Character(Unicode.Scalar(code)!) }
        return table
    }
}
