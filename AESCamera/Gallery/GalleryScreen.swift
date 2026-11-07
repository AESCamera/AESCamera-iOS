import AESCore
import SwiftUI

struct GalleryScreen: View {
    @Binding var path: NavigationPath
    @Environment(AppSession.self) private var session
    @State private var items: [MediaItem] = []
    @State private var loaded = false
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var confirmDelete = false
    @State private var exporting = false
    @State private var message: String?

    private var sections: [(day: Date, items: [MediaItem])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: items) { calendar.startOfDay(for: $0.captureDate) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    private var selectedItems: [MediaItem] {
        items.filter { selection.contains($0.id) }
    }

    var body: some View {
        Group {
            if loaded && items.isEmpty {
                ContentUnavailableView(
                    "No Photos or Videos",
                    systemImage: "lock.rectangle.stack",
                    description: Text("Everything you capture with this password appears here, encrypted.")
                )
            } else {
                grid
            }
        }
        .navigationTitle(selecting ? selectionTitle : "Vault")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(selecting)
        .toolbar { toolbar }
        .task(id: session.vaultRevision) { await reload() }
        .confirmationDialog(deleteTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { delete(selectedItems) }
        } message: {
            Text("Deleted files can't be recovered.")
        }
        .fileImporter(isPresented: $exporting, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            let files = selectedItems.map(\.url)
            Task {
                do {
                    let summary = try await Task.detached { try VaultTransfer.export(files, to: folder) }.value
                    message = summary.failed == 0
                        ? "Exported \(summary.exported) file(s) to \(summary.folderName)."
                        : "Exported \(summary.exported), \(summary.failed) failed."
                } catch {
                    message = error.localizedDescription
                }
                endSelection()
            }
        }
        .alert("Vault", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }

    private var selectionTitle: String {
        selection.isEmpty ? "Select Items" : "\(selection.count) Selected"
    }

    private var deleteTitle: String {
        selection.count == 1 ? "Delete 1 item?" : "Delete \(selection.count) items?"
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 200), spacing: 2)], spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(sections, id: \.day) { section in
                    Section {
                        ForEach(section.items) { item in
                            tile(item)
                        }
                    } header: {
                        Text(DayLabel.string(for: section.day))
                            .font(.headline)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.bar)
                    }
                }
            }
        }
    }

    private func tile(_ item: MediaItem) -> some View {
        Thumbnail(item: item)
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo {
                    Image(systemName: "play.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if selecting {
                    let selected = selection.contains(item.id)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, selected ? Color.accentColor : .black.opacity(0.25))
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if selecting {
                    toggle(item)
                } else {
                    path.append(ViewerRoute(startID: item.id))
                }
            }
            .onLongPressGesture {
                if !selecting {
                    selecting = true
                    selection = [item.id]
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(item.isVideo ? "Video" : "Photo")
            .accessibilityIdentifier(item.isVideo ? "Video" : "Photo")
            .accessibilityValue(selection.contains(item.id) ? "Selected" : "")
            .accessibilityAddTraits(.isButton)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if selecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Done") { endSelection() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(selection.count == items.count ? "Deselect All" : "Select All") {
                    selection = selection.count == items.count ? [] : Set(items.map(\.id))
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                ShareLink(items: selectedItems.map(\.url)) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .disabled(selection.isEmpty)
                Spacer()
                Button {
                    exporting = true
                } label: {
                    Label("Export", systemImage: "folder.badge.plus")
                }
                .disabled(selection.isEmpty)
                Spacer()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    selecting = true
                } label: {
                    Label("Select", systemImage: "checkmark.circle")
                }
                .disabled(items.isEmpty)
                Button {
                    session.lock()
                } label: {
                    Label("Lock", systemImage: "lock.fill")
                }
                Menu {
                    Button {
                        path.append(Route.settings)
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
    }

    private func toggle(_ item: MediaItem) {
        if selection.contains(item.id) {
            selection.remove(item.id)
        } else {
            selection.insert(item.id)
        }
    }

    private func endSelection() {
        selecting = false
        selection = []
    }

    private func reload() async {
        let vault = session.vaultURL
        let listed = await Task.detached(priority: .userInitiated) { VaultFiles.media(in: vault) }.value
        items = listed
        selection = selection.intersection(listed.map(\.id))
        loaded = true
    }

    private func delete(_ doomed: [MediaItem]) {
        Task {
            let failures = await Task.detached {
                doomed.filter { (try? VaultFiles.delete($0)) == nil }.count
            }.value
            if failures > 0 { message = "\(failures) item(s) couldn't be deleted." }
            endSelection()
            session.vaultDidChange()
        }
    }
}

/// One decrypted thumbnail tile (square, centre-cropped).
struct Thumbnail: View {
    let item: MediaItem
    @Environment(AppSession.self) private var session
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .task(id: item.id) {
                guard let secret = session.secret else { return }
                if let cached = ThumbnailStore.shared.cached(item, secret: secret) {
                    image = cached
                    return
                }
                image = await ThumbnailStore.shared.image(for: item, secret: secret)
            }
    }
}

enum DayLabel {
    static func string(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        let sameYear = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
        return day.formatted(sameYear
            ? .dateTime.weekday(.abbreviated).day().month(.abbreviated)
            : .dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
    }
}
