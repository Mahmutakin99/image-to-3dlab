import Foundation

public enum RuntimeStoreError: Error {
    case invalidVersion, unhealthyCandidate, noPreviousRuntime
}

/// Selection changes are atomic. The installer prepares and health-checks a candidate
/// in its final directory before activation, so Python's absolute paths never move.
public struct RuntimeStore {
    private struct Selection: Codable {
        let current: String
        let previous: String?
    }
    public let root: URL
    private var stateURL: URL { root.appendingPathComponent("runtime-selection.json") }

    public init(root: URL) { self.root = root }

    public func directory(version: String) throws -> URL {
        guard !version.isEmpty, version.count <= 100,
              version.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0)
                  || (97...122).contains($0) || $0 == 45 || $0 == 46 }),
              version != ".", version != ".." else { throw RuntimeStoreError.invalidVersion }
        return root.appendingPathComponent("runtimes", isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    public func retains(version: String) -> Bool {
        guard let selection = read() else { return false }
        return selection.current == version || selection.previous == version
    }

    public func current() -> URL? {
        guard let selection = read() else { return nil }
        return try? directory(version: selection.current)
    }

    public func activate(version: String, validate: (URL) -> Bool = Installation.isValid) throws {
        let candidate = try directory(version: version)
        guard validate(candidate) else { throw RuntimeStoreError.unhealthyCandidate }
        let selection = read()
        guard selection?.current != version else { return }
        try write(Selection(current: version, previous: selection?.current))
    }

    public func rollback(validate: (URL) -> Bool = Installation.isValid) throws {
        guard let selection = read(), let previous = selection.previous else {
            throw RuntimeStoreError.noPreviousRuntime
        }
        let candidate = try directory(version: previous)
        guard validate(candidate) else { throw RuntimeStoreError.unhealthyCandidate }
        try write(Selection(current: previous, previous: selection.current))
    }

    private func read() -> Selection? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(Selection.self, from: data)
    }
    private func write(_ selection: Selection) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(selection).write(to: stateURL, options: .atomic)
    }
}
