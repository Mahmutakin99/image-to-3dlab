import XCTest
@testable import Core

final class RuntimeStoreTests: XCTestCase {
    func testInvalidCandidateCannotReplaceWorkingSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeStore(root: root)
        XCTAssertThrowsError(try store.activate(version: "../escape", validate: { _ in true }))
        XCTAssertNil(store.current())
        XCTAssertThrowsError(try store.activate(version: "desktop-0.2.0", validate: { _ in false }))
        XCTAssertNil(store.current())
    }
    func testActivationAndRollbackKeepPreviousRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeStore(root: root)
        try store.activate(version: "desktop-0.2.0", validate: { _ in true })
        try store.activate(version: "desktop-0.3.0", validate: { _ in true })
        XCTAssertEqual(store.current()?.lastPathComponent, "desktop-0.3.0")
        try store.rollback(validate: { _ in true })
        XCTAssertEqual(store.current()?.lastPathComponent, "desktop-0.2.0")
    }
}

private actor RuntimeCommandProbe {
    private(set) var calls = 0
    func fail(_ args: [String], _ cwd: URL) async throws {
        calls += 1
        throw URLError(.notConnectedToInternet)
    }
}

final class RuntimeInstallerTests: XCTestCase {
    func testDownloadFailureLeavesCurrentSelectionIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeStore(root: root)
        try store.activate(version: "working", validate: { _ in true })
        let probe = RuntimeCommandProbe()
        let installer = RuntimeInstaller(store: store, execute: { try await probe.fail($0, $1) })
        do {
            _ = try await installer.prepare(commit: String(repeating: "a", count: 40),
                                            sharedInstallation: root, uv: URL(fileURLWithPath: "/uv"))
            XCTFail("Expected download failure")
        } catch { }
        XCTAssertEqual(store.current()?.lastPathComponent, "working")
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }
    func testInvalidCommitNeverRunsCommands() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let probe = RuntimeCommandProbe()
        let installer = RuntimeInstaller(store: RuntimeStore(root: root), execute: { try await probe.fail($0, $1) })
        do {
            _ = try await installer.prepare(commit: "main; anything", sharedInstallation: root,
                                            uv: URL(fileURLWithPath: "/uv"))
            XCTFail("Expected invalid commit")
        } catch { }
        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
    }
}

private actor PreparedRuntimeProbe {
    let failHealth: Bool
    init(failHealth: Bool) { self.failHealth = failHealth }
    func execute(_ args: [String], _ cwd: URL) async throws {
        if args.contains("clone"), let destination = args.last {
            let root = URL(fileURLWithPath: destination)
            let manager = FileManager.default
            try manager.createDirectory(at: root.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
            try manager.createDirectory(at: root.appendingPathComponent("viewer"), withIntermediateDirectories: true)
            for path in [".venv/bin/python", "viewer/serve.py", "viewer/studio.html"] {
                try Data().write(to: root.appendingPathComponent(path))
            }
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(".venv/bin/python").path)
        }
        if args.contains("-c") {
            let kind = try FileManager.default.attributesOfItem(atPath: cwd.appendingPathComponent("output").path)[.type] as? FileAttributeType
            XCTAssertEqual(kind, .typeDirectory, "Health check must use an isolated library")
            if failHealth { throw URLError(.cannotConnectToHost) }
        }
    }
}

extension RuntimeInstallerTests {
    func testHealthyCandidateSharesLibraryOnlyAfterValidationAndDoesNotActivate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeStore(root: root.appendingPathComponent("managed"))
        let shared = root.appendingPathComponent("original")
        for name in ["vendor", "output"] {
            try FileManager.default.createDirectory(at: shared.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let probe = PreparedRuntimeProbe(failHealth: false)
        let installer = RuntimeInstaller(store: store, execute: { try await probe.execute($0, $1) })
        let candidate = try await installer.prepare(commit: String(repeating: "b", count: 40),
                                                    sharedInstallation: shared, uv: URL(fileURLWithPath: "/uv"))
        XCTAssertNil(store.current())
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: candidate.appendingPathComponent("output").path)
        XCTAssertEqual(destination, shared.appendingPathComponent("output").path)
    }
    func testFailedHealthCheckNeverActivatesOrAttachesLibrary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeStore(root: root.appendingPathComponent("managed"))
        let shared = root.appendingPathComponent("original")
        for name in ["vendor", "output"] {
            try FileManager.default.createDirectory(at: shared.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let probe = PreparedRuntimeProbe(failHealth: true)
        let installer = RuntimeInstaller(store: store, execute: { try await probe.execute($0, $1) })
        do {
            _ = try await installer.prepare(commit: String(repeating: "c", count: 40),
                                            sharedInstallation: shared, uv: URL(fileURLWithPath: "/uv"))
            XCTFail("Expected failed health check")
        } catch { }
        XCTAssertNil(store.current())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: shared.appendingPathComponent("output").path).isEmpty)
    }
}

extension RuntimeInstallerTests {
    func testInterruptedCloneCanBeRetriedWithoutTouchingSharedFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeStore(root: root.appendingPathComponent("managed"))
        let commit = String(repeating: "d", count: 40)
        let candidate = try store.directory(version: commit)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: candidate.appendingPathComponent("partial-download"))
        let shared = root.appendingPathComponent("original")
        for name in ["vendor", "output"] {
            try FileManager.default.createDirectory(at: shared.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let sentinel = shared.appendingPathComponent("output/keep.glb")
        try Data("model".utf8).write(to: sentinel)
        let probe = PreparedRuntimeProbe(failHealth: false)
        let installer = RuntimeInstaller(store: store, execute: { try await probe.execute($0, $1) })
        _ = try await installer.prepare(commit: commit, sharedInstallation: shared, uv: URL(fileURLWithPath: "/uv"))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("model".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: candidate.appendingPathComponent("partial-download").path))
    }
    func testIncompleteSelectedRuntimeIsNeverDeletedForRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeStore(root: root)
        let commit = String(repeating: "e", count: 40)
        let candidate = try store.directory(version: commit)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        let sentinel = candidate.appendingPathComponent("keep")
        try Data("selected".utf8).write(to: sentinel)
        try store.activate(version: commit, validate: { _ in true })
        let probe = PreparedRuntimeProbe(failHealth: false)
        let installer = RuntimeInstaller(store: store, execute: { try await probe.execute($0, $1) })
        do {
            _ = try await installer.prepare(commit: commit, sharedInstallation: root, uv: URL(fileURLWithPath: "/uv"))
            XCTFail("Selected invalid runtime must be preserved")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("selected".utf8))
    }
    func testSymlinkCandidateNeverWritesOutsideStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RuntimeStore(root: root.appendingPathComponent("managed"))
        let commit = String(repeating: "f", count: 40)
        let candidate = try store.directory(version: commit)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: candidate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: candidate, withDestinationURL: outside)
        let probe = RuntimeCommandProbe()
        let installer = RuntimeInstaller(store: store, execute: { try await probe.fail($0, $1) })
        do {
            _ = try await installer.prepare(commit: commit, sharedInstallation: root, uv: URL(fileURLWithPath: "/uv"))
            XCTFail("Symlink candidate must be rejected")
        } catch { }
        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}

extension RuntimeInstallerTests {
    func testRealCommandRunnerReportsExitFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try await RuntimeInstaller.run(["/usr/bin/false"], root)
            XCTFail("A failed subprocess must not be treated as a successful installation")
        } catch RuntimeInstallError.commandFailed(let status) {
            XCTAssertEqual(status, 1)
        }
    }
    func testRealCommandRunnerCapturesOutputInPrivateLog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await RuntimeInstaller.run(["/bin/echo", "runtime-smoke-test"], root)
        let logs = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".desktop-install-logs"),
                                                              includingPropertiesForKeys: nil)
        let log = try XCTUnwrap(logs.first)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), "runtime-smoke-test\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: log.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
}
