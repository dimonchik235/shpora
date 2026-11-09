import SwiftUI
import UniformTypeIdentifiers

/// Экран темы/раздела: вложенные разделы и записи.
struct FolderView: View {
    let folder: URL
    let isRoot: Bool

    @Environment(LibraryStore.self) private var store
    @State private var folders: [LibraryItem] = []
    @State private var notes: [LibraryItem] = []
    @State private var counts: [URL: Int] = [:]

    @State private var query = ""
    @State private var results: [SearchResult] = []

    @State private var nameDialog: NameDialog?
    @State private var nameText = ""
    @State private var toDelete: LibraryItem?
    @State private var showImporter = false

    enum NameDialog: Identifiable {
        case newFolder, newNote, rename(LibraryItem)
        var id: String {
            switch self {
            case .newFolder: "folder"
            case .newNote: "note"
            case .rename(let item): item.url.path
            }
        }
    }

    var body: some View {
        List {
            if !query.isEmpty {
                searchSection
            } else {
                if !folders.isEmpty {
                    Section(isRoot ? "Темы" : "Разделы") {
                        ForEach(folders) { row($0) }
                    }
                }
                if !notes.isEmpty {
                    Section("Записи") {
                        ForEach(notes) { row($0) }
                    }
                }
            }
        }
        .overlay {
            if query.isEmpty, folders.isEmpty, notes.isEmpty {
                ContentUnavailableView {
                    Label(isRoot ? "Пока пусто" : "Пустой раздел", systemImage: "books.vertical")
                } description: {
                    Text("Нажмите «+», чтобы создать тему, раздел или запись")
                }
            }
        }
        .navigationTitle(isRoot ? "Шпора" : folder.lastPathComponent)
        .searchable(text: $query, prompt: isRoot ? "Поиск по всем записям" : "Поиск в «\(folder.lastPathComponent)»")
        .toolbar { toolbar }
        .task(id: store.revision) { reload() }
        .task(id: query) { await search() }
        .refreshable { store.refresh() }
        .alert(dialogTitle, isPresented: Binding(get: { nameDialog != nil }, set: { if !$0 { nameDialog = nil } })) {
            TextField("Название", text: $nameText)
            Button("Отмена", role: .cancel) {}
            Button("Готово") { commitName() }
        }
        .confirmationDialog("Удалить «\(toDelete?.name ?? "")»?",
                            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                if let toDelete { store.delete(toDelete) }
            }
        } message: {
            if toDelete?.isFolder == true { Text("Будут удалены все разделы и записи внутри.") }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.folder, .zip, .plainText, UTType(filenameExtension: "md") ?? .plainText, .image],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { store.importItems(urls, into: folder) }
        }
        .alert("Не удалось импортировать",
               isPresented: Binding(get: { store.importError != nil }, set: { if !$0 { store.importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.importError ?? "")
        }
    }

    // MARK: - Строки

    private func row(_ item: LibraryItem) -> some View {
        NavigationLink(value: item.isFolder ? Route.folder(item.url) : Route.note(item.url, edit: false)) {
            if item.isFolder {
                HStack {
                    Label(item.name, systemImage: "folder.fill")
                    Spacer()
                    if let count = counts[item.url], count > 0 {
                        Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            } else {
                Label(item.name, systemImage: "doc.text")
            }
        }
        .swipeActions {
            Button("Удалить", systemImage: "trash", role: .destructive) { toDelete = item }
            Button("Переименовать", systemImage: "pencil") { startRename(item) }
                .tint(.orange)
        }
        .contextMenu {
            Button("Переименовать", systemImage: "pencil") { startRename(item) }
            Button("Удалить", systemImage: "trash", role: .destructive) { toDelete = item }
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ForEach(results) { result in
                NavigationLink(value: Route.note(result.url, edit: false)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(result.title).font(.headline)
                        if !result.path.isEmpty {
                            Text(result.path).font(.caption).foregroundStyle(.secondary)
                        }
                        if let snippet = result.snippet {
                            Text(snippet).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Панель

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isRoot {
            ToolbarItem(placement: .topBarLeading) {
                SyncMenu()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(isRoot ? "Новая тема" : "Новый раздел", systemImage: "folder.badge.plus") {
                    nameText = ""
                    nameDialog = .newFolder
                }
                Button("Новая запись", systemImage: "square.and.pencil") {
                    nameText = ""
                    nameDialog = .newNote
                }
                Divider()
                Button("Импорт из Файлов (.md, .zip)", systemImage: "square.and.arrow.down") { showImporter = true }
            } label: {
                Label("Добавить", systemImage: "plus")
            }
        }
    }

    private var dialogTitle: String {
        switch nameDialog {
        case .newFolder: isRoot ? "Новая тема" : "Новый раздел"
        case .newNote: "Новая запись"
        case .rename: "Переименовать"
        case nil: ""
        }
    }

    private func startRename(_ item: LibraryItem) {
        nameText = item.name
        nameDialog = .rename(item)
    }

    private func commitName() {
        let name = nameText
        switch nameDialog {
        case .newFolder:
            store.createFolder(named: name, in: folder)
        case .newNote:
            if let url = store.createNote(named: name, in: folder) {
                store.path.append(.note(url, edit: true))
            }
        case .rename(let item):
            store.rename(item, to: name)
        case nil: break
        }
        nameDialog = nil
    }

    // MARK: - Данные

    private func reload() {
        let content = Library.contents(of: folder)
        folders = content.folders
        notes = content.notes
        counts = Dictionary(uniqueKeysWithValues: folders.map { ($0.url, Library.noteCount(in: $0.url)) })
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { results = []; return }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        let folder = folder
        results = await Task.detached { SearchResult.search(q, in: folder) }.value
    }
}
