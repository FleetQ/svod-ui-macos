import Foundation

/// The address a central engine may be added at. A personal key travels in every request, so a
/// plain `http://` address is accepted ONLY for a loopback host (a local engine, a dev box);
/// anything else must be `https://` — the warning in the sheet is not enough on its own.
public enum EngineAddress {
    public static func parse(_ text: String) -> URL? {
        let a = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: a), let scheme = u.scheme?.lowercased(), let host = u.host?.lowercased(), !host.isEmpty else { return nil }
        switch scheme {
        case "https": return u
        case "http": return isLoopback(host) ? u : nil
        default: return nil
        }
    }

    public static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased()
        return h == "127.0.0.1" || h == "localhost" || h == "::1" || h == "[::1]"
    }
}
