import SwiftUI
import Combine

// MARK: - SettingsStore
//
// Single source of every UI preference, persisted to UserDefaults. Owned by
// AppModel (`app.settings`); views observe it via @EnvironmentObject and feature
// models read it through their `app` back-reference. Changing a value publishes
// and persists immediately; wiring elsewhere reacts (theme, endpoint, autosave…).

public enum ThemeMode: String, CaseIterable, Sendable {
    case system, light, dark
    public var label: String { rawValue.capitalized }
    public var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

public enum Density: String, CaseIterable, Sendable {
    case comfortable, compact
    public var label: String { rawValue.capitalized }
}

@MainActor
public final class SettingsStore: ObservableObject {
    private let d = UserDefaults.standard
    private func key(_ k: String) -> String { "svod.settings.\(k)" }

    // MARK: Connection
    @Published public var endpointHost: String { didSet { d.set(endpointHost, forKey: key("endpointHost")) } }
    @Published public var endpointPort: Int { didSet { d.set(endpointPort, forKey: key("endpointPort")) } }
    @Published public var autoStartEngine: Bool { didSet { d.set(autoStartEngine, forKey: key("autoStartEngine")) } }
    @Published public var autoReconnect: Bool { didSet { d.set(autoReconnect, forKey: key("autoReconnect")) } }

    // MARK: Appearance
    @Published public var themeMode: ThemeMode { didSet { d.set(themeMode.rawValue, forKey: key("themeMode")) } }
    @Published public var readingMeasure: Double { didSet { d.set(readingMeasure, forKey: key("readingMeasure")) } }
    @Published public var editorFontSize: Double { didSet { d.set(editorFontSize, forKey: key("editorFontSize")) } }
    @Published public var density: Density { didSet { d.set(density.rawValue, forKey: key("density")) } }

    // MARK: Editor
    @Published public var autosave: Bool { didSet { d.set(autosave, forKey: key("autosave")) } }
    @Published public var autosaveDebounceMs: Int { didSet { d.set(autosaveDebounceMs, forKey: key("autosaveDebounceMs")) } }
    @Published public var focusByDefault: Bool { didSet { d.set(focusByDefault, forKey: key("focusByDefault")) } }
    @Published public var wikilinkAutocomplete: Bool { didSet { d.set(wikilinkAutocomplete, forKey: key("wikilinkAutocomplete")) } }
    @Published public var frontmatterTemplate: String { didSet { d.set(frontmatterTemplate, forKey: key("frontmatterTemplate")) } }

    // MARK: Search
    @Published public var defaultSearchMode: SearchMode { didSet { d.set(defaultSearchMode.rawValue, forKey: key("defaultSearchMode")) } }
    @Published public var searchResultLimit: Int { didSet { d.set(searchResultLimit, forKey: key("searchResultLimit")) } }
    @Published public var rememberQuery: Bool { didSet { d.set(rememberQuery, forKey: key("rememberQuery")) } }

    // MARK: Activity feed
    @Published public var showAgentActivity: Bool { didSet { d.set(showAgentActivity, forKey: key("showAgentActivity")) } }
    @Published public var showCommits: Bool { didSet { d.set(showCommits, forKey: key("showCommits")) } }
    @Published public var showFileChanges: Bool { didSet { d.set(showFileChanges, forKey: key("showFileChanges")) } }
    @Published public var showConflicts: Bool { didSet { d.set(showConflicts, forKey: key("showConflicts")) } }
    @Published public var feedCap: Int { didSet { d.set(feedCap, forKey: key("feedCap")) } }
    @Published public var feedAnimation: Bool { didSet { d.set(feedAnimation, forKey: key("feedAnimation")) } }

    // MARK: Graph
    @Published public var defaultGraphScopeLocal: Bool { didSet { d.set(defaultGraphScopeLocal, forKey: key("defaultGraphScopeLocal")) } }
    @Published public var graphPhysicsIntensity: Double { didSet { d.set(graphPhysicsIntensity, forKey: key("graphPhysicsIntensity")) } }

    // MARK: Startup
    @Published public var reopenLastNote: Bool { didSet { d.set(reopenLastNote, forKey: key("reopenLastNote")) } }
    @Published public var lastOpenedPath: String? { didSet { d.set(lastOpenedPath, forKey: key("lastOpenedPath")) } }

    public init() {
        let ud = UserDefaults.standard
        func b(_ k: String, _ def: Bool) -> Bool { ud.object(forKey: "svod.settings.\(k)") == nil ? def : ud.bool(forKey: "svod.settings.\(k)") }
        func i(_ k: String, _ def: Int) -> Int { ud.object(forKey: "svod.settings.\(k)") == nil ? def : ud.integer(forKey: "svod.settings.\(k)") }
        func dbl(_ k: String, _ def: Double) -> Double { ud.object(forKey: "svod.settings.\(k)") == nil ? def : ud.double(forKey: "svod.settings.\(k)") }
        func s(_ k: String, _ def: String) -> String { ud.string(forKey: "svod.settings.\(k)") ?? def }

        endpointHost = s("endpointHost", "127.0.0.1")
        endpointPort = i("endpointPort", 7517)
        autoStartEngine = b("autoStartEngine", true)
        autoReconnect = b("autoReconnect", true)

        themeMode = ThemeMode(rawValue: s("themeMode", "dark")) ?? .dark
        readingMeasure = dbl("readingMeasure", Double(Spacing.readingMeasure))
        editorFontSize = dbl("editorFontSize", 14)
        density = Density(rawValue: s("density", "comfortable")) ?? .comfortable

        autosave = b("autosave", false)
        autosaveDebounceMs = i("autosaveDebounceMs", 1200)
        focusByDefault = b("focusByDefault", false)
        wikilinkAutocomplete = b("wikilinkAutocomplete", true)
        frontmatterTemplate = s("frontmatterTemplate", "---\ntitle: \ntags: []\n---\n\n")

        defaultSearchMode = SearchMode(rawValue: s("defaultSearchMode", "hybrid")) ?? .hybrid
        searchResultLimit = i("searchResultLimit", 20)
        rememberQuery = b("rememberQuery", false)

        showAgentActivity = b("showAgentActivity", true)
        showCommits = b("showCommits", true)
        showFileChanges = b("showFileChanges", true)
        showConflicts = b("showConflicts", true)
        feedCap = i("feedCap", 200)
        feedAnimation = b("feedAnimation", true)

        defaultGraphScopeLocal = b("defaultGraphScopeLocal", false)
        graphPhysicsIntensity = dbl("graphPhysicsIntensity", 1.0)

        reopenLastNote = b("reopenLastNote", true)
        lastOpenedPath = d.string(forKey: "svod.settings.lastOpenedPath")
    }

    /// Endpoint as a URL, derived from host + port. Loopback assumption preserved.
    public var baseURL: URL {
        URL(string: "http://\(endpointHost):\(endpointPort)") ?? URL(string: "http://127.0.0.1:7517")!
    }

    /// Whether a live activity event type should be shown, per the feed filters.
    public func showsEvent(_ type: EventType) -> Bool {
        switch type {
        case .agentActivity: showAgentActivity
        case .commitCreated: showCommits
        case .fileChanged:   showFileChanges
        case .conflict:      showConflicts
        default:             false
        }
    }

    /// Validate a host:port before applying. Returns an error message or nil.
    public static func validate(host: String, port: Int) -> String? {
        let h = host.trimmingCharacters(in: .whitespaces)
        if h.isEmpty { return "Host can't be empty." }
        if port < 1 || port > 65535 { return "Port must be 1–65535." }
        return nil
    }
}
