import SwiftUI

struct SourcePicker: View {
    @Bindable var store: DriftStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.sources) { source in
                        Button { store.sourceID = source.id; dismiss() } label: {
                            HStack(spacing: 14) {
                                SourceArtwork()
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(source.title).font(.headline)
                                    Text("\(source.tracks.count) sample songs · \(source.subtitle)").font(.caption).foregroundStyle(Palette.secondary)
                                }
                                Spacer()
                                if source.id == store.sourceID { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
                            }.padding(.vertical, 8)
                        }.buttonStyle(.plain)
                    }
                } header: { Text("Try the demo") }
                footer: { Text("These fictional playlists use local sample selection. No real account or music library is included.") }
            }.scrollContentBackground(.hidden).background(Palette.background)
                .navigationTitle("Choose a playlist").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }

        }.tint(Palette.accent).foregroundStyle(Palette.ink)
    }
}

struct ReplacementView: View {
    let store: DriftStore
    let replacing: String
    let didReplace: () -> Void
    @Environment(\.dismiss) private var dismiss
    private var candidates: [Track] {
        let ids = Set(store.mix?.tracks.map(\.id) ?? [])
        let source = store.sources.first { $0.id == store.mix?.sourceID }
        return source?.tracks.filter { !ids.contains($0.id) && $0.available } ?? []
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(candidates) { track in
                        Button { store.replace(replacing, with: track); didReplace(); dismiss() } label: { TrackRow(track: track) }.buttonStyle(.plain)
                    }
                    if candidates.isEmpty { ContentUnavailableView("No more sample songs", systemImage: "music.note", description: Text("Every eligible song is already in this mix.")) }
                } header: { Text("Only from this mix’s source playlist") }
            }.scrollContentBackground(.hidden).background(Palette.background)
                .navigationTitle("Replace a song").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.tint(Palette.accent).foregroundStyle(Palette.ink)
    }
}

struct ConnectionsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("You’re trying the demo", systemImage: "circle.dotted").font(.headline)
                    Text("Mix generation uses fictional music and local rules. No music is streamed by Drift.")
                }
                Section("Qobuz · Not connected") {
                    Text("Live import and private export need a permitted native connection; signing into the Qobuz website does not connect Drift.")
                    Text("Private export, Open in Qobuz, ordered playback and AirPods controls have not been tested.").foregroundStyle(Palette.secondary)
                }
                Section("Cloud AI · Connection preview") {
                    NavigationLink("Connect ChatGPT") { ChatGPTConnectionView() }
                    Text("An official ChatGPT-plan sign-in path is available to test. Real iPhone sign-in and cloud selection are still being verified. Mix generation uses local demo rules.")
                    Text("No separately billed API is enabled. A paid route needs your choice and a secure connection design.").foregroundStyle(Palette.secondary)
                }
                Section("Privacy") {
                    Text("Demo mixes stay on this device. Choosing ChatGPT sign-in contacts OpenAI; the optional connection test sends a short greeting without playlist data. No separately billed API is enabled.")
                }
            }.scrollContentBackground(.hidden).background(Palette.background)
                .navigationTitle("Connections").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(Palette.accent).foregroundStyle(Palette.ink)
    }
}

struct RecentView: View {
    let store: DriftStore
    let open: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if let warning = store.historyWarning { Text(warning).foregroundStyle(Palette.secondary) }
                if store.saved.isEmpty {
                    ContentUnavailableView("A fresh start", systemImage: "bookmark", description: Text("Save a demo mix and it will be waiting here."))
                }
                ForEach(store.saved) { mix in
                    Button {
                        store.open(mix); dismiss(); open()
                    } label: {
                        HStack(spacing: 14) {
                            Sleeve(index: mix.tracks.first?.sleeve ?? 0)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mix.title).font(.headline)
                                Text("\(mix.tracks.count) songs · \(mix.duration) · Demo").font(.caption).foregroundStyle(Palette.secondary)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.caption)
                        }.padding(.vertical, 6)
                    }.buttonStyle(.plain)
                }
            }.scrollContentBackground(.hidden).background(Palette.background)
                .navigationTitle("Recent mixes").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.tint(Palette.accent).foregroundStyle(Palette.ink)
    }
}
