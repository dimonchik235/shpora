import SwiftUI

@main
struct ShporaWatchApp: App {
    @State private var store = WatchStore()
    @AppStorage(TextSize.storageKey) private var textSize = TextSize.standard
    @State private var path: [LibraryItem] = {
        #if DEBUG
        // Отладка: xcrun simctl launch … -openNote "Биология/Кости/Функции костей.md"
        if let note = UserDefaults.standard.string(forKey: "openNote") {
            return [LibraryItem(url: WatchStore.root.appendingPathComponent(note), isFolder: false)]
        }
        #endif
        return []
    }()

    var body: some Scene {
        WindowGroup {
            NavigationStack(path: $path) {
                WatchFolderView(folder: WatchStore.root, isRoot: true)
                    .navigationDestination(for: LibraryItem.self) { item in
                        if item.isFolder {
                            WatchFolderView(folder: item.url, isRoot: false)
                        } else {
                            WatchNoteView(url: item.url)
                        }
                    }
            }
            .environment(store)
            .environment(\.mathProvider, store.math.provider(scale: textSize.scale))
            .environment(\.contentScale, textSize.scale)
            .dynamicTypeSize(textSize.dynamicType)
            .environment(\.libraryRoot, WatchStore.root)
            .task { store.start() }
        }
    }
}

struct WatchFolderView: View {
    let folder: URL
    let isRoot: Bool

    @Environment(WatchStore.self) private var store
    @State private var folders: [LibraryItem] = []
    @State private var notes: [LibraryItem] = []
    var body: some View {
        List { content }
            .navigationTitle(isRoot ? "Шпора" : folder.lastPathComponent)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        WatchSearchView(folder: folder, title: isRoot ? nil : folder.lastPathComponent)
                    } label: {
                        Label("Поиск", systemImage: "magnifyingglass")
                    }
                }
            }
            .task(id: store.revision) {
                let content = Library.contents(of: folder)
                folders = content.folders
                notes = content.notes
            }
    }

    @ViewBuilder
    private var content: some View {
        ForEach(folders) { item in
            NavigationLink(value: item) {
                Label(item.name, systemImage: "folder.fill")
            }
        }
        ForEach(notes) { item in
            NavigationLink(value: item) {
                Label(item.name, systemImage: "doc.text")
            }
        }
        if folders.isEmpty, notes.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "iphone").font(.title2)
                Text("Пока пусто").font(.headline)
                Text("Откройте Шпору на iPhone — записи придут сюда")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
        if isRoot { syncSection }
    }

    private var syncSection: some View {
        Section {
            NavigationLink {
                TextSizeScreen()
            } label: {
                Label("Размер текста", systemImage: "textformat.size")
            }
            Button {
                store.requestSync()
            } label: {
                Label("Обновить", systemImage: "arrow.triangle.2.circlepath")
            }
        } footer: {
            VStack(alignment: .leading) {
                if let date = store.lastSync {
                    Text("Обновлено \(date.formatted(.relative(presentation: .named)))")
                }
                if !store.missing.isEmpty {
                    Text("Ещё загружается: \(store.missing.count)")
                }
            }
        }
    }
}

/// Поиск по записям: по названию и по тексту, внутри текущего раздела.
struct WatchSearchView: View {
    let folder: URL
    /// Название раздела, если ищем не по всей библиотеке.
    let title: String?

    @State private var query = ""
    @State private var results: [SearchResult] = []
    /// Запрос, для которого посчитаны `results` (пока ищем — не пишем «ничего не найдено»).
    @State private var resultsQuery = ""

    var body: some View {
        List {
            TextField(title.map { "Поиск в «\($0)»" } ?? "Поиск по всем записям", text: $query)
                .textInputAutocapitalization(.never)

            ForEach(results) { result in
                NavigationLink(value: LibraryItem(url: result.url, isFolder: false)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title).font(.headline)
                        if !result.path.isEmpty {
                            Text(result.path).font(.caption2).foregroundStyle(.tint).lineLimit(1)
                        }
                        if let snippet = result.snippet {
                            Text(snippet).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
            }
            if !query.isEmpty, results.isEmpty, resultsQuery == query {
                Text("Ничего не найдено")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Поиск")
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { results = []; resultsQuery = query; return }
            let folder = folder
            results = await Task.detached { SearchResult.search(q, in: folder) }.value
            resultsQuery = query
        }
    }
}

struct WatchNoteView: View {
    let url: URL

    @Environment(WatchStore.self) private var store
    @State private var blocks: [MDBlock] = []
    @State private var showTextSize = false

    var body: some View {
        ScrollView {
            MarkdownView(blocks: blocks, noteFolder: url.deletingLastPathComponent())
        }
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Размер текста", systemImage: "textformat.size") { showTextSize = true }
            }
        }
        .sheet(isPresented: $showTextSize) {
            NavigationStack { TextSizeScreen() }
        }
        .task(id: store.revision) {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            blocks = MarkdownParser.parse(text)
        }
    }
}
