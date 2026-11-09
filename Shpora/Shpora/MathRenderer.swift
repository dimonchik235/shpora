import UIKit
import SwiftMath

/// Рисует LaTeX-формулы через SwiftMath.
nonisolated enum MathRenderer {
    static let inlineFont: CGFloat = 17
    static let displayFont: CGFloat = 20

    static func render(_ latex: String, display: Bool, fontSize: CGFloat) -> RenderedMath? {
        if latex.contains(where: { !supported($0) }), let mixed = renderMixed(latex, display: display, fontSize: fontSize) {
            return mixed
        }
        return renderMath(transliterated(latex), display: display, fontSize: fontSize)
    }

    private static func renderMath(_ latex: String, display: Bool, fontSize: CGFloat) -> RenderedMath? {
        let display = display || MathCompat.needsDisplayStyle(latex)
        var math = MathImage(latex: MathCompat.prepare(latex), fontSize: fontSize, textColor: .black,
                             labelMode: display ? .display : .text, textAlignment: .left)
        let (error, image, info) = math.asImage()
        guard error == nil, let image, let info else { return nil }
        return RenderedMath(image: image.withRenderingMode(.alwaysTemplate), descent: info.descent)
    }

    // MARK: - Буквы, которых нет в SwiftMath (ł, ś, ę, ą, ё…)

    /// SwiftMath молча выбрасывает символы, которых не знает: «Właściwości» превращается в «Waciwoci».
    private static let accented = Set("áéíóúýàèìòùâêîôûäëïöüÿãñõçøåæœßÁÉÍÓÚÝÀÈÌÒÙÂÊÎÔÛÄËÏÖÜÃÑÕÇØÅÆŒ")

    private static func supported(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1 else { return false }
        return v <= 0x7E || (0x410...0x44F).contains(v) || accented.contains(c)
    }

    /// Формула вида `\text{Słowo} \rightarrow \text{…}`: текст рисуем обычным шрифтом,
    /// математику — SwiftMath, и склеиваем по базовой линии.
    /// Возвращает nil, если `\text` с такими буквами спрятан внутри других команд (\frac{…} и т.п.).
    private static func renderMixed(_ latex: String, display: Bool, fontSize: CGFloat) -> RenderedMath? {
        guard let segments = topLevelSegments(latex) else { return nil }
        let font = UIFont.systemFont(ofSize: fontSize * (display ? 0.95 : 1))
        let serif = font.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: 0) } ?? font
        let gap = fontSize * 0.28

        // Каждый кусок — картинка + сдвиг базовой линии.
        var parts: [(image: UIImage, ascent: CGFloat, descent: CGFloat)] = []
        for segment in segments {
            switch segment {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let attributes: [NSAttributedString.Key: Any] = [.font: serif, .foregroundColor: UIColor.black]
                let size = (trimmed as NSString).size(withAttributes: attributes)
                let format = UIGraphicsImageRendererFormat()
                format.opaque = false
                let image = UIGraphicsImageRenderer(size: CGSize(width: ceil(size.width), height: ceil(serif.lineHeight)),
                                                    format: format).image { _ in
                    (trimmed as NSString).draw(at: .zero, withAttributes: attributes)
                }
                parts.append((image, serif.ascender, ceil(serif.lineHeight) - serif.ascender))
            case .math(let math):
                guard !math.trimmingCharacters(in: .whitespaces).isEmpty,
                      let r = renderMath(transliterated(math), display: display, fontSize: fontSize) else { continue }
                parts.append((r.image, r.image.size.height - r.descent, r.descent))
            }
        }
        guard !parts.isEmpty else { return nil }

        let ascent = parts.map(\.ascent).max()!
        let descent = parts.map(\.descent).max()!
        let width = parts.map(\.image.size.width).reduce(0, +) + gap * CGFloat(parts.count - 1)
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: ceil(width), height: ceil(ascent + descent)),
                                            format: format).image { _ in
            var x: CGFloat = 0
            for part in parts {
                part.image.draw(at: CGPoint(x: x, y: ascent - part.ascent))
                x += part.image.size.width + gap
            }
        }
        return RenderedMath(image: image.withRenderingMode(.alwaysTemplate), descent: descent)
    }

    private enum Segment { case text(String), math(String) }

    /// Делит формулу на `\text{…}` верхнего уровня и остальное.
    private static func topLevelSegments(_ latex: String) -> [Segment]? {
        let chars = Array(latex)
        var segments: [Segment] = []
        var math = ""
        var depth = 0
        var i = 0
        let commands = ["\\text{", "\\textrm{", "\\textbf{", "\\mathrm{"]
        while i < chars.count {
            if let command = commands.first(where: { matches($0, chars, at: i) }) {
                var j = i + command.count
                var level = 1
                var text = ""
                while j < chars.count {
                    if chars[j] == "{" { level += 1 } else if chars[j] == "}" { level -= 1; if level == 0 { break } }
                    text.append(chars[j])
                    j += 1
                }
                if depth > 0 {
                    // \text внутри \frac{…} — склеить не получится
                    if text.contains(where: { !supported($0) }) { return nil }
                    math += String(chars[i...min(j, chars.count - 1)])
                } else {
                    if !math.isEmpty { segments.append(.math(math)); math = "" }
                    segments.append(.text(text))
                }
                i = j + 1
                continue
            }
            if chars[i] == "{" { depth += 1 } else if chars[i] == "}" { depth -= 1 }
            math.append(chars[i])
            i += 1
        }
        if !math.isEmpty { segments.append(.math(math)) }
        return segments
    }

    private static func matches(_ word: String, _ chars: [Character], at i: Int) -> Bool {
        let w = Array(word)
        return i + w.count <= chars.count && Array(chars[i..<(i + w.count)]) == w
    }

    /// Последний вариант — заменить неизвестные буквы на похожие латинские, чтобы они хотя бы не пропадали.
    private static func transliterated(_ latex: String) -> String {
        String(latex.map { c -> Character in
            if supported(c) { return c }
            switch c {
            case "ł": return "l"
            case "Ł": return "L"
            case "ё": return "е"
            case "Ё": return "Е"
            default:
                let folded = String(c).folding(options: .diacriticInsensitive, locale: nil)
                return folded.count == 1 && supported(folded.first!) ? folded.first! : c
            }
        })
    }
}

/// Кэш формул для экранов iPhone.
final class PhoneMathCache {
    static let shared = PhoneMathCache()
    private var cache: [String: RenderedMath] = [:]
    private var failed: Set<String> = []

    lazy var provider = MathProvider { [unowned self] latex, display in
        let key = (display ? "d:" : "i:") + latex
        if let cached = cache[key] { return cached }
        if failed.contains(key) { return nil }
        let rendered = MathRenderer.render(latex, display: display,
                                           fontSize: display ? MathRenderer.displayFont : MathRenderer.inlineFont)
        if let rendered { cache[key] = rendered } else { failed.insert(key) }
        return rendered
    }
}
