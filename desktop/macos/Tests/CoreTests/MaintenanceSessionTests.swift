import XCTest
@testable import Core

private actor MaintenanceProbe {
    let identity: String
    private(set) var paths: [String] = []
    init(instance: String) {
        identity = "{\"schema_version\":1,\"managed\":true,\"instance\":\"\(instance)\",\"commit\":\"abc\"}"
    }
    func fetch(_ request: URLRequest) async throws -> (Data, Int) {
        let path = request.url?.path ?? ""
        paths.append(path)
        switch path {
        case "/api/desktop-runtime": return (Data(identity.utf8), 200)
        case "/api/maintenance/begin":
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-AssetFurnace-Request"), "1")
            return (Data(#"{"token":"lease","active":true}"#.utf8), 200)
        case "/api/maintenance/shutdown":
            XCTAssertNotNil(request.value(forHTTPHeaderField: "X-AssetFurnace-Owner"))
            let body = try JSONDecoder().decode([String: String].self, from: request.httpBody ?? Data())
            XCTAssertEqual(body["token"], "lease")
            return (Data(#"{"stopping":true}"#.utf8), 202)
        case "/api/maintenance/end": return (Data(#"{"active":false}"#.utf8), 200)
        default: throw URLError(.unsupportedURL)
        }
    }
}

final class MaintenanceSessionTests: XCTestCase {
    func testForeignServerIsNeverLockedOrStopped() async throws {
        let ownership = ServerOwnership(commit: "abc")
        let probe = MaintenanceProbe(instance: "someone-else")
        let session = MaintenanceSession(ownership: ownership, fetch: { try await probe.fetch($0) })
        do { try await session.begin(); XCTFail("Expected foreign server rejection") } catch { }
        let paths = await probe.paths
        XCTAssertEqual(paths, ["/api/desktop-runtime"])
    }
    func testOwnedServerCanBeLockedAndStopped() async throws {
        let ownership = ServerOwnership(commit: "abc")
        let probe = MaintenanceProbe(instance: ownership.instance)
        let session = MaintenanceSession(ownership: ownership, fetch: { try await probe.fetch($0) })
        try await session.begin()
        try await session.shutdown()
        let paths = await probe.paths
        XCTAssertEqual(paths, ["/api/desktop-runtime", "/api/maintenance/begin", "/api/maintenance/shutdown"])
    }
    func testCancelledUpdateReleasesLeaseInsteadOfStoppingServer() async throws {
        let ownership = ServerOwnership(commit: "abc")
        let probe = MaintenanceProbe(instance: ownership.instance)
        let session = MaintenanceSession(ownership: ownership, fetch: { try await probe.fetch($0) })
        try await session.begin()
        try await session.resume()
        let paths = await probe.paths
        XCTAssertEqual(paths.last, "/api/maintenance/end")
        XCTAssertFalse(paths.contains("/api/maintenance/shutdown"))
    }
    func testOwnershipSurvivesReopeningWithPrivateFilePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("owner.json")
        let ownership = ServerOwnership(commit: "abc")
        try ownership.save(to: url)
        XCTAssertEqual(try ServerOwnership.load(from: url), ownership)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
