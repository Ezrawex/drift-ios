import Foundation
import Observation

@MainActor @Observable final class DriftStore {
    let sources: [SourcePlaylist]
    private let generator: any MixGenerator
    private let defaults: UserDefaults
    var sourceID: String { didSet { defaults.set(sourceID, forKey: "source") } }
    var prompt = "A 30-minute run: upbeat, driving, a little angry, no slow songs."
    var minutes = 30
    var mix: Mix?
    var saved: [Mix] = []
    var generating = false
    var error: String?
    private(set) var historyWarning: String?
    private var undoMix: Mix?
    private var task: Task<Void, Never>?
    var source: SourcePlaylist? { sources.first { $0.id == sourceID } ?? sources.first }
    var canUndo: Bool { undoMix != nil }
    var isSaved: Bool { mix.map { saved.contains($0) } ?? false }
    init(repository: any PlaylistRepository = FixtureRepository(), generator: any MixGenerator = DemoGenerator(), defaults: UserDefaults = .standard) {
        self.sources = repository.playlists(); self.generator = generator; self.defaults = defaults
        let remembered = defaults.string(forKey: "source")
        sourceID = sources.first(where: { $0.id == remembered })?.id ?? sources.first?.id ?? ""
        if let data = defaults.data(forKey: "mixes") {
            do { saved = try JSONDecoder().decode([Mix].self, from: data) }
            catch { historyWarning = "Saved mixes could not be read. The original data is preserved; saving is paused." }
        }
    }
    func generate(completion: @escaping @MainActor () -> Void) {
        guard let source else { error = "No source playlist is available."; return }
        start(prompt: prompt, source: source, duration: minutes, previous: nil, completion: completion)
    }
    func refine() {
        guard let previous = mix, let source = sources.first(where: { $0.id == previous.sourceID }) else { return }
        sourceID = source.id
        start(prompt: previous.prompt + " More energetic.", source: source,
              duration: previous.requestedMinutes ?? max(15, (previous.seconds + 59) / 60), previous: previous, completion: {})
    }
    private func start(prompt request: String, source: SourcePlaylist, duration: Int, previous: Mix?, completion: @escaping @MainActor () -> Void) {
        guard !generating else { return }
        guard !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, (1...1440).contains(duration) else { error = "Enter a mood and a valid duration."; return }
        error = nil; generating = true
        let excluded = Set(previous?.excludedTrackIDs ?? [])
        let preferred = previous?.preferredTrackIDs ?? []
        let priorID = mix?.id
        let filtered = SourcePlaylist(id: source.id, title: source.title, subtitle: source.subtitle,
                                      tracks: source.tracks.filter { !excluded.contains($0.id) })
        task = Task {
            defer { generating = false; task = nil }
            do {
                var result: Mix
                do { result = try await generator.generate(prompt: request, source: filtered, minutes: duration) }
                catch MixError.noMatches where !preferred.isEmpty {
                    let kept = try SelectionValidator.validate(ids: preferred, source: source.tracks, excluded: excluded)
                    result = Mix(title: previous?.title ?? "Your mix", prompt: request, sourceID: source.id, tracks: kept)
                }
                try Task.checkCancellation()
                // A response belongs to the captured request, never a different selected playlist or opened mix.
                guard sourceID == source.id, mix?.id == priorID else { return }
                guard result.sourceID == source.id else { throw MixError.invalidSelection }
                var tracks = try SelectionValidator.validate(ids: result.tracks.map(\.id), source: source.tracks, excluded: excluded)
                if !preferred.isEmpty {
                    let kept = try SelectionValidator.validate(ids: preferred, source: source.tracks, excluded: excluded)
                    var sequence = kept
                    var seconds = kept.reduce(0) { $0 + $1.seconds }
                    for track in tracks where !preferred.contains(track.id) && seconds < duration * 60 {
                        sequence.append(track); seconds += track.seconds
                    }
                    tracks = sequence
                }
                result.tracks = tracks; result.prompt = request; result.requestedMinutes = duration
                result.excludedTrackIDs = Array(excluded).sorted(); result.preferredTrackIDs = preferred
                mix = result; self.prompt = request; minutes = duration; undoMix = previous; completion()
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }
    func cancel() { task?.cancel() }
    func remove(_ id: String) { remove(ids: [id]) }
    func remove(ids: [String]) {
        guard !generating, var current = mix else { return }
        let removing = Set(ids).intersection(current.tracks.map(\.id))
        guard !removing.isEmpty else { return }
        undoMix = current
        current.tracks.removeAll { removing.contains($0.id) }
        current.excludedTrackIDs = Array(Set(current.excludedTrackIDs ?? []).union(removing)).sorted()
        current.preferredTrackIDs = (current.preferredTrackIDs ?? []).filter { !removing.contains($0) }
        mix = current
    }
    func move(_ from: IndexSet, to: Int) {
        guard !generating, var current = mix, !from.isEmpty, from.allSatisfy({ current.tracks.indices.contains($0) }),
              (0...current.tracks.count).contains(to) else { return }
        undoMix = current
        let moving = from.sorted().map { current.tracks[$0] }
        for index in from.sorted(by: >) { current.tracks.remove(at: index) }
        current.tracks.insert(contentsOf: moving, at: to - from.filter { $0 < to }.count)
        mix = current
    }
    func replace(_ old: String, with new: Track) {
        guard !generating, var current = mix, let index = current.tracks.firstIndex(where: { $0.id == old }),
              sources.first(where: { $0.id == current.sourceID })?.tracks.contains(new) == true,
              !current.tracks.contains(where: { $0.id == new.id }), new.available else { return }
        undoMix = current; current.tracks[index] = new
        current.excludedTrackIDs = Array(Set(current.excludedTrackIDs ?? []).union([old]).subtracting([new.id])).sorted()
        current.preferredTrackIDs = (current.preferredTrackIDs ?? []).filter { $0 != old } + [new.id]
        mix = current
    }
    func togglePreferred(_ id: String) {
        guard !generating, var current = mix, current.tracks.contains(where: { $0.id == id }) else { return }
        undoMix = current
        var ids = current.preferredTrackIDs ?? []
        if ids.contains(id) { ids.removeAll { $0 == id } } else { ids.append(id) }
        current.preferredTrackIDs = ids; mix = current
    }
    func undo() {
        guard !generating, let undoMix else { return }
        mix = undoMix; restoreRequest(from: undoMix); self.undoMix = nil
    }
    func open(_ savedMix: Mix) {
        guard !generating else { return }
        mix = savedMix; restoreRequest(from: savedMix)
        undoMix = nil; error = nil
    }
    private func restoreRequest(from restored: Mix) {
        sourceID = restored.sourceID; prompt = restored.prompt
        minutes = restored.requestedMinutes ?? [15, 30, 45].min(by: { abs($0 * 60 - restored.seconds) < abs($1 * 60 - restored.seconds) }) ?? 30
    }
    @discardableResult func save() -> Bool {
        guard historyWarning == nil else { error = historyWarning; return false }
        guard let mix, !mix.tracks.isEmpty else { return false }
        var updated = saved.filter { $0.id != mix.id }; updated.insert(mix, at: 0); updated = Array(updated.prefix(20))
        do {
            let data = try JSONEncoder().encode(updated)
            defaults.set(data, forKey: "mixes"); saved = updated; return true
        } catch { self.error = "This mix could not be saved. Please try again."; return false }
    }
}
