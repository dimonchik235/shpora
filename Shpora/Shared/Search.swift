import Foundation

struct SearchResult: Identifiable, Sendable {
    let url: URL
    let title: String
    let path: String
    let snippet: String?
    var id: URL { url }

    nonisolated static func search(_ query: String, in folder: URL) -> [SearchResult] {
        let needle = fold(query)
        guard !needle.isEmpty else { return [] }
        var byTitle: [SearchResult] = []
        var byText: [SearchResult] = []
        for note in Library.allNotes(in: folder) {
            let path = Library.relativePath(of: note.url.deletingLastPathComponent(), root: folder)
                .replacingOccurrences(of: "/", with: " › ")
            let text = (try? String(contentsOf: note.url, encoding: .utf8)) ?? ""
            let snippet = snippet(in: text, for: needle)
            if fold(note.name).contains(needle) {
                byTitle.append(SearchResult(url: note.url, title: note.name, path: path, snippet: snippet))
            } else if snippet != nil {
                byText.append(SearchResult(url: note.url, title: note.name, path: path, snippet: snippet))
            }
        }
        return byTitle + byText
    }

    /// Отрывок текста вокруг первого совпадения (поиск — по «сложенному» тексту).
    nonisolated private static func snippet(in text: String, for needle: [Character]) -> String? {
        let chars = Array(text)
        let folded = fold(text)
        guard let hit = firstIndex(of: needle, in: folded) else { return nil }
        let start = max(0, hit - 40)
        let end = min(chars.count, hit + needle.count + 80)
        return (start > 0 ? "…" : "") + plain(String(chars[start..<end]))
    }

    nonisolated private static func firstIndex(of needle: [Character], in haystack: [Character]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        for i in 0...(haystack.count - needle.count) where haystack[i] == needle[0] {
            if haystack[i..<(i + needle.count)].elementsEqual(needle) { return i }
        }
        return nil
    }

    /// Без учёта регистра и диакритики, по одному символу на символ, чтобы позиции совпадали
    /// с исходным текстом. «ł» и подобные — отдельные буквы, а не диакритика, их приводим вручную:
    /// так «kregoslup» находит «Kręgosłup».
    nonisolated private static func fold(_ text: String) -> [Character] {
        text.map { c in
            switch c {
            case "ł", "Ł": return "l"
            case "đ", "Đ": return "d"
            case "ø", "Ø": return "o"
            case "ё", "Ё": return "е"
            default:
                let f = String(c).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                return f.count == 1 ? f.first! : c
            }
        }
    }

    /// Убирает разметку Markdown из отрывка, чтобы он читался как обычный текст.
    nonisolated private static func plain(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"!\[\[?([^\]]*)\]\]?(\([^)]*\))?"#, with: "$1", options: .regularExpression)
        for (token, replacement) in [("**", ""), ("==", ""), ("<br>", " "), ("`", ""),
                                     ("$\\rightarrow$", "→"), ("$\\leftarrow$", "←")] {
            s = s.replacingOccurrences(of: token, with: replacement)
        }
        s = s.replacingOccurrences(of: #"(?m)^\s*(#+|>|[-*]|\|)\s*"#, with: "", options: .regularExpression)
        return s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
