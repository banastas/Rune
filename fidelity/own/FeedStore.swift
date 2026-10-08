// A feed store, generated for Nib's own highlighting samples (Sublime has no Swift).
import Foundation
import SwiftUI

/// One episode of a feed.
struct Episode: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var duration: TimeInterval = 0
    var tags: [String] = []

    var minutes: Int { Int(duration / 60) }
}

enum LoadState: Equatable {
    case idle, loading
    case failed(message: String)
}

protocol FeedSource {
    func episodes(for url: URL) async throws -> [Episode]
}

@MainActor
final class FeedStore: ObservableObject {
    @Published private(set) var episodes: [Episode] = []
    @Published var state: LoadState = .idle
    private let source: any FeedSource
    static let pageSize = 20

    init(source: some FeedSource) {
        self.source = source
    }

    func load(_ url: URL, retries: Int = 3) async {
        state = .loading
        for attempt in 1...retries {
            do {
                let fresh = try await source.episodes(for: url)
                episodes = fresh.filter { !$0.title.isEmpty }.sorted { $0.duration > $1.duration }
                state = .idle
                return
            } catch let error as URLError where error.code == .timedOut {
                print("try \(attempt): timed out")
            } catch {
                state = .failed(message: "\(error.localizedDescription) after \(attempt) tries")
            }
        }
    }

    func newest(_ count: Int = FeedStore.pageSize) -> ArraySlice<Episode> {
        guard !episodes.isEmpty else { return [] }
        return episodes.prefix(count)
    }
}

struct EpisodeRow: View {
    let episode: Episode

    var body: some View {
        HStack(spacing: 8) {
            Text(episode.title).font(.headline)
            Spacer()
            Text("\(episode.minutes) min").foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#if DEBUG
#Preview {
    EpisodeRow(episode: Episode(id: UUID(), title: "Plain Text Forever", duration: 2_537.5))
}
#endif
