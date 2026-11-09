import SwiftUI
import UIKit
import ImageIO

// MARK: - Формулы

nonisolated struct RenderedMath {
    let image: UIImage
    /// Насколько формула опускается ниже базовой линии текста.
    let descent: CGFloat
}

/// Отрисовщик формул: на iPhone — SwiftMath, на часах — готовые картинки с iPhone.
struct MathProvider {
    var render: (_ latex: String, _ display: Bool) -> RenderedMath?

    static let none = MathProvider { _, _ in nil }
}

extension EnvironmentValues {
    @Entry var mathProvider: MathProvider = .none
    /// Корень библиотеки — для поиска картинок.
    @Entry var libraryRoot: URL? = nil
    /// Масштаб содержимого записи (на часах настраивается пользователем).
    @Entry var contentScale: CGFloat = 1
}

// MARK: - Документ

struct MarkdownView: View {
    let blocks: [MDBlock]
    @Environment(\.contentScale) private var scale
    /// Папка, в которой лежит запись (относительно неё ищутся картинки).
    let noteFolder: URL

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                MarkdownBlockView(block: block, noteFolder: noteFolder)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(watchOS)
        .font(MDFont.style(.body, scale: scale))
        #endif
    }
}

/// Шрифты записи. На часах размеры задаются явно и умножаются на `contentScale`,
/// чтобы текст можно было сделать мельче, чем позволяет Dynamic Type.
enum MDFont {
    static func style(_ style: Font.TextStyle, scale: CGFloat, weight: Font.Weight = .regular,
                      design: Font.Design = .default) -> Font {
        #if os(watchOS)
        let size: CGFloat = switch style {
        case .title3: 20
        case .body, .headline: 17
        case .callout: 16
        case .subheadline: 15
        case .footnote: 14
        case .caption, .caption2: 12
        default: 17
        }
        return .system(size: size * scale, weight: style == .headline && weight == .regular ? .semibold : weight,
                       design: design)
        #else
        return .system(style, design: design, weight: weight)
        #endif
    }
}

enum Metrics {
    #if os(watchOS)
    static let blockSpacing: CGFloat = 8
    static let indent: CGFloat = 10
    static let cellPadding: CGFloat = 5
    #else
    static let blockSpacing: CGFloat = 14
    static let indent: CGFloat = 18
    static let cellPadding: CGFloat = 8
    #endif
}

struct MarkdownBlockView: View {
    let block: MDBlock
    let noteFolder: URL
    @Environment(\.mathProvider) private var math
    @Environment(\.contentScale) private var scale

    var body: some View {
        switch block {
        case .heading(let level, let text):
            InlineText(text: text)
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 6 : 2)

        case .paragraph(let text):
            RichText(text: text)

        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        marker(for: item)
                        RichText(text: item.text)
                            .strikethrough(item.checked == true)
                            .foregroundStyle(item.checked == true ? .secondary : .primary)
                    }
                    .padding(.leading, CGFloat(item.indent) * Metrics.indent)
                }
            }

        case .quote(let inner):
            if let callout = Callout(inner) {
                CalloutView(callout: callout, noteFolder: noteFolder)
            } else {
                quote(inner)
            }

        case .code(_, let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: text)
                    .font(MDFont.style(.footnote, scale: scale, design: .monospaced))
                    .padding(Metrics.cellPadding)
            }
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))

        case .math(let latex):
            MathBlockView(latex: latex)

        case .table(let table):
            MarkdownTableView(table: table)

        case .image(let alt, let source):
            NoteImageView(source: source, alt: alt, noteFolder: noteFolder)

        case .rule:
            Divider()
        }
    }

    private func quote(_ inner: [MDBlock]) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.tint)
                .frame(width: 3)
            MarkdownView(blocks: inner, noteFolder: noteFolder)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func headingFont(_ level: Int) -> Font {
        #if os(watchOS)
        switch level {
        case 1: return MDFont.style(.title3, scale: scale, weight: .bold)
        case 2: return MDFont.style(.headline, scale: scale)
        default: return MDFont.style(.subheadline, scale: scale, weight: .bold)
        }
        #else
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .title3.bold()
        default: return .headline
        }
        #endif
    }

    @ViewBuilder
    private func marker(for item: MDListItem) -> some View {
        if let checked = item.checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        } else if let number = item.number {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
        } else {
            Text(item.indent == 0 ? "•" : "◦").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Блоки-выноски Obsidian: > [!NOTE], > [!TIP], > [!IMPORTANT], > [!WARNING]…

struct Callout {
    let kind: String
    let title: String
    let blocks: [MDBlock]

    /// Цитата становится выноской, если первая строка — `[!тип]` (после него может идти свой заголовок).
    init?(_ blocks: [MDBlock]) {
        guard case .paragraph(let first)? = blocks.first,
              let match = first.firstMatch(of: /^\[!(\w+)\][+-]?[ \t]*([^\n]*)\n?/) else { return nil }
        kind = String(match.1).lowercased()
        let custom = String(match.2).trimmingCharacters(in: .whitespaces)
        title = custom.isEmpty ? Self.defaultTitle(kind) : custom
        let rest = String(first[match.range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        self.blocks = (rest.isEmpty ? [] : [.paragraph(rest)]) + blocks.dropFirst()
    }

    private static func defaultTitle(_ kind: String) -> String {
        switch kind {
        case "tip", "hint": "Tip"
        case "important": "Important"
        case "warning", "caution", "attention": "Warning"
        case "danger", "error": "Danger"
        case "example": "Example"
        case "question", "help", "faq": "Question"
        case "success", "check", "done": "Success"
        case "quote", "cite": "Quote"
        case "abstract", "summary", "tldr": "Summary"
        default: kind.prefix(1).uppercased() + kind.dropFirst()
        }
    }

    var icon: String {
        switch kind {
        case "tip", "hint": "flame.fill"
        case "important": "exclamationmark.bubble.fill"
        case "warning", "caution", "attention": "exclamationmark.triangle.fill"
        case "danger", "error": "bolt.fill"
        case "example": "list.bullet"
        case "question", "help", "faq": "questionmark.circle.fill"
        case "success", "check", "done": "checkmark.circle.fill"
        case "quote", "cite": "quote.opening"
        case "abstract", "summary", "tldr": "doc.text.fill"
        default: "info.circle.fill"
        }
    }

    var color: Color {
        switch kind {
        case "tip", "hint", "success", "check", "done": .teal
        case "important": .purple
        case "warning", "caution", "attention": .orange
        case "danger", "error": .red
        case "example": .indigo
        case "quote", "cite": .gray
        default: .blue
        }
    }
}

struct CalloutView: View {
    let callout: Callout
    let noteFolder: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(callout.title, systemImage: callout.icon)
                .font(.headline)
                .foregroundStyle(callout.color)
            if !callout.blocks.isEmpty {
                MarkdownView(blocks: callout.blocks, noteFolder: noteFolder)
            }
        }
        .padding(Metrics.cellPadding * 1.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(callout.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8)
                .fill(callout.color)
                .frame(width: 3)
        }
    }
}

// MARK: - Текст со встроенным форматированием и формулами

struct InlineText: View {
    let text: String
    @Environment(\.mathProvider) private var math

    var body: some View {
        Self.build(text, math: math)
            .fixedSize(horizontal: false, vertical: true)
            #if os(iOS)
            .textSelection(.enabled)
            #endif
    }

    static func build(_ text: String, math: MathProvider) -> Text {
        var result = Text(verbatim: "")
        let segments = InlineMath.segments(text)
        // **жирный** может охватывать формулу: «**0 ≤ $pH$ < 7**». Звёздочки тогда попадают в разные
        // куски текста, и разбор Markdown по кускам их не видит — поэтому жирность считаем сами.
        let markers = segments.reduce(0) { count, segment in
            guard case .text(let t) = segment else { return count }
            return count + t.replacingOccurrences(of: "==", with: "**").components(separatedBy: "**").count - 1
        }
        let spansMath = markers.isMultiple(of: 2) && segments.count > 1
        var bold = false
        for segment in segments {
            switch segment {
            case .text(let string) where spansMath:
                let pieces = string.replacingOccurrences(of: "==", with: "**").components(separatedBy: "**")
                for (index, piece) in pieces.enumerated() {
                    if index > 0 { bold.toggle() }
                    guard !piece.isEmpty else { continue }
                    let part = Text(attributed(piece))
                    result = Text("\(result)\(bold ? part.bold() : part)")
                }
            case .text(let string):
                result = Text("\(result)\(Text(attributed(string)))")
            case .math(let latex), .display(let latex):
                let display = if case .display = segment { true } else { false }
                if let rendered = math.render(latex, display) {
                    let image = Text(Image(uiImage: rendered.image).renderingMode(.template))
                        .baselineOffset(-rendered.descent)
                    result = Text("\(result)\(image)")
                } else {
                    result = Text("\(result)\(Text(verbatim: latex).font(.system(.body, design: .monospaced)))")
                }
            }
        }
        return result
    }

    static func attributed(_ string: String) -> AttributedString {
        // ==выделение== из Obsidian превращаем в жирный текст
        let prepared = string.replacingOccurrences(of: "==", with: "**")
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        return (try? AttributedString(markdown: prepared, options: options)) ?? AttributedString(string)
    }
}

/// Текст, внутри которого могут быть формулы `$$…$$`: они выносятся отдельной строкой, как в Obsidian.
struct RichText: View {
    let text: String

    private enum Part { case text(String), display(String) }

    var body: some View {
        let parts = Self.parts(of: text)
        if parts.count == 1, case .text(let only) = parts[0] {
            InlineText(text: only)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .text(let t): InlineText(text: t)
                    case .display(let latex): MathBlockView(latex: latex)
                    }
                }
            }
        }
    }

    private static func parts(of text: String) -> [Part] {
        var parts: [Part] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { parts.append(.text(trimmed)) }
            current = ""
        }
        for segment in InlineMath.segments(text) {
            switch segment {
            case .text(let t): current += t
            case .math(let latex): current += "$\(latex)$"
            case .display(let latex):
                flush()
                parts.append(.display(latex))
            }
        }
        flush()
        return parts.isEmpty ? [.text("")] : parts
    }
}

// MARK: - Формула отдельной строкой

struct MathBlockView: View {
    let latex: String
    @Environment(\.mathProvider) private var math
    @State private var showFull = false

    var body: some View {
        if let rendered = math.render(latex, true) {
            ScrollView(.horizontal, showsIndicators: false) {
                Image(uiImage: rendered.image)
                    .renderingMode(.template)
                    .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { showFull = true }
            .zoomCover(isPresented: $showFull) {
                ZoomableImageScreen(image: rendered.image, template: true)
            }
        } else {
            Text(verbatim: latex)
                .font(.system(.callout, design: .monospaced))
                .padding(Metrics.cellPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

// MARK: - Таблица

struct MarkdownTableView: View {
    let table: MDTable
    @State private var showFull = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: true) {
                TableGrid(table: table)
            }
            .onTapGesture { showFull = true }
            Label("Нажмите, чтобы развернуть", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.caption2)
                .foregroundStyle(.secondary)
                #if os(watchOS)
                .labelStyle(.iconOnly)
                #endif
        }
        .zoomCover(isPresented: $showFull) {
            FullTableScreen(table: table)
        }
        #if DEBUG
        // Отладка: xcrun simctl launch … -openNote … -openTable YES — сразу развернуть первую таблицу
        .onAppear {
            if UserDefaults.standard.bool(forKey: "openTable"), !Self.debugOpened {
                Self.debugOpened = true
                showFull = true
            }
        }
        #endif
    }

    #if DEBUG
    private static var debugOpened = false
    #endif
}

struct TableGrid: View {
    let table: MDTable
    var fontScale: CGFloat = 1
    @Environment(\.contentScale) private var contentScale

    var body: some View {
        let columns = table.columnCount
        let widths = columnWidths(fontSize: fontSize)
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<columns, id: \.self) { c in
                    cell(table.header[safe: c] ?? "", column: c, width: widths[c])
                        .bold()
                        .background(.tint.opacity(0.18))
                }
            }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { r, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { c in
                        cell(row[safe: c] ?? "", column: c, width: widths[c])
                            .background(r.isMultiple(of: 2) ? Color.clear : Color.secondary.opacity(0.08))
                    }
                }
            }
        }
        .fixedSize()
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.4), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var fontSize: CGFloat { baseFontSize * fontScale * contentScale }
    private var padding: CGFloat { Metrics.cellPadding * fontScale }

    private func cell(_ text: String, column: Int, width: CGFloat) -> some View {
        let alignment: Alignment = switch table.alignments[safe: column] ?? .leading {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
        // Ширина колонки задана заранее: тогда Grid правильно считает высоту строки
        // с переносами, и длинный текст не налезает на соседние строки.
        return InlineText(text: text.replacingOccurrences(of: "<br>", with: "\n"))
            .font(.system(size: fontSize))
            .frame(width: width, alignment: alignment)
            .padding(padding)
            .frame(maxHeight: .infinity, alignment: alignment)
            .border(.secondary.opacity(0.25), width: 0.5)
    }

    /// Ширина колонок по содержимому: короткие колонки узкие, длинный текст переносится
    /// по `maxColumnWidth`, но колонка не уже самого длинного слова.
    private func columnWidths(fontSize: CGFloat) -> [CGFloat] {
        let font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
        let maxWidth = maxColumnWidth * fontScale * contentScale
        let minWidth = fontSize * 2
        func width(_ s: String) -> CGFloat {
            ceil((s as NSString).size(withAttributes: [.font: font]).width)
        }
        return (0..<table.columnCount).map { c in
            var full: CGFloat = 0
            var word: CGFloat = 0
            for raw in [table.header[safe: c] ?? ""] + table.rows.map({ $0[safe: c] ?? "" }) {
                for line in Self.plain(raw).components(separatedBy: "\n") {
                    full = max(full, width(line))
                    for w in line.split(separator: " ") { word = max(word, width(String(w))) }
                }
            }
            return min(max(full, word, minWidth), max(maxWidth, word)) + 2
        }
    }

    /// Текст ячейки без разметки — для оценки ширины.
    private static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "==", with: "")
            .replacingOccurrences(of: #"(?<!\\)[*_`$]"#, with: "", options: .regularExpression)
    }

    private var maxColumnWidth: CGFloat {
        #if os(watchOS)
        150
        #else
        220
        #endif
    }

    private var baseFontSize: CGFloat {
        #if os(watchOS)
        13
        #else
        15
        #endif
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Картинка в записи

struct NoteImageView: View {
    let source: String
    let alt: String
    let noteFolder: URL

    @Environment(\.libraryRoot) private var root
    @State private var image: UIImage?
    @State private var failed = false
    @State private var showFull = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: .infinity)
                    .onTapGesture { showFull = true }
                    .zoomCover(isPresented: $showFull) {
                        FullImageLoader(url: resolvedURL)
                    }
            } else if failed {
                Label(alt.isEmpty ? source : alt, systemImage: "photo.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary)
                    .frame(height: 120)
                    .overlay(ProgressView())
            }
        }
        .task(id: source) {
            guard let url = resolvedURL else { failed = true; return }
            image = await ImageLoader.load(url, maxPixel: ImageLoader.previewPixels)
            failed = image == nil
        }
    }

    private var resolvedURL: URL? {
        Library.resolveImage(source, noteFolder: noteFolder, root: root ?? noteFolder)
    }
}

/// Полноэкранный просмотр картинки в полном разрешении.
struct FullImageLoader: View {
    let url: URL?
    @State private var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let image {
                ZoomableImageScreen(image: image, template: false)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.black)
                    .onTapGesture { dismiss() }
            }
        }
        .task {
            if let url { image = await ImageLoader.load(url, maxPixel: ImageLoader.fullPixels) }
        }
    }
}

nonisolated enum ImageLoader {
    #if os(watchOS)
    static let previewPixels = 400
    static let fullPixels = 1600
    #else
    static let previewPixels = 1400
    static let fullPixels = 4096
    #endif

    static func load(_ url: URL, maxPixel: Int) async -> UIImage? {
        if url.scheme == "http" || url.scheme == "https" {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            return downsample(data: data, maxPixel: maxPixel)
        }
        return await Task.detached(priority: .userInitiated) {
            await ensureDownloaded(url)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return downsample(data: data, maxPixel: maxPixel)
        }.value
    }

    /// Если файл ещё в iCloud и не скачан — скачиваем и ждём.
    static func ensureDownloaded(_ url: URL) async {
        #if os(iOS)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { return }
        try? fm.startDownloadingUbiquitousItem(at: url)
        for _ in 0..<60 where !fm.fileExists(atPath: url.path) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        #endif
    }

    static func downsample(data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
