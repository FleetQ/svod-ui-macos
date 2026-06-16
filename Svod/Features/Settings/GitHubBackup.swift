import Foundation
import AppKit

// MARK: - GitHubBackup
//
// One-click backup setup via GitHub's OAuth **Device Flow** (no client secret, no
// redirect URL needed). The flow runs entirely in the app:
//   request device code → user authorizes in the browser → poll for a token →
//   ensure a private `svod-backup-<vault>` repo exists → store the authenticated
//   remote URL in the macOS Keychain → hand back a `keychain:` ref.
//
// SECURITY: the access token is written to the Keychain locally and the engine
// only ever receives a `keychain:<account>` REFERENCE over the (loopback) App API
// — the raw token never crosses the API nor lands in the engine config. The
// Keychain item is created with an open ACL (`security -A`) so the headless engine
// can resolve it without a GUI prompt.

@MainActor
final class GitHubBackup: ObservableObject {
    /// Public OAuth App client id (device flow needs no secret).
    static let clientID = "Ov23liNkXS7CerjNmDa8"
    /// `repo` = create + push to a private repo (classic OAuth scopes have no narrower option).
    static let scope = "repo"

    enum Phase: Equatable {
        case idle
        case requesting
        case awaitingAuth(userCode: String, verificationURI: String)
        case finishing
        case connected(repo: String)
        case failed(String)
    }
    @Published var phase: Phase = .idle

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 20
        return URLSession(configuration: c)
    }()

    func reset() { phase = .idle }

    /// Full flow. Returns (keychain ref, "owner/repo") on success, nil on failure
    /// (with `phase == .failed`).
    func connect(vaultId: String, repoName: String? = nil) async -> (ref: String, repo: String)? {
        do {
            phase = .requesting
            let dc = try await requestDeviceCode()
            phase = .awaitingAuth(userCode: dc.userCode, verificationURI: dc.verificationUri)
            if let url = URL(string: dc.verificationUri) { NSWorkspace.shared.open(url) }

            let token = try await pollForToken(dc)
            phase = .finishing
            let name = Self.sanitizeRepoName(repoName) ?? "svod-backup-\(vaultId)"
            let login = try await ensureRepo(token: token, name: name)
            // Best-effort: replace the default README so the repo doesn't look empty
            // (the snapshots live on a custom ref GitHub's UI hides) and nobody deletes it.
            try? await writeReadme(token: token, login: login, name: name, vaultId: vaultId)
            let authedURL = "https://x-access-token:\(token)@github.com/\(login)/\(name).git"
            let ref = try storeRemote(vaultId: vaultId, url: authedURL)
            let repo = "\(login)/\(name)"
            phase = .connected(repo: repo)
            return (ref, repo)
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            return nil
        }
    }

    /// Coerce a user-typed name into a valid GitHub repo name (alnum, `-_.`); nil if empty.
    private static func sanitizeRepoName(_ s: String?) -> String? {
        guard let s else { return nil }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.")
        let cleaned = String(s.trimmingCharacters(in: .whitespaces).unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "-" })
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: device flow
    private struct DeviceCode: Decodable {
        let deviceCode: String, userCode: String, verificationUri: String, interval: Int, expiresIn: Int
        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code", userCode = "user_code"
            case verificationUri = "verification_uri", interval, expiresIn = "expires_in"
        }
    }

    private func requestDeviceCode() async throws -> DeviceCode {
        let r = URLRequest.form(
            "https://github.com/login/device/code",
            ["client_id": Self.clientID, "scope": Self.scope])
        let (data, _) = try await session.data(for: r)
        do { return try JSONDecoder().decode(DeviceCode.self, from: data) }
        catch { throw GHError.message("GitHub didn’t return a device code. Check the network and the OAuth app’s Device Flow setting.") }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String?, error: String?, errorDescription: String?
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", error, errorDescription = "error_description"
        }
    }

    private func pollForToken(_ dc: DeviceCode) async throws -> String {
        let deadline = Date().addingTimeInterval(TimeInterval(dc.expiresIn))
        var interval = dc.interval
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(max(interval, 1)) * 1_000_000_000)
            let r = URLRequest.form(
                "https://github.com/login/oauth/access_token",
                ["client_id": Self.clientID, "device_code": dc.deviceCode,
                 "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
            let (data, _) = try await session.data(for: r)
            let t = try JSONDecoder().decode(TokenResponse.self, from: data)
            if let token = t.accessToken, !token.isEmpty { return token }
            switch t.error {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "expired_token": throw GHError.message("The authorization code expired. Try again.")
            case "access_denied": throw GHError.message("Authorization was denied.")
            case let e?: throw GHError.message(t.errorDescription ?? e)
            case nil: continue
            }
        }
        throw GHError.message("Timed out waiting for GitHub authorization.")
    }

    // MARK: repo
    private func ensureRepo(token: String, name: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.github.com/user/repos")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": name, "private": true, "auto_init": true, "description": "Svod vault backup",
        ])
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        struct Repo: Decodable { struct Owner: Decodable { let login: String }; let owner: Owner }
        if code == 201, let r = try? JSONDecoder().decode(Repo.self, from: data) {
            return r.owner.login                       // freshly created
        }
        // 422 = already exists (or validation): fall back to the authenticated user.
        return try await currentLogin(token: token)
    }

    /// Overwrite the repo's README on the default branch so it explains the backup ref
    /// layout (the data lives under refs/svod/backup/<vault>, invisible in GitHub's file
    /// view) and warns not to delete the repo. Best-effort; never blocks the connect.
    private func writeReadme(token: String, login: String, name: String, vaultId: String) async throws {
        let api = "https://api.github.com/repos/\(login)/\(name)/contents/README.md"
        guard let url = URL(string: api) else { return }
        // Fetch the existing README sha (auto_init created one) — required to update it.
        var getReq = URLRequest(url: url)
        getReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        getReq.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (getData, getResp) = try await session.data(for: getReq)
        var sha: String?
        if (getResp as? HTTPURLResponse)?.statusCode == 200 {
            struct C: Decodable { let sha: String }
            sha = (try? JSONDecoder().decode(C.self, from: getData))?.sha
        }
        var put = URLRequest(url: url)
        put.httpMethod = "PUT"
        put.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        put.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "message": "Svod: document backup ref layout",
            "content": Data(Self.readmeBody(login: login, name: name, vaultId: vaultId).utf8).base64EncodedString(),
        ]
        if let sha { body["sha"] = sha }
        put.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await session.data(for: put)
    }

    private static func readmeBody(login: String, name: String, vaultId: String) -> String {
        let clone = "https://github.com/\(login)/\(name).git"
        return """
        # Svod vault backup

        ⚠️ **This repository is NOT empty — please don't delete it.**

        It is an off-site backup of a [Svod](https://github.com/FleetQ/svod-engine) knowledge
        vault. The notes are **not** stored on a normal branch, so GitHub's file browser shows
        only this README. The actual snapshots live under a custom git ref:

        ```
        refs/svod/backup/\(vaultId)
        ```

        GitHub's web UI lists only `refs/heads/*` (branches) and tags, so this ref is invisible
        here — but the data is fully present and restorable.

        ## See what's backed up

        ```
        git ls-remote \(clone)
        ```

        A line ending in `refs/svod/backup/\(vaultId)` is your latest snapshot (its sha).

        ## Inspect / restore locally

        ```
        git clone \(clone) svod-backup && cd svod-backup
        git fetch origin 'refs/svod/backup/*:refs/svod/backup/*'
        git switch -c restored refs/svod/backup/\(vaultId)
        # your notes are now in the working tree
        ```

        Normally you don't do this by hand — the Svod app restores from this ref for you.

        ---
        _Managed by Svod. This file is auto-generated; edits may be overwritten._
        """
    }

    private func currentLogin(token: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.github.com/user")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await session.data(for: req)
        struct U: Decodable { let login: String }
        guard let u = try? JSONDecoder().decode(U.self, from: data) else {
            throw GHError.message("Couldn’t read your GitHub account.")
        }
        return u.login
    }

    // MARK: secret storage — a local 0600 file the engine resolves via a `file:` ref
    //
    // The authenticated remote URL (with the token) is written to a user-only file
    // and handed to the engine as `file:<path>` — never on argv (no `ps` leak) and
    // not in a world-readable Keychain item. Mirrors how git's credential.store /
    // ~/.netrc keep push credentials. The raw token still never crosses the App API.
    private func storeRemote(vaultId: String, url: String) throws -> String {
        let fm = FileManager.default
        let dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true)
            .appendingPathComponent("Svod", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let file = dir.appendingPathComponent("backup-\(vaultId).remote")
        // Create empty with 0600 first so the secret is never briefly world-readable.
        if !fm.fileExists(atPath: file.path) {
            fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try url.write(to: file, atomically: false, encoding: .utf8)
        return "file:\(file.path)"
    }

    enum GHError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
    }
}

private extension URLRequest {
    /// A form-encoded POST that asks for a JSON response.
    static func form(_ url: String, _ fields: [String: String]) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        r.httpBody = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        return r
    }
}

private extension CharacterSet {
    static let urlQueryValueAllowed: CharacterSet = {
        var s = CharacterSet.urlQueryAllowed
        s.remove(charactersIn: "&=+")
        return s
    }()
}
