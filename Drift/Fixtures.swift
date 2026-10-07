import Foundation

struct FixtureRepository: PlaylistRepository {
    func playlists() -> [SourcePlaylist] { Self.sources }
    static let tracks: [Track] = [
        .init(id: "demo-01", title: "First Light", artist: "Northbound", seconds: 218, energy: 3, sleeve: 0, available: true),
        .init(id: "demo-02", title: "Wide Awake", artist: "The Hours", seconds: 241, energy: 4, sleeve: 1, available: true),
        .init(id: "demo-03", title: "Night Current", artist: "Low Season", seconds: 264, energy: 4, sleeve: 2, available: true),
        .init(id: "demo-04", title: "No Turning Back", artist: "Parallel Lines", seconds: 203, energy: 5, sleeve: 3, available: true),
        .init(id: "demo-05", title: "Open Road", artist: "Soft Circuit", seconds: 229, energy: 3, sleeve: 4, available: true),
        .init(id: "demo-06", title: "The Long Way", artist: "Northbound", seconds: 278, energy: 4, sleeve: 5, available: true),
        .init(id: "demo-07", title: "Electric Air", artist: "Glass Avenue", seconds: 225, energy: 5, sleeve: 6, available: true),
        .init(id: "demo-08", title: "Keep Moving", artist: "The Hours", seconds: 236, energy: 3, sleeve: 7, available: true),
        .init(id: "demo-09", title: "Still Water", artist: "Low Season", seconds: 252, energy: 1, sleeve: 2, available: true),
        .init(id: "demo-10", title: "Paper Moon", artist: "Soft Circuit", seconds: 197, energy: 2, sleeve: 5, available: true),
        .init(id: "demo-11", title: "Window Seat", artist: "Glass Avenue", seconds: 281, energy: 2, sleeve: 4, available: true),
        .init(id: "demo-12", title: "Blue Hour", artist: "Parallel Lines", seconds: 246, energy: 1, sleeve: 1, available: true),
        .init(id: "demo-13", title: "Far From Here", artist: "Northbound", seconds: 224, energy: 2, sleeve: 0, available: true),
        .init(id: "demo-14", title: "In Between", artist: "The Hours", seconds: 213, energy: 1, sleeve: 3, available: true),
        .init(id: "demo-15", title: "Second Wind", artist: "Low Season", seconds: 232, energy: 4, sleeve: 6, available: true),
        .init(id: "demo-16", title: "Silver Street", artist: "Soft Circuit", seconds: 209, energy: 5, sleeve: 7, available: true)
    ]
    static let sources: [SourcePlaylist] = [
        .init(id: "demo-library", title: "The listening room", subtitle: "A little of everything", tracks: tracks),
        .init(id: "demo-quiet", title: "Quiet corners", subtitle: "Space to slow down", tracks: tracks.filter { $0.energy <= 2 })
    ]
}
