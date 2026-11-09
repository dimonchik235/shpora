import SwiftUI
import PhotosUI

/// Просмотр записи.
struct NoteView: View {
    let url: URL
    let startEditing: Bool

    @Environment(LibraryStore.self) private var store
    @State private var blocks: [MDBlock] = []
    @State private var isEditing = false
    @State private var loaded = false

    var body: some View {
        ScrollView {
            MarkdownView(blocks: blocks, noteFolder: url.deletingLastPathComponent())
                .padding()
        }
        .overlay {
            if loaded, blocks.isEmpty {
                ContentUnavailableView("Пустая запись", systemImage: "doc",
                                       description: Text("Нажмите «Изменить», чтобы написать текст"))
            }
        }
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Изменить", systemImage: "square.and.pencil") { isEditing = true }
        }
        .navigationDestination(isPresented: $isEditing) {
            NoteEditorView(url: url)
        }
        .task(id: store.revision) {
            blocks = MarkdownParser.parse(await store.read(url))
            loaded = true
        }
        .refreshable { store.refresh() }
        .onAppear {
            if startEditing, !loaded { isEditing = true }
        }
    }
}

/// Редактор Markdown с панелью быстрых вставок и предпросмотром.
struct NoteEditorView: View {
    let url: URL

    @Environment(LibraryStore.self) private var store
    @State private var text = ""
    @State private var savedText = ""
    @State private var selection: TextSelection?
    @State private var preview = false
    @State private var photoItem: PhotosPickerItem?
    @State private var loaded = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Picker("Режим", selection: $preview) {
                Text("Текст").tag(false)
                Text("Просмотр").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom, 8)

            if preview {
                ScrollView {
                    MarkdownView(blocks: MarkdownParser.parse(text), noteFolder: url.deletingLastPathComponent())
                        .padding()
                }
            } else {
                TextEditor(text: $text, selection: $selection)
                    .font(.system(.callout, design: .monospaced))
                    .focused($focused)
                    .padding(.horizontal, 8)
                    .scrollDismissesKeyboard(.interactively)
            }
        }
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Фото", systemImage: "photo.badge.plus")
                }
            }
            ToolbarItemGroup(placement: .keyboard) { formattingBar }
        }
        .task {
            guard !loaded else { return }
            text = await store.read(url)
            savedText = text
            loaded = true
            focused = true
        }
        .task(id: text) {
            // автосохранение через секунду после последней правки
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { save() }
        }
        .onDisappear { save() }
        .onChange(of: photoItem) {
            guard let item = photoItem else { return }
            photoItem = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let path = store.saveImage(data, forNote: url) else { return }
                insertBlock("![](\(path))")
            }
        }
    }

    private func save() {
        guard loaded, text != savedText else { return }
        savedText = text
        store.write(text, to: url)
    }

    // MARK: - Панель форматирования

    private var formattingBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                Menu {
                    Button("Заголовок 1") { prefixLine("# ") }
                    Button("Заголовок 2") { prefixLine("## ") }
                    Button("Заголовок 3") { prefixLine("### ") }
                } label: { Image(systemName: "textformat.size") }
                Button { wrap("**", "**", placeholder: "жирный") } label: { Image(systemName: "bold") }
                Button { wrap("*", "*", placeholder: "курсив") } label: { Image(systemName: "italic") }
                Button { wrap("==", "==", placeholder: "важно") } label: { Image(systemName: "highlighter") }
                Button { prefixLine("- ") } label: { Image(systemName: "list.bullet") }
                Button { prefixLine("1. ") } label: { Image(systemName: "list.number") }
                Button { prefixLine("- [ ] ") } label: { Image(systemName: "checklist") }
                Button { prefixLine("> ") } label: { Image(systemName: "text.quote") }
                Button {
                    insertBlock("| Столбец 1 | Столбец 2 |\n| --- | --- |\n|  |  |\n|  |  |")
                } label: { Image(systemName: "tablecells") }
                Menu {
                    Button("В строке  $…$") { wrap("$", "$", placeholder: "x^2") }
                    Button("Отдельной строкой  $$…$$") { insertBlock("$$\n\\frac{a}{b}\n$$") }
                } label: { Image(systemName: "function") }
                Button { wrap("`", "`", placeholder: "код") } label: { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                Button { focused = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
            }
            .padding(.horizontal, 4)
        }
    }

    private var currentRange: Range<String.Index> {
        if case .selection(let range)? = selection?.indices,
           range.lowerBound >= text.startIndex, range.upperBound <= text.endIndex {
            return range
        }
        return text.endIndex..<text.endIndex
    }

    private func offset(_ index: String.Index) -> Int { text.distance(from: text.startIndex, to: index) }
    private func index(_ offset: Int) -> String.Index {
        text.index(text.startIndex, offsetBy: min(offset, text.count))
    }

    /// Обернуть выделение: **текст**
    private func wrap(_ prefix: String, _ suffix: String, placeholder: String) {
        let range = currentRange
        let selected = String(text[range])
        let inner = selected.isEmpty ? placeholder : selected
        let start = offset(range.lowerBound)
        text.replaceSubrange(range, with: prefix + inner + suffix)
        let innerStart = start + prefix.count
        selection = TextSelection(range: index(innerStart)..<index(innerStart + inner.count))
    }

    /// Добавить префикс в начало текущей строки: «# », «- »…
    private func prefixLine(_ prefix: String) {
        let range = currentRange
        let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let cursor = offset(range.lowerBound) + prefix.count
        text.insert(contentsOf: prefix, at: lineStart)
        selection = TextSelection(insertionPoint: index(cursor))
    }

    /// Вставить блок отдельными строками.
    private func insertBlock(_ block: String) {
        let range = currentRange
        let before = text[..<range.lowerBound]
        let lead = before.isEmpty || before.hasSuffix("\n\n") ? "" : (before.hasSuffix("\n") ? "\n" : "\n\n")
        let insert = lead + block + "\n"
        let cursor = offset(range.lowerBound) + insert.count
        text.replaceSubrange(range, with: insert)
        selection = TextSelection(insertionPoint: index(cursor))
    }
}
