import Foundation

// MARK: - VaultKey
//
// How the app names a vault that lives on a REMOTE engine: `<vaultId>@<profileId>`. Vaults on
// the local engine keep their bare id, so every persisted path/vault pair, pin and setting from
// before multi-engine keeps meaning the same thing. `@` is safe: an engine vault id is
// `[a-z0-9][a-z0-9_-]*`, and `:` is already the separator `GlobalNoteRef` splits on.

public enum VaultKey {
    public static let separator: Character = "@"

    /// `make("socialscore", profileId: "central")` → `"socialscore@central"`; nil profile ⇒ the bare id.
    public static func make(_ vaultId: String, profileId: String?) -> String {
        guard let profileId, !profileId.isEmpty else { return vaultId }
        return "\(vaultId)\(separator)\(profileId)"
    }

    /// Split on the LAST `@` so a vault id can never be mistaken for a profile.
    public static func parse(_ key: String?) -> (vaultId: String?, profileId: String?) {
        guard let key, !key.isEmpty else { return (nil, nil) }
        guard let at = key.lastIndex(of: separator), at != key.startIndex, key.index(after: at) != key.endIndex else {
            return (key, nil)
        }
        return (String(key[..<at]), String(key[key.index(after: at)...]))
    }

    public static func isRemote(_ key: String?) -> Bool { parse(key).profileId != nil }
}
