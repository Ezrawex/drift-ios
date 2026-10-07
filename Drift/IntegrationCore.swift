import Foundation

// Provider-independent contracts. Qobuz access remains unimplemented; the
// separately gated ChatGPT plan transport is not connected to the demo UI.
struct PlaylistPage: Sendable {
    let offset: Int
    let total: Int
    let revision: String?
    let title: String
    let tracks: [Track] // Playlist entries, including repeated recordings.
}
protocol PlaylistPageTransport: Sendable {
    func page(playlistID: String, offset: Int, limit: Int) async throws -> PlaylistPage
}
enum IntegrationError: LocalizedError {
    case inconsistentImport, importTooLarge, invalidAI, recoveryRequired, exportConflict, exportBusy
    var errorDescription: String? {
        switch self {
        case .inconsistentImport: "The playlist changed or a page was incomplete. Import again before making a mix."
        case .importTooLarge: "This playlist exceeds the configured import limit. No partial library was accepted."
        case .invalidAI: "The AI selection failed local validation after one repair attempt."
        case .recoveryRequired: "An export may still be pending. Check Qobuz before creating or adding anything again."
        case .exportConflict: "The exported playlist does not match the private ordered mix. No further writes were made."
        case .exportBusy: "An export is already running."
        }
    }
}
struct PaginatedImporter: Sendable {
    let transport: any PlaylistPageTransport
    var pageSize = 100
    var maximumEntries = 100_000
    func importPlaylist(id: String) async throws -> SourcePlaylist {
        guard pageSize > 0, maximumEntries > 0 else { throw IntegrationError.inconsistentImport }
        let first = try await scan(id: id)
        // A provider revision must represent the full snapshot. Without one, compare two complete reads.
        if first.revision == nil {
            let second = try await scan(id: id)
            guard second.tracks == first.tracks, second.title == first.title, second.revision == nil else { throw IntegrationError.inconsistentImport }
        }
        let inventory = Dictionary(grouping: first.tracks, by: \.id)
        guard inventory.values.allSatisfy({ Set($0).count == 1 }) else { throw IntegrationError.inconsistentImport }
        return SourcePlaylist(id: id, title: first.title, subtitle: "Imported playlist", tracks: first.tracks)
    }
    private func scan(id: String) async throws -> (tracks: [Track], title: String, revision: String?) {
        var tracks: [Track] = [], total: Int?, title: String?, revision: String?
        repeat {
            try Task.checkCancellation()
            let page = try await transport.page(playlistID: id, offset: tracks.count, limit: pageSize)
            try Task.checkCancellation()
            guard page.total >= 0, page.total <= maximumEntries else { throw IntegrationError.importTooLarge }
            if total == nil { total = page.total; title = page.title; revision = page.revision }
            guard page.offset == tracks.count, page.total == total, page.title == title, page.revision == revision,
                  page.tracks.count <= pageSize, tracks.count + page.tracks.count <= page.total,
                  !page.tracks.isEmpty || tracks.count == page.total else { throw IntegrationError.inconsistentImport }
            tracks.append(contentsOf: page.tracks)
        } while tracks.count < (total ?? 0)
        return (tracks, title ?? "Playlist", revision)
    }
}

struct SelectionRequest: Sendable {
    let prompt: String
    let source: SourcePlaylist
    let minutes: Int
    var excluded: Set<String> = []
    var preferred: Set<String> = []
}
protocol CloudSelectionTransport: Sendable {
    // Provider adapter must send only selected playlist metadata and the user's prompt, after consent.
    // Response schema: {"track_ids":["source-recording-id", ...]}; no inferred audio features.
    func selection(_ request: SelectionRequest, repairingInvalidResponse: Bool) async throws -> Data
}
struct ValidatedCloudSelector: Sendable {
    let transport: any CloudSelectionTransport
    func select(_ request: SelectionRequest) async throws -> [Track] {
        for repair in [false, true] {
            try Task.checkCancellation()
            let response = try await transport.selection(request, repairingInvalidResponse: repair)
            try Task.checkCancellation()
            do {
                let tracks = try Self.validate(response, request: request)
                return tracks
            } catch {
                if repair { throw IntegrationError.invalidAI }
            }
        }
        throw IntegrationError.invalidAI
    }
    static func validate(_ data: Data, request: SelectionRequest) throws -> [Track] {
        guard data.count <= 1_000_000, request.minutes > 0, request.minutes <= Int.max / 60,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["track_ids"], let ids = object["track_ids"] as? [String] else { throw IntegrationError.invalidAI }
        let tracks = try SelectionValidator.validate(ids: ids, source: request.source.tracks, excluded: request.excluded)
        guard request.preferred.isSubset(of: Set(ids)), tracks.allSatisfy({ $0.seconds > 0 }) else { throw IntegrationError.invalidAI }
        // Duration is calculated locally. Reject a response missing the target by more than one longest song.
        let longest = request.source.tracks.filter { $0.available && !request.excluded.contains($0.id) }.map(\.seconds).max() ?? 0
        var total = 0
        for track in tracks {
            let (next, overflow) = total.addingReportingOverflow(track.seconds)
            guard !overflow else { throw IntegrationError.invalidAI }
            total = next
        }
        // Both operands are nonnegative bounded Ints, so subtraction/abs are safe.
        guard abs(total - request.minutes * 60) <= longest else { throw IntegrationError.invalidAI }
        return tracks
    }
}

struct RemotePlaylist: Sendable {
    let id: String
    let isPublic: Bool
    let orderedTrackIDs: [String]
}
protocol PrivatePlaylistTransport: Sendable {
    // find/read must include complete pagination, provider ownership and the persisted unique export marker.
    func findOwnedPlaylists(marker: String) async throws -> [RemotePlaylist]
    func createPrivate(title: String, marker: String) async throws -> String
    func readComplete(id: String) async throws -> RemotePlaylist
    func append(id: String, orderedTrackIDs: [String]) async throws
}
struct ExportRecord: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case prepared, createIntent, created, appendIntent, verified }
    let mixID: UUID
    let marker: String
    let title: String
    let orderedTrackIDs: [String]
    var playlistID: String?
    var phase: Phase
}
protocol ExportJournal: Sendable {
    func load(mixID: UUID) async throws -> ExportRecord?
    func save(_ record: ExportRecord) async throws
}
actor FileExportJournal: ExportJournal {
    let directory: URL
    init(directory: URL) { self.directory = directory }
    func load(mixID: UUID) throws -> ExportRecord? {
        let url = directory.appendingPathComponent(mixID.uuidString + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ExportRecord.self, from: Data(contentsOf: url))
    }
    func save(_ record: ExportRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(record.mixID.uuidString + ".json"), options: .atomic)
    }
}
actor ExportCoordinator {
    let transport: any PrivatePlaylistTransport
    let journal: any ExportJournal
    private var busy = false
    init(transport: any PrivatePlaylistTransport, journal: any ExportJournal) { self.transport = transport; self.journal = journal }
    // Not connected to the demo UI. Call only from an explicit export action once a live adapter is approved.
    func exportOnUserRequest(_ mix: Mix, source: SourcePlaylist) async throws -> ExportRecord {
        guard !busy else { throw IntegrationError.exportBusy }
        busy = true; defer { busy = false }
        guard mix.sourceID == source.id else { throw MixError.invalidSelection }
        _ = try SelectionValidator.validate(ids: mix.tracks.map(\.id), source: source.tracks, excluded: Set(mix.excludedTrackIDs ?? []))
        var record: ExportRecord
        if let existing = try await journal.load(mixID: mix.id) {
            guard existing.orderedTrackIDs == mix.tracks.map(\.id) else { throw IntegrationError.exportConflict }
            record = existing
        } else {
            record = ExportRecord(mixID: mix.id, marker: "drift-" + UUID().uuidString, title: mix.title,
                                  orderedTrackIDs: mix.tracks.map(\.id), playlistID: nil, phase: .prepared)
            try await journal.save(record)
        }
        try Task.checkCancellation()
        if record.phase == .prepared {
            record.phase = .createIntent; try await journal.save(record)
            try Task.checkCancellation()
            record.playlistID = try await transport.createPrivate(title: record.title, marker: record.marker)
            record.phase = .created; try await journal.save(record)
        } else if record.playlistID == nil {
            let found = try await transport.findOwnedPlaylists(marker: record.marker)
            guard found.count == 1, let foundID = found.first?.id else { throw IntegrationError.recoveryRequired }
            record.playlistID = foundID; record.phase = .created; try await journal.save(record)
        }
        guard let id = record.playlistID else { throw IntegrationError.recoveryRequired }
        try Task.checkCancellation()
        var remote = try await transport.readComplete(id: id)
        guard remote.id == id, !remote.isPublic else { throw IntegrationError.exportConflict }
        if remote.orderedTrackIDs != record.orderedTrackIDs {
            // Any unknown append outcome is read back, never blindly retried, including an empty read.
            guard record.phase == .created, remote.orderedTrackIDs.isEmpty else { throw IntegrationError.recoveryRequired }
            record.phase = .appendIntent; try await journal.save(record)
            try Task.checkCancellation()
            try await transport.append(id: id, orderedTrackIDs: record.orderedTrackIDs)
            remote = try await transport.readComplete(id: id)
            guard remote.id == id, !remote.isPublic, remote.orderedTrackIDs == record.orderedTrackIDs else { throw IntegrationError.exportConflict }
        }
        record.phase = .verified; try await journal.save(record)
        return record
    }
}
