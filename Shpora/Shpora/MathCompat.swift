import Foundation
import SwiftMath

/// Команды LaTeX, которых нет в SwiftMath, но которые часто встречаются в записях из Obsidian
/// (химия: `\rightleftharpoons`, `\overset{H_2O}{\rightleftharpoons}`, `\implies`…).
/// Недостающие символы регистрируем, а составные команды переписываем в то, что SwiftMath понимает.
nonisolated enum MathCompat {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var registered = false
    nonisolated(unsafe) private static var stackedNames: [String: String] = [:]

    /// Готовит формулу для SwiftMath.
    static func prepare(_ latex: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        registerSymbols()
        return rewriteStacked(latex)
    }

    /// Формулы со стрелками-надписями лучше рисовать в «выключном» стиле: только в нём SwiftMath
    /// ставит надпись над стрелкой, а не сбоку.
    static func needsDisplayStyle(_ latex: String) -> Bool {
        ["\\overset", "\\underset", "\\stackrel", "\\xrightarrow", "\\xleftarrow"].contains { latex.contains($0) }
    }

    private static func registerSymbols() {
        guard !registered else { return }
        registered = true
        let symbols: [String: String] = [
            "rightleftharpoons": "\u{21CC}", "leftrightharpoons": "\u{21CB}",
            "rightleftarrows": "\u{21C4}", "leftrightarrows": "\u{21C6}",
            "implies": "\u{27F9}", "impliedby": "\u{27F8}", "iff": "\u{27FA}",
            "xrightarrow": "\u{2192}", "xleftarrow": "\u{2190}",
        ]
        // Конструктор MTMathAtom закрыт — берём копию готовой стрелки-отношения и меняем символ.
        for (name, value) in symbols where MTMathAtomFactory.atom(forLatexSymbol: name) == nil {
            guard let atom = MTMathAtomFactory.atom(forLatexSymbol: "rightarrow") else { continue }
            atom.nucleus = value
            MTMathAtomFactory.add(latexSymbol: name, value: atom)
        }
    }

    // MARK: - \overset{над}{знак}, \underset{под}{знак}, \stackrel, \xrightarrow[под]{над}

    private static func rewriteStacked(_ latex: String) -> String {
        let chars = Array(latex)
        var out = ""
        var i = 0
        while i < chars.count {
            guard chars[i] == "\\" else { out.append(chars[i]); i += 1; continue }
            let name = commandName(chars, at: i)
            switch name {
            case "overset", "stackrel", "underset":
                var j = i + 1 + name.count
                guard let (label, afterLabel) = group(chars, from: j),
                      let (base, afterBase) = group(chars, from: afterLabel) else { break }
                j = afterBase
                let script = name == "underset" ? "_" : "^"
                out += stacked(base: rewriteStacked(base)) + "\(script){\(rewriteStacked(label))}"
                i = j
                continue
            case "xrightarrow", "xleftarrow":
                var j = i + 1 + name.count
                var below: String?
                if let (b, after) = optionalGroup(chars, from: j) { below = b; j = after }
                guard let (above, after) = group(chars, from: j) else { break }
                j = after
                let arrow = name == "xrightarrow" ? "\\longrightarrow" : "\\longleftarrow"
                out += stacked(base: arrow) + "^{\(rewriteStacked(above))}"
                if let below { out += "_{\(rewriteStacked(below))}" }
                i = j
                continue
            default:
                break
            }
            // обычная команда — переносим как есть
            out += "\\" + name
            i += 1 + name.count
            if name.isEmpty, i < chars.count { out.append(chars[i]); i += 1 }
        }
        return out
    }

    /// Знак, над которым можно поставить надпись: оператор с «пределами», как у \sum.
    /// Если знак сложный (не один символ), надпись просто ставится сбоку.
    private static func stacked(base: String) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespaces)
        let glyph: String?
        if trimmed.hasPrefix("\\"), let atom = MTMathAtomFactory.atom(forLatexSymbol: String(trimmed.dropFirst())),
           atom.nucleus.count == 1 {
            glyph = atom.nucleus
        } else if trimmed.count == 1, let c = trimmed.first, "=<>+-~".contains(c) {
            glyph = c == "-" ? "\u{2212}" : String(c)
        } else {
            glyph = nil
        }
        guard let glyph else { return "{\(base)}" }
        if let name = stackedNames[glyph] { return "\\" + name }
        // имя команды — только буквы: кодируем символ шестнадцатеричными «буквами»
        let code = glyph.unicodeScalars.map { String($0.value, radix: 16) }.joined()
        let name = "shporastack" + String(code.map { c in Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(Int(String(c), radix: 16)!))) })
        MTMathAtomFactory.add(latexSymbol: name, value: MTMathAtomFactory.operatorWithName(glyph, limits: true))
        stackedNames[glyph] = name
        return "\\" + name
    }

    private static func commandName(_ chars: [Character], at i: Int) -> String {
        var j = i + 1
        var name = ""
        while j < chars.count, chars[j].isLetter { name.append(chars[j]); j += 1 }
        return name
    }

    private static func skipSpaces(_ chars: [Character], _ i: Int) -> Int {
        var i = i
        while i < chars.count, chars[i] == " " { i += 1 }
        return i
    }

    /// `{…}` с учётом вложенных скобок; одиночный символ или команда без скобок тоже подходят.
    private static func group(_ chars: [Character], from start: Int) -> (String, Int)? {
        let i = skipSpaces(chars, start)
        guard i < chars.count else { return nil }
        if chars[i] == "{" {
            var depth = 0
            var j = i
            while j < chars.count {
                if chars[j] == "\\", j + 1 < chars.count { j += 2; continue }
                if chars[j] == "{" { depth += 1 }
                if chars[j] == "}" { depth -= 1; if depth == 0 { return (String(chars[(i + 1)..<j]), j + 1) } }
                j += 1
            }
            return nil
        }
        if chars[i] == "\\" {
            let name = commandName(chars, at: i)
            return ("\\" + name, i + 1 + max(name.count, 1))
        }
        return (String(chars[i]), i + 1)
    }

    /// `[…]` — необязательный аргумент (подпись под стрелкой в \xrightarrow).
    private static func optionalGroup(_ chars: [Character], from start: Int) -> (String, Int)? {
        let i = skipSpaces(chars, start)
        guard i < chars.count, chars[i] == "[" else { return nil }
        guard let end = chars[i...].firstIndex(of: "]") else { return nil }
        return (String(chars[(i + 1)..<end]), end + 1)
    }
}
