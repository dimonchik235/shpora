import SwiftUI
import UIKit

enum Route: Hashable {
    case folder(URL)
    case note(URL, edit: Bool)
}

/// Хранилище записей: папка в iCloud Drive (видна на Mac в Finder → iCloud Drive → Шпора)
/// или локальная папка «На iPhone», если iCloud недоступен.
@Observable
final class LibraryStore {
    private(set) var root: URL?
    private(set) var isICloud = false
    /// Увеличивается при любом изменении — экраны перечитывают файлы.
    private(set) var revision = 0
    var path: [Route] = []

    func setup() async {
        guard root == nil else { return }
        let container = await Task.detached {
            FileManager.default.url(forUbiquityContainerIdentifier: nil)
        }.value
        let url: URL
        if let container {
            url = container.appendingPathComponent("Documents", isDirectory: true)
            isICloud = true
        } else {
            url = URL.documentsDirectory
        }
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = url
        downloadAll()
        if !UserDefaults.standard.bool(forKey: "seeded") {
            UserDefaults.standard.set(true, forKey: "seeded")
            if Library.allNotes(in: url).isEmpty { SampleContent.create(in: url) }
        }
        #if DEBUG
        // Отладка: xcrun simctl launch … -openNote "Биология/Кости/Функции костей.md"
        if let note = UserDefaults.standard.string(forKey: "openNote") {
            path = [.note(url.appendingPathComponent(note), edit: UserDefaults.standard.bool(forKey: "edit"))]
        }
        // Отладка: xcrun simctl launch … -importZip /путь/к/архиву.zip — как «Импорт из Файлов» в корень
        if let zip = UserDefaults.standard.string(forKey: "importZip") {
            importItems([URL(fileURLWithPath: zip)], into: url)
        }
        #endif
        changed()
    }

    /// Перечитать всё и докачать файлы из iCloud.
    func refresh() {
        downloadAll()
        changed()
    }

    func changed() {
        revision += 1
        WatchSync.shared.scheduleSync()
    }

    /// Просим iCloud скачать все файлы, которых ещё нет на телефоне.
    private func downloadAll() {
        guard isICloud, let root else { return }
        Task.detached { Self.downloadPlaceholders(in: root) }
    }

    nonisolated private static func downloadPlaceholders(in root: URL) {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in e where url.lastPathComponent.hasSuffix(".icloud") {
            try? fm.startDownloadingUbiquitousItem(at: Library.resolvePlaceholder(url))
        }
    }

    // MARK: - Файлы

    func read(_ url: URL) async -> String {
        await ImageLoader.ensureDownloaded(url)
        return await Task.detached {
            var result = ""
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { u in
                result = (try? String(contentsOf: u, encoding: .utf8)) ?? ""
            }
            return result
        }.value
    }

    func write(_ text: String, to url: URL) {
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: nil) { u in
            try? text.write(to: u, atomically: true, encoding: .utf8)
        }
        changed()
    }

    @discardableResult
    func createFolder(named name: String, in parent: URL) -> URL? {
        let url = uniqueURL(parent.appendingPathComponent(sanitize(name), isDirectory: true))
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            changed()
            return url
        } catch { return nil }
    }

    @discardableResult
    func createNote(named name: String, in parent: URL) -> URL? {
        let clean = sanitize(name)
        let url = uniqueURL(parent.appendingPathComponent(clean).appendingPathExtension("md"))
        do {
            try "# \(clean)\n\n".write(to: url, atomically: true, encoding: .utf8)
            changed()
            return url
        } catch { return nil }
    }

    func rename(_ item: LibraryItem, to name: String) {
        var target = item.url.deletingLastPathComponent().appendingPathComponent(sanitize(name))
        if !item.isFolder { target.appendPathExtension(item.url.pathExtension) }
        guard target != item.url else { return }
        target = uniqueURL(target)
        NSFileCoordinator().coordinate(writingItemAt: item.url, options: .forMoving,
                                       writingItemAt: target, options: .forReplacing, error: nil) { from, to in
            try? FileManager.default.moveItem(at: from, to: to)
        }
        changed()
    }

    func delete(_ item: LibraryItem) {
        NSFileCoordinator().coordinate(writingItemAt: item.url, options: .forDeleting, error: nil) { u in
            try? FileManager.default.removeItem(at: u)
        }
        changed()
    }

    /// Импорт .md файлов, картинок и целых папок (например, из Файлов или с Mac).
    func importItems(_ urls: [URL], into folder: URL) {
        let fm = FileManager.default
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { u in
                if u.pathExtension.lowercased() == "zip" {
                    do {
                        try importZip(u, into: folder)
                    } catch {
                        importError = "«\(u.lastPathComponent)»: \(error.localizedDescription)"
                    }
                    return
                }
                let target = uniqueURL(folder.appendingPathComponent(u.lastPathComponent))
                try? fm.copyItem(at: u, to: target)
            }
        }
        changed()
    }

    /// Ошибка последнего импорта — показывается алертом.
    var importError: String?

    /// Раздел из .zip (формат описан в ZIP-ФОРМАТ.md). Если в архиве одна папка верхнего
    /// уровня — она и становится разделом, иначе раздел называется по имени архива.
    private func importZip(_ zip: URL, into folder: URL) throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: temp) }
        try ZipReader.extract(zip, to: temp)

        let top = (try? fm.contentsOfDirectory(at: temp, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        let source: URL
        if top.count == 1, (try? top[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            source = top[0]
        } else {
            guard !top.isEmpty else { throw ZipReader.ZipError.corrupted("архив пустой") }
            source = temp
        }
        let name = source == temp ? zip.deletingPathExtension().lastPathComponent : source.lastPathComponent
        let target = uniqueURL(folder.appendingPathComponent(name, isDirectory: true))
        var moveError: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: [], error: nil) { t in
            do { try fm.moveItem(at: source, to: t) } catch { moveError = error }
        }
        if let moveError { throw moveError }
    }

    /// Сохраняет фото рядом с записью в папку images и возвращает относительный путь для Markdown.
    func saveImage(_ data: Data, forNote note: URL) -> String? {
        guard let image = ImageLoader.downsample(data: data, maxPixel: 2560),
              let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        let folder = note.deletingLastPathComponent().appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "img-" + Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .timeSeparator(.omitted).dateSeparator(.omitted).dateTimeSeparator(.standard)) + ".jpg"
        let url = uniqueURL(folder.appendingPathComponent(name))
        do {
            try jpeg.write(to: url)
            return "images/" + url.lastPathComponent
        } catch { return nil }
    }

    private func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Без названия" : cleaned
    }
}

/// Если файл уже существует — добавляет « 2», « 3»…
nonisolated func uniqueURL(_ url: URL) -> URL {
    let fm = FileManager.default
    guard fm.fileExists(atPath: url.path) else { return url }
    let ext = url.pathExtension
    let base = url.deletingPathExtension().lastPathComponent
    let folder = url.deletingLastPathComponent()
    var n = 2
    while true {
        var candidate = folder.appendingPathComponent("\(base) \(n)")
        if !ext.isEmpty { candidate.appendPathExtension(ext) }
        if !fm.fileExists(atPath: candidate.path) { return candidate }
        n += 1
    }
}
