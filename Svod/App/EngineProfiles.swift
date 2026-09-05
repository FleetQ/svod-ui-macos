import Foundation

// MARK: - EngineProfile / EngineProfileStore
//
// A "central engine" the app talks to besides the local one: a name, a base URL and a personal
// API key (engine ≥ contract 0.30.0, ADR-0019). Profiles (no secrets) persist in UserDefaults;
// the key lives in `~/Library/Application Support/Svod/engine-<id>.key` with mode 0600 — the same
// model as agent tokens and the GitHub backup remote. INJECT a `UserDefaults(suiteName:)` in
// tests: the XCTest host is the real app, and `.standard` is its live preferences.

public struct EngineProfile: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public var name: String
    public var baseURL: URL
    public init(id: String = UUID().uuidString.lowercased(), name: String, baseURL: URL) {
        self.id = id; self.name = name; self.baseURL = baseURL
    }
}

@MainActor
public final class EngineProfileStore: ObservableObject {
    public static let defaultsKey = "svod.settings.engineProfiles"

    @Published public private(set) var profiles: [EngineProfile] = []

    private let defaults: UserDefaults
    private let secretsDir: URL

    public init(defaults: UserDefaults = .standard, secretsDir: URL? = nil) {
        self.defaults = defaults
        self.secretsDir = secretsDir ?? Self.defaultSecretsDir()
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([EngineProfile].self, from: data) {
            profiles = decoded
        }
    }

    public func profile(_ id: String) -> EngineProfile? { profiles.first { $0.id == id } }

    /// Add (or replace by id) a profile and store its key 0600. The key never enters UserDefaults.
    @discardableResult
    public func add(_ profile: EngineProfile, apiKey: String) throws -> EngineProfile {
        try writeKey(apiKey, for: profile.id)
        profiles.removeAll { $0.id == profile.id }
        profiles.append(profile)
        persist()
        return profile
    }

    /// Forget a profile and delete its key file (only ever our own `engine-<id>.key`).
    public func remove(_ id: String) {
        profiles.removeAll { $0.id == id }
        persist()
        let f = keyFile(id)
        if f.lastPathComponent.hasPrefix("engine-"), f.pathExtension == "key" {
            try? FileManager.default.removeItem(at: f)
        }
    }

    public func apiKey(for id: String) -> String? {
        (try? String(contentsOf: keyFile(id), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func keyFile(_ id: String) -> URL { secretsDir.appendingPathComponent("engine-\(id).key") }

    private func persist() {
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    private func writeKey(_ key: String, for id: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: secretsDir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let file = keyFile(id)
        // Create empty with 0600 first so the secret is never briefly world-readable.
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try key.write(to: file, atomically: false, encoding: .utf8)
    }

    private static func defaultSecretsDir() -> URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Svod", isDirectory: true)
    }
}
