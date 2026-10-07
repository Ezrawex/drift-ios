import SwiftUI

struct ReplacementRequest: Identifiable { let id: String }

struct MixView: View {
    @Bindable var store: DriftStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var editing = false
    @State private var replacement: ReplacementRequest?
    @State private var showConnections = false
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top) {
                        Sleeve(index: 0, size: 76)
                        Spacer()
                        DemoBadge()
                    }
                    Text(store.mix?.title ?? "Your mix").font(.largeTitle.weight(.semibold)).tracking(-0.8)
                    Text("\(store.mix?.tracks.count ?? 0) songs · \(store.mix?.duration ?? "0 min")")
                        .font(.subheadline.weight(.medium)).foregroundStyle(Palette.accent)
                    Text("A sample sequence for your moment. Edit the order, swap a song, or leave one out. Keep a favorite using its menu.")
                        .font(.subheadline).foregroundStyle(Palette.secondary)
                    Text("DEMO SELECTION · NO CLOUD AI").font(.caption2.weight(.semibold)).tracking(1).foregroundStyle(Palette.secondary)
                }.padding(.vertical, 8)
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            Section {
                sequenceHeader.padding(.vertical, 4).buttonStyle(.borderless).listRowSeparator(.hidden)
                if store.mix?.tracks.isEmpty == true {
                    ContentUnavailableView("Your mix has room", systemImage: "music.note", description: Text("Undo the last removal or go back and make another mix."))
                }
                ForEach(Array((store.mix?.tracks ?? []).enumerated()), id: \.element.id) { index, track in
                    HStack(alignment: dynamicTypeSize.isAccessibilitySize ? .top : .center, spacing: 4) {
                        TrackRow(track: track, position: editing ? nil : index + 1)
                        if !editing {
                            Menu("Options for \(track.title)", systemImage: (store.mix?.preferredTrackIDs ?? []).contains(track.id) ? "pin.fill" : "ellipsis") {
                                Button((store.mix?.preferredTrackIDs ?? []).contains(track.id) ? "Allow replacement on refine" : "Keep on refine", systemImage: "pin") { store.togglePreferred(track.id) }
                                Button("Replace song", systemImage: "arrow.triangle.2.circlepath") { replacement = .init(id: track.id) }
                                Button("Remove song", systemImage: "minus.circle", role: .destructive) { store.remove(track.id) }
                            }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                                .accessibilityValue((store.mix?.preferredTrackIDs ?? []).contains(track.id) ? "Kept on refine" : "")
                        }
                    }.listRowSeparatorTint(Palette.secondary.opacity(0.15))
                }.onDelete { offsets in
                    let tracks = store.mix?.tracks ?? []
                    store.remove(ids: offsets.filter { tracks.indices.contains($0) }.map { tracks[$0].id })
                }.onMove { store.move($0, to: $1) }

            }.listRowBackground(Color.clear).disabled(store.generating)
            Section {
                Button { store.refine() } label: {
                    Label("More energetic", systemImage: "bolt").font(.subheadline.weight(.medium)).padding(.vertical, 4)
                }.disabled(store.generating)
                if store.generating {
                    HStack { ProgressView(); Text("Reworking the demo…"); Spacer(); Button("Cancel") { store.cancel() } }
                }
                if let error = store.error { Text(error).font(.footnote).foregroundStyle(Palette.secondary) }
                Text("Fictional songs and artwork. This mix cannot be played or exported to Qobuz.").font(.footnote).foregroundStyle(Palette.secondary)
                if dynamicTypeSize.isAccessibilitySize { connectionsButton }
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Palette.background)
            .environment(\.editMode, .constant(editing ? .active : .inactive))
            .navigationTitle("Your mix").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    PrimaryButton(title: store.isSaved ? "Saved on this device" : "Save demo mix", symbol: store.isSaved ? "checkmark" : "bookmark", disabled: store.generating || store.mix?.tracks.isEmpty != false) { store.save() }
                    if !dynamicTypeSize.isAccessibilitySize { connectionsButton }
                }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8).background(Palette.background)
            }
            .sheet(item: $replacement) { request in ReplacementView(store: store, replacing: request.id) {} }
            .sheet(isPresented: $showConnections) { ConnectionsView() }
    }
    private var sequenceHeader: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    sequenceLabel
                    HStack { Spacer(); editControls }
                }
            } else {
                HStack { sequenceLabel; Spacer(); editControls }
            }
        }
    }
    private var sequenceLabel: some View {
        Text(editing ? "MAKE IT YOURS" : "THE SEQUENCE").font(.caption.weight(.semibold))
            .tracking(1.2).foregroundStyle(Palette.secondary)
    }
    @ViewBuilder private var editControls: some View {
        if store.canUndo { Button("Undo") { store.undo() }.font(.subheadline).frame(minHeight: 44) }
        Button(editing ? "Done" : "Edit") { editing.toggle() }
            .font(.subheadline.weight(.semibold)).frame(minHeight: 44).accessibilityIdentifier("editMix")
    }
    private var connectionsButton: some View {
        Button("Qobuz export requires a connection") { showConnections = true }
            .font(.footnote).padding(.vertical, 4)
    }
}
