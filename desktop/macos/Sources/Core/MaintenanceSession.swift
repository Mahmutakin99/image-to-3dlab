import Foundation

public struct ServerOwnership: Codable, Equatable, Sendable {
    public let instance: String
    public let secret: String
    public let commit: String

    public init(commit: String) {
        instance = UUID().uuidString
        secret = UUID().uuidString + UUID().uuidString
        self.commit = commit
    }
    public var environment: [String: String] {
        ["I3D_DESKTOP_INSTANCE": instance, "I3D_DESKTOP_OWNER": secret, "I3D_DESKTOP_COMMIT": commit]
    }
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func load(from url: URL) throws -> Self {
        try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
}

public enum MaintenanceSessionError: Error {
    case foreignServer, leaseMissing, invalidResponse, requestFailed(Int)
}

public actor MaintenanceSession {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, Int)
    private struct Identity: Decodable {
        let schemaVersion: Int
        let managed: Bool
        let instance: String?
        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version", managed, instance
        }
    }
    private struct Lease: Decodable { let token: String; let active: Bool }
    private struct Shutdown: Decodable { let stopping: Bool }
    private struct Resume: Decodable { let active: Bool }
    private let ownership: ServerOwnership
    private let fetch: Fetch
    private var token: String?

    public init(ownership: ServerOwnership, fetch: @escaping Fetch = MaintenanceSession.download) {
        self.ownership = ownership
        self.fetch = fetch
    }

    public func begin() async throws {
        guard token == nil else { return }
        let identity = try JSONDecoder().decode(Identity.self, from: await request("desktop-runtime", status: 200))
        guard identity.schemaVersion == 1, identity.managed, identity.instance == ownership.instance else {
            throw MaintenanceSessionError.foreignServer
        }
        let lease = try JSONDecoder().decode(Lease.self, from: await request("maintenance/begin", method: "POST", status: 200))
        guard lease.active, !lease.token.isEmpty else { throw MaintenanceSessionError.invalidResponse }
        token = lease.token
    }

    public func shutdown() async throws {
        guard let token else { throw MaintenanceSessionError.leaseMissing }
        let response = try JSONDecoder().decode(Shutdown.self,
            from: await request("maintenance/shutdown", method: "POST", token: token, status: 202))
        guard response.stopping else { throw MaintenanceSessionError.invalidResponse }
        self.token = nil
    }

    public func resume() async throws {
        guard let token else { return }
        let response = try JSONDecoder().decode(Resume.self,
            from: await request("maintenance/end", method: "POST", token: token, status: 200))
        guard !response.active else { throw MaintenanceSessionError.invalidResponse }
        self.token = nil
    }

    private func request(_ path: String, method: String = "GET", token: String? = nil, status: Int) async throws -> Data {
        guard let url = URL(string: "http://127.0.0.1:8777/api/" + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = method
        if method == "POST" {
            request.setValue("1", forHTTPHeaderField: "X-AssetFurnace-Request")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(ownership.secret, forHTTPHeaderField: "X-AssetFurnace-Owner")
            request.httpBody = try JSONEncoder().encode(token.map { ["token": $0] } ?? [:])
        }
        let (data, actualStatus) = try await fetch(request)
        guard actualStatus == status else { throw MaintenanceSessionError.requestFailed(actualStatus) }
        return data
    }

    public static func download(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http.statusCode)
    }
}
