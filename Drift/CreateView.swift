import SwiftUI

enum AppSheet: String, Identifiable {
    case sources, connections, recent
    var id: String { rawValue }
}

struct CreateView: View {
    @Bindable var store: DriftStore
    @State private var sheet: AppSheet?
    @State private var showMix = false
    @FocusState private var promptFocused: Bool
    private let suggestions: [(String, String, String)] = [
        ("Find my stride", "figure.run", "A 30-minute run: upbeat, driving, a little angry, no slow songs."),
        ("Quiet focus", "moon", "Quiet focus, soft and calm. No distractions."),
        ("After hours", "sun.horizon", "A melancholic evening, a little space to unwind.")
    ]
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    sourceButton.disabled(store.generating)
                    moodInput.disabled(store.generating)
                    if !promptFocused {
                        suggestionsView.disabled(store.generating)
                        durationPicker.disabled(store.generating)
                    }
                    if let error = store.error {
                        Label(error, systemImage: "exclamationmark.circle").font(.subheadline)
                            .foregroundStyle(Palette.ink).padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityIdentifier("generationError")
                    }
                    if !promptFocused {
                        Text("Fictional sample music. Selection runs on this device; cloud AI and Qobuz are not connected.")
                            .font(.footnote).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 24)
            }
            .background(Palette.background).scrollDismissesKeyboard(.interactively)
            .navigationTitle("Drift").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Connections", systemImage: "slider.horizontal.3") { sheet = .connections }
                        .accessibilityIdentifier("connections")
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { promptFocused = false } }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if store.generating {
                        HStack { ProgressView(); Text("Choosing from sample songs…").font(.subheadline); Spacer(); Button("Cancel") { store.cancel() } }
                            .padding(16).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                    } else {
                        PrimaryButton(title: "Make my mix", symbol: "sparkles", disabled: store.source == nil || store.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            promptFocused = false; store.generate { showMix = true }
                        }.accessibilityIdentifier("makeMix")
                    }
                }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 8).background(Palette.background)
            }
            .navigationDestination(isPresented: $showMix) { MixView(store: store) }
            .sheet(item: $sheet) { selected in
                switch selected {
                case .sources: SourcePicker(store: store)
                case .connections: ConnectionsView()
                case .recent: RecentView(store: store) { showMix = true }
                }
            }
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: "waveform.path").font(.title).foregroundStyle(Palette.accent).accessibilityHidden(true); Spacer(); DemoBadge().labelStyle(.titleAndIcon) }
            Text("Your music.\nThis moment.").font(.title.weight(.semibold)).tracking(-0.8)
            Text("Make a little room for the right songs.").font(.subheadline).foregroundStyle(Palette.secondary)
        }.padding(.top, 4)
    }
    private var sourceButton: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FROM YOUR PLAYLIST").font(.caption.weight(.semibold)).tracking(1.3).foregroundStyle(Palette.secondary)
            Button { sheet = .sources } label: {
                HStack(spacing: 14) {
                    SourceArtwork()
                    VStack(alignment: .leading, spacing: 5) {
                        Text(store.source?.title ?? "No playlist available").font(.headline)
                        Text("\(store.source?.tracks.count ?? 0) sample songs · Demo library").font(.caption).foregroundStyle(Palette.secondary)
                    }
                    Spacer(minLength: 0); Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                }.padding(14).background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
            }.buttonStyle(.plain).accessibilityIdentifier("sourcePicker")
        }
    }
    private var moodInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What are you in\nthe mood for?").font(.title2.weight(.semibold)).tracking(-0.3)
            TextField("Describe a mood or activity", text: $store.prompt, axis: .vertical)
                .lineLimit((promptFocused ? 1 : 3)...7).font(.body).padding(16)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
                .focused($promptFocused).accessibilityLabel("Mood or activity").accessibilityIdentifier("moodInput")
        }
    }
    private var suggestionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A PLACE TO START").font(.caption.weight(.semibold)).tracking(1.3).foregroundStyle(Palette.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.0) { suggestion in
                        Button { store.prompt = suggestion.2 } label: {
                            Label(suggestion.0, systemImage: suggestion.1).font(.subheadline)
                                .padding(.horizontal, 14).padding(.vertical, 12)
                                .background(Palette.surface, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
    }
    private var durationPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("TIME TO YOURSELF").font(.caption.weight(.semibold)).tracking(1.3).foregroundStyle(Palette.secondary); Spacer() }
            Picker("Approximate duration", selection: $store.minutes) {
                ForEach([15,30,45], id: \.self) { Text("\($0) min").tag($0) }
            }.pickerStyle(.segmented)
            HStack {
                Text("Duration is approximate.").font(.caption).foregroundStyle(Palette.secondary)
                Spacer()
                Button("Recent mixes") { sheet = .recent }.font(.caption.weight(.medium))
            }
        }
    }
}
