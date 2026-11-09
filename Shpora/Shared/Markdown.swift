import Foundation

/// Блок разобранного Markdown-документа.
nonisolated enum MDBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MDListItem])
    case quote([MDBlock])
    case code(language: String, text: String)
    case math(String)
    case table(MDTable)
    case image(alt: String, source: String)
    case rule
}

nonisolated struct MDListItem: Hashable, Sendable {
    var indent: Int
    /// nil — маркированный список, иначе номер.
    var number: Int?
    /// nil — обычный пункт, true/false — чекбокс.
    var checked: Bool?
    var text: String
}

nonisolated enum MDColumnAlignment: Hashable, Sendable {
    case leading, center, trailing
}

nonisolated struct MDTable: Hashable, Sendable {
    var header: [String]
    var alignments: [MDColumnAlignment]
    var rows: [[String]]

    var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }
}

nonisolated enum MarkdownParser {
    static func parse(_ source: String) -> [MDBlock] {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        return parse(lines: lines[...])
    }

    private static func parse(lines: ArraySlice<String>) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var paragraph: [String] = []
        var i = lines.startIndex

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(contentsOf: splitImages(paragraph.joined(separator: "\n")))
            paragraph.removeAll()
        }

        // YAML front matter (Obsidian) пропускаем.
        if let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
           lines[lines.startIndex + 1..<end].allSatisfy({ $0.contains(":") || $0.trimmingCharacters(in: .whitespaces).isEmpty || $0.hasPrefix(" ") || $0.hasPrefix("-") }) {
            i = end + 1
        }

        while i < lines.endIndex {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Пустая строка
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // Блок кода
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                let fence = String(trimmed.prefix(3))
                let language = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.endIndex, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    body.append(lines[i])
                    i += 1
                }
                i += 1
                if language.lowercased() == "math" || language.lowercased() == "latex" {
                    blocks.append(.math(body.joined(separator: "\n")))
                } else {
                    blocks.append(.code(language: language, text: body.joined(separator: "\n")))
                }
                continue
            }

            // Формула $$ ... $$ или \[ ... \]
            if let (open, close) = [("$$", "$$"), ("\\[", "\\]")].first(where: { trimmed.hasPrefix($0.0) }) {
                flushParagraph()
                var rest = String(trimmed.dropFirst(open.count))
                if let r = rest.range(of: close) {
                    blocks.append(.math(String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)))
                    i += 1
                    continue
                }
                var body: [String] = rest.isEmpty ? [] : [rest]
                i += 1
                while i < lines.endIndex {
                    rest = lines[i]
                    if let r = rest.range(of: close) {
                        let before = String(rest[..<r.lowerBound])
                        if !before.trimmingCharacters(in: .whitespaces).isEmpty { body.append(before) }
                        break
                    }
                    body.append(rest)
                    i += 1
                }
                i += 1
                blocks.append(.math(body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
                continue
            }

            // Заголовок
            if let level = headingLevel(trimmed) {
                flushParagraph()
                let text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, text: text.trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)))
                i += 1
                continue
            }

            // Горизонтальная линия
            if isRule(trimmed) {
                flushParagraph()
                blocks.append(.rule)
                i += 1
                continue
            }

            // Таблица
            if trimmed.contains("|"), i + 1 < lines.endIndex, isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let header = splitRow(line)
                let alignments = splitRow(lines[i + 1]).map(alignment)
                var rows: [[String]] = []
                i += 2
                while i < lines.endIndex {
                    let row = lines[i].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    rows.append(splitRow(row))
                    i += 1
                }
                blocks.append(.table(MDTable(header: header, alignments: alignments, rows: rows)))
                continue
            }

            // Цитата
            if trimmed.hasPrefix(">") {
                flushParagraph()
                var inner: [String] = []
                while i < lines.endIndex {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    var content = t.dropFirst()
                    if content.hasPrefix(" ") { content = content.dropFirst() }
                    inner.append(String(content))
                    i += 1
                }
                blocks.append(.quote(parse(lines: inner[...])))
                continue
            }

            // Список
            if listItem(line) != nil {
                flushParagraph()
                var items: [MDListItem] = []
                while i < lines.endIndex {
                    if let item = listItem(lines[i]) {
                        items.append(item)
                        i += 1
                    } else if !items.isEmpty,
                              lines[i].hasPrefix("  ") || lines[i].hasPrefix("\t"),
                              !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        // продолжение пункта на следующей строке
                        items[items.count - 1].text += "\n" + lines[i].trimmingCharacters(in: .whitespaces)
                        i += 1
                    } else {
                        break
                    }
                }
                blocks.append(.list(items))
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Помощники

    private static func headingLevel(_ line: String) -> Int? {
        var level = 0
        for ch in line {
            if ch == "#" { level += 1 } else { break }
        }
        guard (1...6).contains(level) else { return nil }
        let after = line.dropFirst(level)
        return after.isEmpty || after.hasPrefix(" ") ? level : nil
    }

    private static func isRule(_ line: String) -> Bool {
        let chars = line.filter { !$0.isWhitespace }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let cells = splitRow(line)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard c.contains("-") else { return false }
            return c.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    static func splitRow(_ line: String) -> [String] {
        var row = line.trimmingCharacters(in: .whitespaces)
        if row.hasPrefix("|") { row.removeFirst() }
        if row.hasSuffix("|") && !row.hasSuffix("\\|") { row.removeLast() }
        var cells: [String] = []
        var current = ""
        var inMath = false
        var previous: Character = " "
        for ch in row {
            if ch == "$" && previous != "\\" { inMath.toggle() }
            if ch == "|" && previous != "\\" && !inMath {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else if ch == "|" && previous == "\\" {
                current.removeLast()
                current.append(ch)
            } else {
                current.append(ch)
            }
            previous = ch
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func alignment(_ cell: String) -> MDColumnAlignment {
        let c = cell.trimmingCharacters(in: .whitespaces)
        switch (c.hasPrefix(":"), c.hasSuffix(":")) {
        case (true, true): return .center
        case (false, true): return .trailing
        default: return .leading
        }
    }

    private static func listItem(_ line: String) -> MDListItem? {
        let expanded = line.replacingOccurrences(of: "\t", with: "    ")
        let indentCount = expanded.prefix(while: { $0 == " " }).count
        let body = expanded.dropFirst(indentCount)
        var number: Int?
        var rest: Substring

        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            rest = body.dropFirst(2)
        } else {
            let digits = body.prefix(while: \.isNumber)
            guard !digits.isEmpty, digits.count < 10 else { return nil }
            let after = body.dropFirst(digits.count)
            guard let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " else { return nil }
            number = Int(digits)
            rest = after.dropFirst(2)
        }

        var checked: Bool?
        let lower = rest.lowercased()
        if lower.hasPrefix("[ ] ") || lower == "[ ]" {
            checked = false
            rest = rest.dropFirst(min(4, rest.count))
        } else if lower.hasPrefix("[x] ") || lower == "[x]" {
            checked = true
            rest = rest.dropFirst(min(4, rest.count))
        }
        return MDListItem(indent: indentCount / 2, number: number, checked: checked,
                          text: rest.trimmingCharacters(in: .whitespaces))
    }

    /// `![alt](src)` и `![[src]]` в тексте абзаца становятся отдельными блоками картинок.
    private static let imageRegex = try! NSRegularExpression(
        pattern: #"!\[([^\]]*)\]\(\s*<?([^)>]+?)>?(?:\s+"[^"]*")?\s*\)|!\[\[([^\]|]+)(?:\|[^\]]*)?\]\]"#)

    static func splitImages(_ text: String) -> [MDBlock] {
        let ns = text as NSString
        let matches = imageRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [.paragraph(text)] }
        var result: [MDBlock] = []
        var cursor = 0
        for m in matches {
            let before = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            if !before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.paragraph(before.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            if m.range(at: 3).location != NSNotFound {
                result.append(.image(alt: "", source: ns.substring(with: m.range(at: 3))))
            } else {
                result.append(.image(alt: ns.substring(with: m.range(at: 1)), source: ns.substring(with: m.range(at: 2))))
            }
            cursor = m.range.location + m.range.length
        }
        let tail = ns.substring(from: cursor)
        if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.paragraph(tail.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return result
    }

    // MARK: - Сбор ресурсов (для синхронизации с часами)

    /// Все формулы документа: (latex, display?).
    static func formulas(in blocks: [MDBlock]) -> [(String, Bool)] {
        var result: [(String, Bool)] = []
        func inline(_ text: String) {
            for segment in InlineMath.segments(text) {
                switch segment {
                case .math(let latex): result.append((latex, false))
                case .display(let latex): result.append((latex, true))
                case .text: break
                }
            }
        }
        for block in blocks {
            switch block {
            case .math(let latex): result.append((latex, true))
            case .heading(_, let t), .paragraph(let t): inline(t)
            case .list(let items): items.forEach { inline($0.text) }
            case .quote(let inner): result += formulas(in: inner)
            case .table(let table): (table.header + table.rows.flatMap { $0 }).forEach(inline)
            default: break
            }
        }
        return result
    }

    static func imageSources(in blocks: [MDBlock]) -> [String] {
        blocks.flatMap { block -> [String] in
            switch block {
            case .image(_, let src): return [src]
            case .quote(let inner): return imageSources(in: inner)
            default: return []
            }
        }
    }
}

/// Разбиение строки на текст и встроенные формулы `$...$`.
nonisolated enum InlineMath {
    /// `display` — формула `$$…$$` или `\[…\]` посреди текста (в Obsidian так пишут прямо в пункте списка).
    enum Segment: Hashable { case text(String), math(String), display(String) }

    private static let regex = try! NSRegularExpression(
        pattern: #"\$\$((?:\\.|[^$])+?)\$\$|\\\[(.+?)\\\]|(?<![\\$])\$(?![\s$])((?:\\.|[^$\\])+?)(?<!\s)\$(?!\$)|\\\((.+?)\\\)"#,
        options: [.dotMatchesLineSeparators])

    static func segments(_ text: String) -> [Segment] {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [.text(text)] }
        var result: [Segment] = []
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                result.append(.text(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))))
            }
            if let g = [1, 2].first(where: { m.range(at: $0).location != NSNotFound }) {
                result.append(.display(ns.substring(with: m.range(at: g)).trimmingCharacters(in: .whitespacesAndNewlines)))
            } else if let g = [3, 4].first(where: { m.range(at: $0).location != NSNotFound }) {
                result.append(.math(ns.substring(with: m.range(at: g))))
            }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length { result.append(.text(ns.substring(from: cursor))) }
        return result
    }
}
