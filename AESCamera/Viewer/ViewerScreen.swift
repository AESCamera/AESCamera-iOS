import AESCore
import SwiftUI

struct ViewerRoute: Hashable {
    let startID: String
}

/// One pager for photos and videos, newest first. Two sources, as on Android: the vault,
/// or files staged by an import (with "Add to Vault").
struct ViewerScreen: View {
    enum Source: Hashable {
        case vault(startID: String)
        case imported([URL])
    }

    let source: Source
    var onClose: (() -> Void)?

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var items: [MediaItem] = []
    @State private var current: String?
    @State private var chromeHidden = false
    @State private var zoomed = false
    @State private var confirmDelete = false
    @State private var added = Set<String>()
    @State private var adding = false
    @State private var message: String?

    private var currentIndex: Int? {
        items.firstIndex { $0.id == current }
    }

    private var currentItem: MediaItem? {
        currentIndex.map { items[$0] }
    }

    private var isImported: Bool {
        if case .imported = source { true } else { false }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(items) { item in
                        page(item)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $current)
            .scrollDisabled(zoomed)
            .scrollIndicators(.hidden)
        }
        .ignoresSafeArea()
        .background(Color.black.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .toolbarBackground(.visible, for: .navigationBar, .bottomBar)
        .toolbarBackground(Color.black.opacity(0.6), for: .navigationBar, .bottomBar)
        .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
        .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar, .bottomBar)
        .statusBarHidden(chromeHidden)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.2), value: chromeHidden)
        .onChange(of: current) { zoomed = false }
        .task(id: session.vaultRevision) { await load() }
        .confirmationDialog("Delete this item?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteCurrent() }
        } message: {
            Text("Deleted files can't be recovered.")
        }
        .alert("AES Camera", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    @ViewBuilder
    private func page(_ item: MediaItem) -> some View {
        if item.isVideo {
            VideoPage(item: item, isCurrent: current == item.id) { chromeHidden.toggle() }
        } else {
            PhotoPage(item: item, zoomed: current == item.id ? $zoomed : .constant(false)) {
                chromeHidden.toggle()
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if let item = currentItem, let index = currentIndex {
                VStack(spacing: 0) {
                    Text(title(for: item)).font(.subheadline.weight(.semibold))
                    Text("\(index + 1) of \(items.count)").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        if let onClose {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close", action: onClose)
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            if let item = currentItem {
                ShareLink(item: item.url) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                Spacer()
                if isImported {
                    if added.contains(item.id) {
                        Label("Added", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                    } else {
                        Button {
                            addToVault(item)
                        } label: {
                            Label("Add to Vault", systemImage: "lock.doc")
                                .labelStyle(.titleAndIcon)
                        }
                        .disabled(adding)
                    }
                } else {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func title(for item: MediaItem) -> String {
        guard MediaNames.isGenerated(item.name) else { return item.name }
        return item.captureDate.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }

    private func load() async {
        switch source {
        case .vault(let startID):
            let vault = session.vaultURL
            let listed = await Task.detached(priority: .userInitiated) { VaultFiles.media(in: vault) }.value
            let keep = current ?? startID
            items = listed
            current = listed.contains { $0.id == keep } ? keep : listed.first?.id
            if listed.isEmpty { dismiss() }
        case .imported(let urls):
            guard items.isEmpty else { return }
            items = urls.map { url in
                MediaItem(url: url, captureDate: MediaNames.captureDate(fromName: url.lastPathComponent) ?? Date())
            }
            current = items.first?.id
        }
    }

    private func deleteCurrent() {
        guard let item = currentItem, let index = currentIndex else { return }
        do {
            try VaultFiles.delete(item)
        } catch {
            message = error.localizedDescription
            return
        }
        items.remove(at: index)
        current = items.isEmpty ? nil : items[min(index, items.count - 1)].id
        session.vaultDidChange()
    }

    private func addToVault(_ item: MediaItem) {
        adding = true
        Task {
            defer { adding = false }
            do {
                let vault = try await session.ensureVault()
                guard let secret = session.secret else { return }
                let outcome = try await ImportStaging.addToVault(item.url, name: item.name, vault: vault, secret: secret)
                switch outcome {
                case .imported, .alreadyInVault:
                    added.insert(item.id)
                    session.vaultDidChange()
                case .wrongPassword:
                    message = "This file was encrypted with a different password, so this vault can't show it."
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
