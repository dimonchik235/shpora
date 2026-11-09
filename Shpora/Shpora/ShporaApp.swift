import SwiftUI

@main
struct ShporaApp: App {
    @State private var store = LibraryStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(\.mathProvider, PhoneMathCache.shared.provider)
                .environment(\.libraryRoot, store.root)
                .task {
                    await store.setup()
                    if let root = store.root { WatchSync.shared.start(root: root) }
                }
                .onChange(of: scenePhase) {
                    if scenePhase == .active, store.root != nil { store.refresh() }
                }
        }
    }
}

struct RootView: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $store.path) {
            Group {
                if let root = store.root {
                    FolderView(folder: root, isRoot: true)
                } else {
                    ProgressView("Открываю библиотеку…")
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .folder(let url): FolderView(folder: url, isRoot: false)
                case .note(let url, let edit): NoteView(url: url, startEditing: edit)
                }
            }
        }
    }
}
