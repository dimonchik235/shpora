import SwiftUI
import WatchConnectivity

/// Отправляет записи, картинки и формулы на Apple Watch.
/// Шлются только изменившиеся файлы; список всех файлов (манифест) позволяет часам удалить лишнее.
@Observable
final class WatchSync: NSObject {
    static let shared = WatchSync()

    private(set) var status = "Часы не подключены"
    private(set) var isSyncing = false
    private(set) var lastSync: Date?

    private var root: URL?
    private var pendingSync: Task<Void, Never>?
    /// path → version уже доставленных на часы файлов.
    private var sent: [String: String] = UserDefaults.standard.dictionary(forKey: "watchSent") as? [String: String] ?? [:]
    /// path → version файлов в пути.
    private var inFlight: [String: String] = [:]

    private let outbox = URL.cachesDirectory.appendingPathComponent("WatchOutbox", isDirectory: true)

    func start(root: URL) {
        self.root = root
        guard WCSession.isSupported() else { status = "Часы не поддерживаются"; return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func scheduleSync() {
        pendingSync?.cancel()
        pendingSync = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await sync()
        }
    }

    /// Отправить всё заново (если на часах что-то потерялось).
    func resendAll() {
        sent.removeAll()
        persist()
        Task { await sync() }
    }

    func sync() async {
        guard let root, WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { status = "Подключение к часам…"; return }
        guard session.isPaired else { status = "Часы не подключены"; return }
        guard session.isWatchAppInstalled else { status = "Приложение не установлено на часах"; return }
        guard !isSyncing else { return }

        isSyncing = true
        status = "Синхронизация…"
        defer { isSyncing = false }

        let entries = await Task.detached { WatchExport.collect(root: root) }.value
        let sentNow = sent, inFlightNow = inFlight, outbox = outbox
        // Сначала текст, потом формулы и только потом тяжёлые картинки — записи появляются на часах быстрее.
        let changed = entries
            .filter { sentNow[$0.path] != $0.version && inFlightNow[$0.path] != $0.version }
            .sorted { ($0.priority, $0.path) < ($1.priority, $1.path) }

        let manifest = Dictionary(entries.map { ($0.path, $0.version) }, uniquingKeysWith: { a, _ in a })
        let manifestData = (try? JSONEncoder().encode(manifest)) ?? Data()

        if session.isReachable {
            // Часы на связи — шлём сразу сообщениями (быстро, работает и в симуляторе).
            // Каждый файл готовим прямо перед отправкой, чтобы первые записи пришли не дожидаясь картинок.
            var failed = false
            for entry in changed where !failed {
                guard let data = await Task.detached(operation: { entry.produce() }).value else { continue }
                if await sendViaMessages(data, metadata: [SyncKeys.path: entry.path, SyncKeys.version: entry.version]) {
                    sent[entry.path] = entry.version
                    persist()
                } else {
                    failed = true
                }
            }
            if !failed, await sendViaMessages(manifestData, metadata: [SyncKeys.kind: SyncKeys.manifestKind]) {
                lastSync = .now
                status = "На часах актуально"
                return
            }
            status = "Связь с часами прервалась, повторю позже"
            return
        }

        // Часы не на связи — фоновая передача файлов, дойдёт, когда часы проснутся.
        // Готовим файлы в фоне (сжатие картинок, рендер формул).
        let prepared: [(WatchExport.Entry, URL)] = await Task.detached {
            try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
            return changed.compactMap { entry in
                guard let data = entry.produce() else { return nil }
                let file = outbox.appendingPathComponent(UUID().uuidString)
                guard (try? data.write(to: file)) != nil else { return nil }
                return (entry, file)
            }
        }.value

        for (entry, file) in prepared {
            inFlight[entry.path] = entry.version
            session.transferFile(file, metadata: [SyncKeys.path: entry.path, SyncKeys.version: entry.version])
        }
        let file = outbox.appendingPathComponent("manifest-" + UUID().uuidString)
        if (try? manifestData.write(to: file)) != nil {
            session.transferFile(file, metadata: [SyncKeys.kind: SyncKeys.manifestKind])
        }

        lastSync = .now
        let notes = entries.filter { $0.path.hasSuffix(".md") || $0.path.hasSuffix(".markdown") }.count
        status = prepared.isEmpty
            ? "На часах актуально · \(notes) зап."
            : "Отправляется \(prepared.count) файл(ов) · \(notes) зап."
    }

    /// Отправка данных сообщениями по кусочкам (лимит размера одного сообщения ~64 КБ).
    private func sendViaMessages(_ data: Data, metadata: [String: Any]) async -> Bool {
        let chunkSize = 48_000
        let count = max(1, (data.count + chunkSize - 1) / chunkSize)
        for index in 0..<count {
            var message = metadata
            message[SyncKeys.chunk] = data.subdata(in: index * chunkSize..<min(data.count, (index + 1) * chunkSize))
            message[SyncKeys.index] = index
            message[SyncKeys.count] = count
            let delivered = await Self.send(message)
            if !delivered { return false }
        }
        return true
    }

    nonisolated private static func send(_ message: [String: Any]) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            WCSession.default.sendMessage(message,
                                          replyHandler: { @Sendable _ in continuation.resume(returning: true) },
                                          errorHandler: { @Sendable _ in continuation.resume(returning: false) })
        }
    }

    private func persist() {
        UserDefaults.standard.set(sent, forKey: "watchSent")
    }

    fileprivate func finished(path: String, version: String, file: URL, error: Error?) {
        if inFlight[path] == version { inFlight[path] = nil }
        if error == nil { sent[path] = version; persist() }
        try? FileManager.default.removeItem(at: file)
        if inFlight.isEmpty, !isSyncing {
            status = error == nil ? "На часах актуально" : "Ошибка: \(error!.localizedDescription)"
        }
    }

    fileprivate func handleRequest(_ info: [String: Any]) {
        if info[SyncKeys.requestFull] as? Bool == true {
            resendAll()
        } else if let need = info[SyncKeys.need] as? [String] {
            need.forEach { sent[$0] = nil }
            persist()
            Task { await sync() }
        } else {
            Task { await sync() }
        }
    }
}

extension WatchSync: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let outstanding = session.outstandingFileTransfers.compactMap { t -> (String, String)? in
            guard let p = t.file.metadata?[SyncKeys.path] as? String,
                  let v = t.file.metadata?[SyncKeys.version] as? String else { return nil }
            return (p, v)
        }
        Task { @MainActor in
            outstanding.forEach { inFlight[$0.0] = $0.1 }
            await sync()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in scheduleSync() }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        let metadata = fileTransfer.file.metadata ?? [:]
        let url = fileTransfer.file.fileURL
        guard let path = metadata[SyncKeys.path] as? String,
              let version = metadata[SyncKeys.version] as? String else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let errorCopy = error
        Task { @MainActor in finished(path: path, version: version, file: url, error: errorCopy) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let info = userInfo as [String: Any]
        let request = (info[SyncKeys.requestFull] as? Bool, info[SyncKeys.need] as? [String])
        Task { @MainActor in
            var dict: [String: Any] = [:]
            if let full = request.0 { dict[SyncKeys.requestFull] = full }
            if let need = request.1 { dict[SyncKeys.need] = need }
            handleRequest(dict)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        self.session(session, didReceiveUserInfo: message)
    }
}

/// Сбор того, что нужно отправить на часы.
nonisolated enum WatchExport {
    struct Entry: Sendable {
        enum Source: Sendable {
            case copy(URL)
            case image(URL)
            case math(String, display: Bool)
        }
        let path: String
        let version: String
        let source: Source

        /// Порядок отправки: записи, формулы, картинки.
        var priority: Int {
            switch source {
            case .copy: 0
            case .math: 1
            case .image: 2
            }
        }

        func produce() -> Data? {
            switch source {
            case .copy(let url):
                return try? Data(contentsOf: url)
            case .image(let url):
                // на часы — уменьшенная копия, чтобы быстро передавалась и не съедала память
                guard let data = try? Data(contentsOf: url),
                      let image = ImageLoader.downsample(data: data, maxPixel: 1600) else { return nil }
                return image.jpegData(compressionQuality: 0.8)
            case .math(let latex, let display):
                let size = display ? SyncKeys.watchDisplayFont : SyncKeys.watchInlineFont
                return MathRenderer.render(latex, display: display, fontSize: size)?.image.pngData()
            }
        }
    }

    static func collect(root: URL) -> [Entry] {
        let fm = FileManager.default
        var entries: [String: Entry] = [:]
        for note in Library.allNotes(in: root) where fm.fileExists(atPath: note.url.path) {
            let path = Library.relativePath(of: note.url, root: root)
            entries[path] = Entry(path: path, version: version(of: note.url), source: .copy(note.url))

            guard let text = try? String(contentsOf: note.url, encoding: .utf8) else { continue }
            let blocks = MarkdownParser.parse(text)
            let folder = note.url.deletingLastPathComponent()
            for source in MarkdownParser.imageSources(in: blocks) {
                guard let url = Library.resolveImage(source, noteFolder: folder, root: root),
                      url.isFileURL, fm.fileExists(atPath: url.path) else { continue }
                let imagePath = Library.relativePath(of: url, root: root)
                entries[imagePath] = Entry(path: imagePath, version: version(of: url), source: .image(url))
            }
            for (latex, display) in MarkdownParser.formulas(in: blocks) {
                guard let rendered = MathRenderer.render(latex, display: display,
                                                         fontSize: display ? SyncKeys.watchDisplayFont : SyncKeys.watchInlineFont)
                else { continue }
                // В имени файла — ключ формулы, сдвиг базовой линии и масштаб картинки.
                let name = "\(Library.mathKey(latex, display: display))~\(Int(rendered.descent * 1000))~\(Int(rendered.image.scale)).png"
                let mathPath = SyncKeys.mathFolder + "/" + name
                entries[mathPath] = Entry(path: mathPath, version: "2", source: .math(latex, display: display))
            }
        }
        return Array(entries.values)
    }

    private static func version(of url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let date = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(Int(date))-\(values?.fileSize ?? 0)"
    }
}

/// Кнопка синхронизации в шапке главного экрана.
struct SyncMenu: View {
    @Environment(LibraryStore.self) private var store
    private var sync: WatchSync { .shared }

    var body: some View {
        Menu {
            Section {
                Label(store.isICloud ? "iCloud Drive › Шпора" : "Только на iPhone (iCloud выключен)",
                      systemImage: store.isICloud ? "icloud" : "iphone")
                Label(sync.status, systemImage: "applewatch")
            }
            Button("Синхронизировать", systemImage: "arrow.triangle.2.circlepath") {
                store.refresh()
                Task { await sync.sync() }
            }
            Button("Отправить на часы заново", systemImage: "applewatch.radiowaves.left.and.right") {
                sync.resendAll()
            }
        } label: {
            Image(systemName: sync.isSyncing ? "arrow.triangle.2.circlepath.icloud" : (store.isICloud ? "icloud" : "iphone"))
                .symbolEffect(.rotate, isActive: sync.isSyncing)
        }
    }
}
