import XCTest
@testable import Core

final class UpdateTests: XCTestCase {
    func testDailyChecksAndManualOverride() {
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: nil, now: 100))
        XCTAssertFalse(UpdateSchedule.isDue(lastCheck: 100, now: 86499))
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: 100, now: 86500))
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: 100, now: 101, manual: true))
    }
    func testClockMovingBackwardsAllowsOneFreshCheck() {
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: 100, now: 99))
    }
    func testOnlyStableSemanticVersionsAreCompared() {
        XCTAssertTrue(ReleaseVersion("v0.5.10")! > ReleaseVersion("0.5.7")!)
        XCTAssertNil(ReleaseVersion("v1.0.0-beta"))
        XCTAssertNil(ReleaseVersion("garbage"))
        XCTAssertNil(ReleaseVersion("1.2"))
    }
}

private actor ReleaseProbe {
    private(set) var calls = 0
    func fetch(_ request: URLRequest) async throws -> Data {
        calls += 1
        try await Task.sleep(nanoseconds: 20_000_000)
        return Data(#"{"tag_name":"v0.5.10","html_url":"https://github.com/Bingeljell/image-to-3dlab/releases/tag/v0.5.10"}"#.utf8)
    }
}

final class UpdateClientTests: XCTestCase {
    func testConcurrentChecksShareRequestAndManualCheckBypassesCache() async throws {
        let probe = ReleaseProbe()
        let client = ReleaseChecker(fetch: { try await probe.fetch($0) })
        async let first = client.check(now: 100)
        async let second = client.check(now: 100)
        _ = try await (first, second)
        _ = try await client.check(now: 101)
        let cachedCalls = await probe.calls
        XCTAssertEqual(cachedCalls, 1)
        let release = try await client.check(now: 102, manual: true)
        XCTAssertEqual(release?.tagName, "v0.5.10")
        let manualCalls = await probe.calls
        XCTAssertEqual(manualCalls, 2)
    }
}

private actor OfflineProbe {
    private(set) var calls = 0
    func fetch(_ request: URLRequest) async throws -> Data {
        calls += 1
        throw URLError(.notConnectedToInternet)
    }
}

extension UpdateClientTests {
    func testOfflineCheckIsNotRepeatedUntilTomorrowButManualRetries() async throws {
        let probe = OfflineProbe()
        let client = ReleaseChecker(fetch: { try await probe.fetch($0) })
        do { _ = try await client.check(now: 100); XCTFail("Expected offline error") } catch { }
        let cached = try await client.check(now: 101)
        XCTAssertNil(cached)
        let automaticCalls = await probe.calls
        XCTAssertEqual(automaticCalls, 1)
        do { _ = try await client.check(now: 102, manual: true); XCTFail("Expected offline error") } catch { }
        let manualCalls = await probe.calls
        XCTAssertEqual(manualCalls, 2)
    }
    func testCacheSurvivesRecreatingChecker() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("cache.json")
        let online = ReleaseProbe()
        let first = ReleaseChecker(cacheURL: path, fetch: { try await online.fetch($0) })
        _ = try await first.check(now: 100)
        let offline = OfflineProbe()
        let second = ReleaseChecker(cacheURL: path, fetch: { try await offline.fetch($0) })
        let result = try await second.check(now: 101)
        XCTAssertEqual(result?.tagName, "v0.5.10")
        let calls = await offline.calls
        XCTAssertEqual(calls, 0)
    }
}
