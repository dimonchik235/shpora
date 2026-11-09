import Foundation
import CryptoKit

/// Элемент библиотеки: папка (тема/раздел) или запись (.md файл).
nonisolated struct LibraryItem: Identifiable, Hashable, Sendable {
    let url: URL
    let isFolder: Bool

    var id: URL { url }

    var name: String {
        isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }
}

nonisolated enum Library {
    static let noteExtensions: Set<String> = ["md", "markdown"]
    /// Служебные папки с картинками, которые не показываются как разделы.
    static let attachmentFolders: Set<String> = ["images", "image", "img", "assets", "attachments", "media"]

    static func isHidden(_ name: String) -> Bool {
        name.hasPrefix("_") || attachmentFolders.contains(name.lowercased())
            || (name.hasPrefix(".") && !name.hasSuffix(".icloud"))
    }

    /// Возвращает настоящий URL для плейсхолдера iCloud (`.Name.md.icloud` → `Name.md`).
    static func resolvePlaceholder(_ url: URL) -> URL {
        let name = url.lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return url }
        let real = String(name.dropFirst().dropLast(".icloud".count))
        return url.deletingLastPathComponent().appendingPathComponent(real)
    }

    static func contents(of folder: URL) -> (folders: [LibraryItem], notes: [LibraryItem]) {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var folders: [LibraryItem] = []
        var notes: [LibraryItem] = []
        var seen = Set<URL>()
        for raw in urls {
            let url = resolvePlaceholder(raw)
            let name = url.lastPathComponent
            guard !isHidden(name), seen.insert(url).inserted else { continue }
            let isDir = (try? raw.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                folders.append(LibraryItem(url: url, isFolder: true))
            } else if noteExtensions.contains(url.pathExtension.lowercased()) {
                notes.append(LibraryItem(url: url, isFolder: false))
            }
        }
        let order: (LibraryItem, LibraryItem) -> Bool = {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return (folders.sorted(by: order), notes.sorted(by: order))
    }

    /// Все записи внутри папки (рекурсивно).
    static func allNotes(in folder: URL) -> [LibraryItem] {
        let (folders, notes) = contents(of: folder)
        return notes + folders.flatMap { allNotes(in: $0.url) }
    }

    /// Количество записей внутри папки (рекурсивно).
    static func noteCount(in folder: URL) -> Int { allNotes(in: folder).count }

    static func relativePath(of url: URL, root: URL) -> String {
        let r = root.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let u = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard u.starts(with: r) else { return url.lastPathComponent }
        return u.dropFirst(r.count).joined(separator: "/")
    }

    /// Находит файл картинки по ссылке из Markdown.
    static func resolveImage(_ source: String, noteFolder: URL, root: URL) -> URL? {
        let decoded = source.removingPercentEncoding ?? source
        if decoded.hasPrefix("http://") || decoded.hasPrefix("https://") { return URL(string: source) }
        let fm = FileManager.default
        let candidates: [URL] = decoded.hasPrefix("/")
            ? [root.appendingPathComponent(String(decoded.dropFirst()))]
            : [noteFolder.appendingPathComponent(decoded),
               root.appendingPathComponent(decoded)]
                + attachmentFolders.map { noteFolder.appendingPathComponent($0).appendingPathComponent(decoded) }
        for c in candidates where fm.fileExists(atPath: c.path) || fm.fileExists(atPath: placeholder(for: c).path) {
            return c.standardizedFileURL
        }
        // Как в Obsidian — ищем по имени файла по всей библиотеке.
        let fileName = (decoded as NSString).lastPathComponent
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in e where resolvePlaceholder(url).lastPathComponent == fileName {
                return resolvePlaceholder(url)
            }
        }
        return nil
    }

    static func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".icloud")
    }

    /// Ключ формулы для готовых картинок на часах.
    static func mathKey(_ latex: String, display: Bool) -> String {
        let digest = SHA256.hash(data: Data(((display ? "d:" : "i:") + latex).utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// Протокол синхронизации iPhone → часы.
nonisolated enum SyncKeys {
    static let path = "path"
    static let version = "version"
    static let kind = "kind"
    static let manifestKind = "manifest"
    static let need = "need"
    static let requestFull = "requestFull"
    static let mathFolder = "_math"
    static let chunk = "chunk"
    static let index = "index"
    static let count = "count"
    /// Размер шрифта формул, отрисованных для часов.
    static let watchInlineFont: CGFloat = 15
    static let watchDisplayFont: CGFloat = 17
}
