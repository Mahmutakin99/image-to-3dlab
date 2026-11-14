import Foundation

public enum UpdateSchedule {
    public static func isDue(lastCheck: TimeInterval?, now: TimeInterval, manual: Bool = false) -> Bool {
        guard !manual, let lastCheck else { return true }
        return now < lastCheck || now - lastCheck >= 86_400
    }
}

public struct ReleaseVersion: Comparable, Sendable {
    private let parts: [Int]
    public init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let tokens = text.split(separator: ".", omittingEmptySubsequences: false)
        guard tokens.count == 3, tokens.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = tokens.compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        parts = numbers
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.parts.lexicographicallyPrecedes(rhs.parts)
    }
}

public struct GitHubRelease: Codable, Sendable {
    public let tagName: String
    public let htmlURL: URL
    public let body: String?
    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url", body
    }
}

public actor ReleaseChecker {
    public typealias Fetch = @Sendable (URLRequest) async throws -> Data
    private struct Cache: Codable {
        var checkedAt: TimeInterval
        var release: GitHubRelease?
    }
    private let fetch: Fetch
    private let cacheURL: URL?
    private var cache: Cache?
    private var pending: Task<GitHubRelease, Error>?

    public init(cacheURL: URL? = nil, fetch: @escaping Fetch = ReleaseChecker.download) {
        self.cacheURL = cacheURL
        self.fetch = fetch
        if let cacheURL, let data = try? Data(contentsOf: cacheURL) {
            cache = try? JSONDecoder().decode(Cache.self, from: data)
        }
    }

    public static func download(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    public func check(now: TimeInterval = Date().timeIntervalSince1970,
                      manual: Bool = false) async throws -> GitHubRelease? {
        if let pending { return try await pending.value }
        guard UpdateSchedule.isDue(lastCheck: cache?.checkedAt, now: now, manual: manual) else {
            return cache?.release
        }
        let fetch = self.fetch
        let task = Task<GitHubRelease, Error> {
            guard let url = URL(string: "https://api.github.com/repos/Bingeljell/image-to-3dlab/releases/latest") else {
                throw URLError(.badURL)
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let result = try JSONDecoder().decode(GitHubRelease.self, from: await fetch(request))
            guard ReleaseVersion(result.tagName) != nil else { throw URLError(.cannotParseResponse) }
            return result
        }
        pending = task
        defer { pending = nil }
        do {
            let release = try await task.value
            save(Cache(checkedAt: now, release: release))
            return release
        } catch {
            save(Cache(checkedAt: now, release: cache?.release))
            throw error
        }
    }

    private func save(_ value: Cache) {
        cache = value
        guard let cacheURL else { return }
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(value) { try? data.write(to: cacheURL, options: .atomic) }
    }
}
