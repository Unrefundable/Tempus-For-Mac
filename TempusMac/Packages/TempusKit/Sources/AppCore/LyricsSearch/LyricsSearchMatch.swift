import Foundation
import Persistence
import SubsonicAPI

/// A song found by its lyrics, with the line that matched best and where the typed words are in it.
public struct LyricsSearchMatch: Sendable, Identifiable {
    public let song: Song
    public let line: String
    public let highlights: [Range<String.Index>]

    public var id: String {
        song.id
    }

    /// A line of lyrics, how well it matches, and where the matching words are.
    struct ScoredLine {
        let line: String
        let score: Int
        let highlights: [Range<String.Index>]
    }

    /// The line of `lyrics` that best matches `query`: the most of its words, with a bonus for
    /// all of them in order; the first such line on a tie. The last typed word may be unfinished,
    /// so it matches as a prefix. Nil when there are no lines or no words to look for.
    static func bestLine(in lyrics: String, for query: String) -> ScoredLine? {
        let wanted = LyricsWords.words(in: query).map(\.folded)
        guard !wanted.isEmpty else { return nil }
        var best: ScoredLine?
        for line in lyrics.split(whereSeparator: \.isNewline).map(String.init) {
            let scored = score(line, wanted: wanted)
            if best == nil || scored.score > best?.score ?? 0 {
                best = scored
            }
        }
        return best
    }

    private static func score(_ line: String, wanted: [String]) -> ScoredLine {
        let words = LyricsWords.words(in: line)
        let matches = { (word: String, wantedIndex: Int) in
            wantedIndex == wanted.count - 1 ? word.hasPrefix(wanted[wantedIndex]) : word == wanted[wantedIndex]
        }
        let found = wanted.indices.filter { wantedIndex in words.contains { matches($0.folded, wantedIndex) } }
        let highlights = words.filter { word in wanted.indices.contains { matches(word.folded, $0) } }.map(\.range)
        let inOrder = words.indices.contains { start in
            start + wanted.count <= words.count
                && wanted.indices.allSatisfy { matches(words[start + $0].folded, $0) }
        }
        return ScoredLine(line: line, score: found.count + (inOrder ? wanted.count : 0), highlights: highlights)
    }
}

/// Words as lyrics search compares them, matching how the index sees them (`LyricsFolding`, then
/// SQLite's tokenizer): lowercased, accents and apostrophes gone, Latin letters in ASCII.
enum LyricsWords {
    static func words(in text: String) -> [(range: Range<String.Index>, folded: String)] {
        var words: [(range: Range<String.Index>, folded: String)] = []
        text.enumerateSubstrings(in: text.startIndex ..< text.endIndex, options: .byWords) { word, range, _, _ in
            guard let word else { return }
            let folded = fold(word)
            if !folded.isEmpty {
                words.append((range, folded))
            }
        }
        return words
    }

    static func fold(_ word: String) -> String {
        LyricsFolding.fold(word)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
