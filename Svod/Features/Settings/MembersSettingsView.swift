import SwiftUI
import AppKit

// Members — the people who may reach the ACTIVE vault's engine with a personal key
// (engine ≥ contract 0.30.0, ADR-0019). An admin adds a person, picks a role per vault
// (reader / editor), and hands over the key the engine generated — shown exactly once.
// Rotate and revoke take effect on the person's next request; no restart. A non-admin sees
// who they are and what they may do. Degrades to a calm note on engines before 0.30.0.

@MainActor
public final class MembersModel: ObservableObject {
    @Published public private(set) var me: Me?
    @Published public private(set) var users: [UserInfo] = []
    @Published public private(set) var unavailable = false
    @Published public private(set) var busy = false
    @Published public var statusMsg: String?
    /// The one-time key to show. Set by create/rotate, cleared when the sheet is dismissed —
    /// never kept anywhere else in the app.
    @Published public var revealedKey: RevealedKey?

    public struct RevealedKey: Identifiable, Equatable {
        public let userId: String
        public let name: String
        public let key: String
        public let rotated: Bool
        public var id: String { userId + key }
    }

    private let client: SvodClient
    public init(client: SvodClient) { self.client = client }

    public var isAdmin: Bool { me?.admin == true }

    /// "last seen 3 hours ago" / "never used". Engines before 0.31.0 send no lastUsedAt.
    public static func lastSeen(_ iso: String?, now: Date = Date()) -> String {
        guard let iso, let date = Self.isoParser.date(from: iso) ?? Self.isoParserNoFraction.date(from: iso) else { return "never used" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return "last seen " + f.localizedString(for: date, relativeTo: now)
    }
    private static let isoParser: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    private static let isoParserNoFraction: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f }()

    public func load() async {
        do {
            let who = try await client.me()
            me = who
            unavailable = false
            if who.admin {
                users = try await client.users().users.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            } else {
                users = []
            }
        } catch let e as SvodClientError where e.isNotImplemented || e.isNotFound {
            unavailable = true
        } catch let e as SvodClientError where e.isOffline {
            // keep the last good state
        } catch let e as SvodClientError {
            statusMsg = e.errorDescription
        } catch {
            statusMsg = error.localizedDescription
        }
    }

    public func create(_ req: CreateUserRequest) async {
        busy = true; defer { busy = false }
        statusMsg = nil
        do {
            let created = try await client.createUser(req)
            revealedKey = RevealedKey(userId: created.user.userId, name: created.user.name, key: created.key, rotated: false)
            await load()
        } catch let e as SvodClientError {
            statusMsg = Self.describe(e, fallback: "Couldn’t add the member.")
        } catch {
            statusMsg = error.localizedDescription
        }
    }

    public func update(id: String, _ req: UpdateUserRequest) async {
        busy = true; defer { busy = false }
        statusMsg = nil
        do {
            _ = try await client.updateUser(id: id, req)
            await load()
        } catch let e as SvodClientError {
            statusMsg = Self.describe(e, fallback: "Couldn’t update the member.")
        } catch {
            statusMsg = error.localizedDescription
        }
    }

    public func rotate(_ user: UserInfo) async {
        busy = true; defer { busy = false }
        statusMsg = nil
        do {
            let r = try await client.rotateUserKey(id: user.userId)
            revealedKey = RevealedKey(userId: user.userId, name: user.name, key: r.key, rotated: true)
        } catch let e as SvodClientError {
            statusMsg = Self.describe(e, fallback: "Couldn’t rotate the key.")
        } catch {
            statusMsg = error.localizedDescription
        }
    }

    public func revoke(_ user: UserInfo) async {
        busy = true; defer { busy = false }
        statusMsg = nil
        do {
            try await client.deleteUser(id: user.userId)
            statusMsg = "\(user.name) no longer has access."
            await load()
        } catch let e as SvodClientError {
            statusMsg = Self.describe(e, fallback: "Couldn’t revoke access.")
        } catch {
            statusMsg = error.localizedDescription
        }
    }

    private static func describe(_ e: SvodClientError, fallback: String) -> String {
        switch e {
        case .http(409, _): return "That member id is already taken."
        case .http(403, _): return "Only an engine admin can manage members."
        case .http(401, _): return "Your key was not accepted by this engine."
        default: return e.errorDescription ?? fallback
        }
    }
}

struct MembersSettingsView: View {
    @EnvironmentObject var app: AppModel

    /// The engine behind the ACTIVE vault is the one whose members we manage.
    private var engineLabel: String { app.vault.activeVault?.engineName ?? "this Mac" }

    var body: some View {
        MembersBody(model: MembersModel(client: app.client), engineLabel: engineLabel,
                    vaults: app.vault.vaults.filter { $0.engineId == app.vault.activeVault?.engineId })
            .id(app.vault.activeVault?.engineId ?? "local")
    }
}

/// Split out so the model is created against the live client once per engine (`.id(engineId)`).
private struct MembersBody: View {
    @StateObject var model: MembersModel
    let engineLabel: String
    let vaults: [Vault]
    @State private var editing: MemberDraft?
    @State private var pendingRevoke: UserInfo?

    var body: some View {
        Form {
            if model.unavailable {
                Section {
                    Label("Members need a newer Svod engine.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text("Update the engine to contract 0.30.0+ to give people personal keys and per-vault roles.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                whoAmI
                if model.isAdmin { members }
            }
            if let msg = model.statusMsg {
                Section { Text(msg).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
        .sheet(item: $editing) { draft in
            MemberEditSheet(draft: draft, vaults: vaults) { result in
                editing = nil
                guard let result else { return }
                Task {
                    if let id = result.existingId {
                        await model.update(id: id, UpdateUserRequest(name: result.name, email: result.email, admin: result.admin, grants: result.grants))
                    } else {
                        await model.create(CreateUserRequest(userId: result.userId, name: result.name, email: result.email, admin: result.admin, grants: result.grants))
                    }
                }
            }
        }
        .sheet(item: $model.revealedKey) { reveal in
            KeyRevealSheet(reveal: reveal) { model.revealedKey = nil }
        }
        .confirmationDialog("Revoke access?",
                            isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
                            presenting: pendingRevoke) { user in
            Button("Revoke \(user.name)", role: .destructive) { Task { await model.revoke(user) } }
            Button("Cancel", role: .cancel) { pendingRevoke = nil }
        } message: { user in
            Text("“\(user.name)” loses access on their next request. Their key is deleted from the engine.")
        }
    }

    @ViewBuilder private var whoAmI: some View {
        Section("You on \(engineLabel)") {
            if let me = model.me {
                LabeledContent("Signed in as") {
                    HStack(spacing: Spacing.xs) {
                        Text(me.name)
                        if me.local { StatusPill("local", tone: .neutral) }
                        else if me.admin { StatusPill("admin", tone: .accent) }
                    }
                }
                if !me.local && !me.admin {
                    if me.grants.isEmpty {
                        Text("No vault grants yet — ask an admin.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(me.grants) { g in
                        LabeledContent(g.vault) { StatusPill(g.role, tone: g.role == "editor" ? .accent : .neutral) }
                    }
                }
            } else {
                Text("Loading…").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var members: some View {
        Section("Members") {
            if model.users.isEmpty {
                Text("Nobody has a personal key yet. Add a member to hand them one.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.users) { u in
                HStack(spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Spacing.xs) {
                            Text(u.name).font(.body)
                            Text(u.userId).font(Typography.caption).foregroundStyle(.secondary)
                            if u.admin { StatusPill("admin", tone: .accent) }
                            // A key that has gone quiet is the one to revoke; "never" is a key that was handed over but not used.
                            Text(MembersModel.lastSeen(u.lastUsedAt))
                                .font(Typography.caption2).foregroundStyle(.tertiary)
                                .help(u.lastUsedAt.map { "Key last used \($0)" } ?? "This key has never authenticated (or the engine predates 0.31.0)")
                        }
                        if u.grants.isEmpty && !u.admin {
                            Text("no vaults").font(Typography.caption2).foregroundStyle(.tertiary)
                        } else {
                            HStack(spacing: Spacing.xxs) {
                                ForEach(u.grants) { g in
                                    Text("\(g.vault) · \(g.role)")
                                        .font(Typography.caption2)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(ThemeColor.surfaceRaised, in: Capsule())
                                }
                            }
                        }
                    }
                    Spacer()
                    Menu {
                        Button("Edit…") { editing = .edit(u) }
                        Button("Rotate key…") { Task { await model.rotate(u) } }
                        Divider()
                        Button("Revoke…", role: .destructive) { pendingRevoke = u }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Edit, rotate key, or revoke")
                }
                .contentShape(Rectangle())
            }
        }
        Section {
            Button { editing = .new(vaults: vaults) } label: { Label("Add member…", systemImage: "person.badge.plus") }
                .disabled(model.busy)
            Text("The engine generates the key and shows it once. Send it to the person over a channel you trust; they enter it in Settings → Connection → Central engines.")
                .font(Typography.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Draft + sheets

struct MemberDraft: Identifiable {
    let id = UUID()
    var existingId: String?
    var userId: String = ""
    var name: String = ""
    var email: String = ""
    var admin: Bool = false
    /// vault id (as the ENGINE knows it) → role; absent ⇒ no access.
    var roles: [String: String] = [:]

    struct Result {
        let existingId: String?
        let userId: String
        let name: String
        let email: String?
        let admin: Bool
        let grants: [VaultGrant]
    }

    static func new(vaults: [Vault]) -> MemberDraft {
        var d = MemberDraft()
        // A sensible starting point: reader on every vault of this engine.
        for v in vaults { d.roles[MemberDraft.engineVaultId(v)] = "reader" }
        return d
    }

    static func edit(_ u: UserInfo) -> MemberDraft {
        var d = MemberDraft()
        d.existingId = u.userId; d.userId = u.userId; d.name = u.name; d.email = u.email ?? ""; d.admin = u.admin
        for g in u.grants { d.roles[g.vault] = g.role }
        return d
    }

    /// The vault id the ENGINE uses (a remote vault's app key carries the profile suffix).
    static func engineVaultId(_ v: Vault) -> String { VaultKey.parse(v.id).vaultId ?? v.id }

    /// "Мария Петрова" → "maria-petrova" (ASCII-folded, engine id pattern).
    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let latin = folded.applyingTransform(.toLatin, reverse: false) ?? folded
        let stripped = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
        let allowed = stripped.lowercased().map { c -> Character in
            ("a"..."z").contains(c) || ("0"..."9").contains(c) ? c : "-"
        }
        var s = String(allowed).replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "member" : s
    }

    func result() -> Result {
        Result(existingId: existingId,
               userId: existingId ?? (userId.isEmpty ? Self.slug(name) : userId),
               name: name.trimmingCharacters(in: .whitespaces),
               email: email.trimmingCharacters(in: .whitespaces).isEmpty ? nil : email.trimmingCharacters(in: .whitespaces),
               admin: admin,
               grants: roles.filter { $0.value != "none" }.map { VaultGrant(vault: $0.key, role: $0.value) }.sorted { $0.vault < $1.vault })
    }
}

private struct MemberEditSheet: View {
    @State var draft: MemberDraft
    let vaults: [Vault]
    let done: (MemberDraft.Result?) -> Void
    @State private var idEdited = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Text(draft.existingId == nil ? "Add member" : "Edit member").font(Typography.title)
            Form {
                TextField("Name", text: $draft.name)
                    .onChange(of: draft.name) { _, n in if draft.existingId == nil && !idEdited { draft.userId = MemberDraft.slug(n) } }
                TextField("Member id", text: $draft.userId)
                    .disabled(draft.existingId != nil)
                    .onChange(of: draft.userId) { _, _ in idEdited = true }
                    .font(Typography.code)
                TextField("Email (optional)", text: $draft.email)
                Toggle("Engine admin (manages members, agents, backup, vaults)", isOn: $draft.admin)
                Section("Vault access") {
                    if vaults.isEmpty {
                        Text("This engine has no vaults yet.").foregroundStyle(.secondary)
                    }
                    ForEach(vaults) { v in
                        let vid = MemberDraft.engineVaultId(v)
                        Picker(v.name, selection: Binding(
                            get: { draft.roles[vid] ?? "none" },
                            set: { draft.roles[vid] = $0 })) {
                            Text("No access").tag("none")
                            Text("Reader").tag("reader")
                            Text("Editor").tag("editor")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button(draft.existingId == nil ? "Add & create key" : "Save") { done(draft.result()) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty || draft.userId.isEmpty)
            }
        }
        .padding(Spacing.lg)
        .frame(width: 520)
    }
}

private struct KeyRevealSheet: View {
    let reveal: MembersModel.RevealedKey
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Label(reveal.rotated ? "New key for \(reveal.name)" : "\(reveal.name) can now sign in", systemImage: "key.fill")
                .font(Typography.title)
            Text("This key is shown once. Copy it now and send it to \(reveal.name) over a channel you trust. The engine keeps it hashed on disk; the app does not keep it at all.")
                .font(Typography.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Spacing.sm) {
                Text(reveal.key)
                    .font(Typography.code).textSelection(.enabled)
                    .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                    .background(ThemeColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radii.sm))
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(reveal.key, forType: .string)
                    copied = true
                }
            }
            Text("They enter it in Svod → Settings → Connection → Central engines, together with this engine’s address.")
                .font(Typography.caption).foregroundStyle(.tertiary)
            HStack { Spacer(); Button("Done") { done() }.keyboardShortcut(.defaultAction) }
        }
        .padding(Spacing.lg)
        .frame(width: 520)
    }
}

#Preview {
    MembersSettingsView()
        .environmentObject(AppModel(client: MockSvodClient.preview))
        .frame(width: 640, height: 520)
}
