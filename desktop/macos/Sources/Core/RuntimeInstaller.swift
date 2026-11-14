import Foundation

public enum RuntimeInstallError: Error {
    case invalidCommit, incompleteCandidate, missingSharedDirectory, commandFailed(Int32)
}

/// Downloads code and dependencies only. Existing weights, engines and library stay in place.
public actor RuntimeInstaller {
    public typealias Execute = @Sendable ([String], URL) async throws -> Void
    private let store: RuntimeStore
    private let execute: Execute

    public init(store: RuntimeStore, execute: @escaping Execute = RuntimeInstaller.run) {
        self.store = store
        self.execute = execute
    }

    public func prepare(commit: String, sharedInstallation: URL, uv: URL) async throws -> URL {
        guard commit.count == 40, commit.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw RuntimeInstallError.invalidCommit
        }
        let candidate = try store.directory(version: commit)
        let manager = FileManager.default
        let candidateAttributes = try? manager.attributesOfItem(atPath: candidate.path)
        if let candidateAttributes {
            guard candidateAttributes[.type] as? FileAttributeType == .typeDirectory else {
                throw RuntimeInstallError.incompleteCandidate
            }
            if !Installation.isValid(at: candidate) {
                guard !store.retains(version: commit) else { throw RuntimeInstallError.incompleteCandidate }
                let recovery = store.root.appendingPathComponent("incomplete-installs", isDirectory: true)
                try manager.createDirectory(at: recovery, withIntermediateDirectories: true)
                try manager.moveItem(at: candidate,
                                     to: recovery.appendingPathComponent(commit + "-" + UUID().uuidString))
            }
        }
        if !manager.fileExists(atPath: candidate.path) {
            try manager.createDirectory(at: candidate.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await execute(["/usr/bin/git", "clone", "--no-checkout", "--depth=1",
                               "https://github.com/Mahmutakin99/image-to-3dlab.git", candidate.path], store.root)
            try await execute(["/usr/bin/git", "fetch", "--depth=1", "origin", commit], candidate)
            try await execute(["/usr/bin/git", "checkout", "--detach", commit], candidate)
            for name in ["vendor"] {
                let shared = sharedInstallation.appendingPathComponent(name, isDirectory: true)
                guard manager.fileExists(atPath: shared.path) else { throw RuntimeInstallError.missingSharedDirectory }
                try manager.createSymbolicLink(at: candidate.appendingPathComponent(name), withDestinationURL: shared)
            }
            try await execute([uv.path, "sync", "--frozen", "--no-dev", "--inexact", "--python", "3.11"], candidate)
        }
        guard Installation.isValid(at: candidate) else { throw RuntimeInstallError.incompleteCandidate }
        let ready = candidate.appendingPathComponent(".desktop-runtime-ready")
        if manager.fileExists(atPath: ready.path) { return candidate }
        let isolatedOutput = candidate.appendingPathComponent("output")
        let attributes = try? manager.attributesOfItem(atPath: isolatedOutput.path)
        guard attributes?[.type] as? FileAttributeType != .typeSymbolicLink else {
            throw RuntimeInstallError.incompleteCandidate
        }
        try manager.createDirectory(at: isolatedOutput, withIntermediateDirectories: true)
        try await execute([candidate.appendingPathComponent(".venv/bin/python").path, "-c", Self.healthCheck], candidate)
        let library = sharedInstallation.appendingPathComponent("output", isDirectory: true)
        guard manager.fileExists(atPath: library.path) else { throw RuntimeInstallError.missingSharedDirectory }
        try manager.removeItem(at: isolatedOutput)
        try manager.createSymbolicLink(at: isolatedOutput, withDestinationURL: library)
        try Data(commit.utf8).write(to: ready, options: .atomic)
        // Activation is a separate action after the old, owned server has safely stopped.
        return candidate
    }

    public static func run(_ arguments: [String], _ directory: URL) async throws {
        guard let executable = arguments.first else { throw RuntimeInstallError.commandFailed(-1) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "VIRTUAL_ENV")
        environment["UV_PROJECT_ENVIRONMENT"] = directory.appendingPathComponent(".venv").path
        process.environment = environment
        let logDirectory = directory.appendingPathComponent(".desktop-install-logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let log = logDirectory.appendingPathComponent(UUID().uuidString + ".log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        process.standardOutput = handle
        process.standardError = handle
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { child in
                if child.terminationStatus == 0 { continuation.resume() }
                else { continuation.resume(throwing: RuntimeInstallError.commandFailed(child.terminationStatus)) }
            }
            do { try process.run() }
            catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
        }
    }

    private static let healthCheck = #"""
import json, socket, subprocess, sys, time, urllib.request
with socket.socket() as reservation:
    reservation.bind(('127.0.0.1', 0))
    port = reservation.getsockname()[1]
child = subprocess.Popen([sys.executable, 'viewer/serve.py', '--no-browser', '--port', str(port)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    for attempt in range(80):
        if child.poll() is not None:
            raise RuntimeError('Health-check server exited')
        try:
            with urllib.request.urlopen(f'http://127.0.0.1:{port}/api/catalog', timeout=1) as response:
                catalog = json.load(response)
            if catalog.get('schema_version') != 1 or not isinstance(catalog.get('backends'), list):
                raise RuntimeError('Unexpected catalog')
            break
        except OSError:
            time.sleep(.25)
    else:
        raise RuntimeError('Health-check server did not answer')
finally:
    child.terminate()
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
"""#
}
