import Foundation

struct Track: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let seconds: Int
    let energy: Int // Authored fixture descriptor, not audio analysis.
    let sleeve: Int
    let available: Bool
    var time: String { String(format: "%d:%02d", seconds / 60, seconds % 60) }
}

struct SourcePlaylist: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let tracks: [Track]
}

struct Mix: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var prompt: String
    var sourceID: String
    var tracks: [Track]
    var requestedMinutes: Int? = nil
    var excludedTrackIDs: [String]? = nil
    var preferredTrackIDs: [String]? = nil
    var seconds: Int { tracks.reduce(0) { $0 + $1.seconds } }
    var duration: String { "\(seconds / 60) min \(seconds % 60) sec" }
}

enum MixError: LocalizedError {
    case noMatches, invalidSelection
    var errorDescription: String? {
        switch self {
        case .noMatches: "No suitable demo songs. Try a broader mood or choose another sample playlist."
        case .invalidSelection: "The selection could not be validated. Your previous mix is preserved."
        }
    }
}

protocol PlaylistRepository: Sendable { func playlists() -> [SourcePlaylist] }
protocol MixGenerator: Sendable {
    func generate(prompt: String, source: SourcePlaylist, minutes: Int) async throws -> Mix
}
protocol QobuzClient: Sendable { func importPlaylist(id: String) async throws -> SourcePlaylist }
protocol ExportService: Sendable { func export(_ mix: Mix) async throws -> URL }

struct SelectionValidator {
    static func validate(ids: [String], source: [Track], excluded: Set<String> = []) throws -> [Track] {
        let groups = Dictionary(grouping: source, by: \.id)
        guard groups.values.allSatisfy({ Set($0).count == 1 }) else { throw MixError.invalidSelection }
        let inventory = groups.mapValues { $0[0] }
        guard !ids.isEmpty, Set(ids).count == ids.count else { throw MixError.invalidSelection }
        return try ids.map { id in
            guard !id.isEmpty, let track = inventory[id], track.available, track.seconds > 0, !excluded.contains(id) else { throw MixError.invalidSelection }
            return track
        }
    }
}

struct DemoGenerator: MixGenerator {
    func generate(prompt: String, source: SourcePlaylist, minutes: Int) async throws -> Mix {
        try await Task.sleep(for: .milliseconds(850))
        try Task.checkCancellation()
        let text = prompt.lowercased()
        let fast = ["run", "energetic", "upbeat", "driving", "angry", "no slow"].contains { text.contains($0) }
        // The explicit refinement overrides the prior quiet descriptor; other constraints still apply.
        let refiningEnergy = text.hasSuffix(" more energetic.")
        let quiet = !refiningEnergy && ["focus", "quiet", "calm", "soft"].contains { text.contains($0) }
        // Bounded fixture keyword behavior only. This is not cloud AI or taste validation.
        var candidates = source.tracks.filter { track in
            track.available && (!fast || track.energy >= 3) && (!quiet || track.energy <= 2)
            && !(text.contains("no \(track.artist.lowercased())") || text.contains("exclude \(track.artist.lowercased())") || text.contains("don't include \(track.title.lowercased())"))
        }
        if fast { candidates.sort { $0.energy < $1.energy } }
        if quiet { candidates.sort { $0.energy > $1.energy } }
        guard !candidates.isEmpty else { throw MixError.noMatches }
        var selected: [Track] = []
        var total = 0
        for track in candidates where total < minutes * 60 {
            selected.append(track); total += track.seconds
        }
        let tracks = try SelectionValidator.validate(ids: selected.map(\.id), source: source.tracks)
        return Mix(title: fast ? "Find your stride" : quiet ? "A little room to focus" : "After the day", prompt: prompt, sourceID: source.id, tracks: tracks, requestedMinutes: minutes)
    }
}
