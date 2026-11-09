import SwiftUI
import WatchConnectivity
import os

nonisolated let syncLog = Logger(subsystem: "com.kirill.Shpora", category: "sync")

/// Локальная копия библиотеки на часах, которую присылает iPhone.
@Observable
final class WatchStore: NSObject {
    nonisolated static let root: URL = {
        let url = URL.documentsDirectory.appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private(set) var revision = 0
    private(set) var missing: [String] = []
    var lastSync: Date? = UserDefaults.standard.object(forKey: "lastSync") as? Date {
        didSet { UserDefaults.standard.set(lastSync, forKey: "lastSync") }
    }

    let math = WatchMathCache()

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Попросить iPhone прислать изменения (или недостающие файлы).
    func requestSync() {
        send(missing.isEmpty ? ["sync": true] : [SyncKeys.need: missing])
    }

    func requestFull() {
        send([SyncKeys.requestFull: true])
    }

    private func send(_ message: [String: Any]) {
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        if session.isReachable {
            session.sendMessage(message, replyHandler: nil) { _ in session.transferUserInfo(message) }
        } else {
            session.transferUserInfo(message)
        }
    }

    /// Что уже дозапрашивали в этом запуске — чтобы не зациклиться на файле, который iPhone не может отдать.
    private var requested = Set<String>()

    fileprivate func didUpdate(missing newMissing: [String]? = nil) {
        if let newMissing {
            missing = newMissing
            // Файл мог потеряться (приложение закрыли посреди передачи) — просим его ещё раз.
            let ask = newMissing.filter { !requested.contains($0) }
            if !ask.isEmpty {
                requested.formUnion(ask)
                send([SyncKeys.need: ask])
            }
        }
        lastSync = .now
        math.reload()
        revision += 1
    }

    // MARK: - Работа с файлами (вызывается из фоновой очереди WatchConnectivity)

    nonisolated static func destination(for path: String) -> URL? {
        let parts = path.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { return nil }
        return parts.reduce(root) { $0.appendingPathComponent($1) }
    }

    nonisolated static func store(_ data: Data, at path: String) {
        guard let dest = destination(for: path) else { return }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            syncLog.error("store failed \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Удаляет файлы, которых больше нет на iPhone; возвращает недостающие.
    nonisolated static func apply(manifest: [String: String]) -> [String] {
        let fm = FileManager.default
        var present = Set<String>()
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in e {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true else { continue }
                let path = Library.relativePath(of: url, root: root)
                if manifest[path] == nil {
                    try? fm.removeItem(at: url)
                } else {
                    present.insert(path)
                }
            }
        }
        removeEmptyFolders(in: root)
        return manifest.keys.filter { !present.contains($0) }.sorted()
    }

    nonisolated private static func removeEmptyFolders(in folder: URL) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in items where (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            removeEmptyFolders(in: item)
            if (try? fm.contentsOfDirectory(atPath: item.path))?.isEmpty == true {
                try? fm.removeItem(at: item)
            }
        }
    }
}

extension WatchStore: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else { return }
        Task { @MainActor in
            // Первый запуск или переустановка — просим всё целиком, иначе сверяемся с iPhone:
            // он пришлёт изменения и список файлов, а недостающие часы дозапросят сами.
            if Library.allNotes(in: Self.root).isEmpty { requestFull() } else { requestSync() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // Файл нужно забрать до выхода из метода — потом система его удалит.
        guard let data = try? Data(contentsOf: file.fileURL) else { return }
        handle(data, metadata: file.metadata ?? [:])
    }

    /// Файлы, присланные сообщениями по кусочкам (когда часы на связи с iPhone).
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        defer { replyHandler([:]) }
        guard let chunk = message[SyncKeys.chunk] as? Data,
              let index = message[SyncKeys.index] as? Int,
              let count = message[SyncKeys.count] as? Int else { return }
        let key = (message[SyncKeys.path] as? String) ?? "manifest"
        if index == 0 { Self.pending[key] = Data() }
        Self.pending[key, default: Data()].append(chunk)
        if index == count - 1, let data = Self.pending.removeValue(forKey: key) {
            var metadata = message
            metadata[SyncKeys.chunk] = nil
            handle(data, metadata: metadata)
        }
    }

    /// Недособранные файлы. Делегат WatchConnectivity вызывается на одной последовательной очереди.
    nonisolated(unsafe) private static var pending: [String: Data] = [:]

    nonisolated private func handle(_ data: Data, metadata: [String: Any]) {
        if metadata[SyncKeys.kind] as? String == SyncKeys.manifestKind {
            guard let manifest = try? JSONDecoder().decode([String: String].self, from: data) else { return }
            let missing = Self.apply(manifest: manifest)
            Task { @MainActor in didUpdate(missing: missing) }
        } else if let path = metadata[SyncKeys.path] as? String {
            Self.store(data, at: path)
            Task { @MainActor in
                missing.removeAll { $0 == path }
                didUpdate()
            }
        }
    }
}

/// Формулы на часах — готовые картинки, отрисованные iPhone.
final class WatchMathCache {
    private var files: [String: (url: URL, descent: CGFloat, scale: CGFloat)] = [:]
    private var images: [String: RenderedMath] = [:]

    init() { reload() }

    func reload() {
        files.removeAll()
        images.removeAll()
        let folder = WatchStore.root.appendingPathComponent(SyncKeys.mathFolder)
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for url in urls {
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "~")
            guard parts.count == 3, let descent = Double(parts[1]), let scale = Double(parts[2]) else { continue }
            files[String(parts[0])] = (url, descent / 1000, max(scale, 1))
        }
    }

    /// `scale` — размер текста на часах: картинку формулы показываем крупнее или мельче.
    func provider(scale: CGFloat) -> MathProvider {
        MathProvider { [unowned self] latex, display in
            let key = Library.mathKey(latex, display: display) + "@\(scale)"
            if let cached = images[key] { return cached }
            guard let file = files[Library.mathKey(latex, display: display)],
                  let data = try? Data(contentsOf: file.url),
                  let image = UIImage(data: data, scale: file.scale / scale) else { return nil }
            let rendered = RenderedMath(image: image.withRenderingMode(.alwaysTemplate),
                                        descent: file.descent * scale)
            images[key] = rendered
            return rendered
        }
    }
}
