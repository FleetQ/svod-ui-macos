import SwiftUI

/// The "Теми" pane: the vault's thematic communities, as computed by the engine's derived graph.
///
/// **Selecting a theme filters the notes tree to its members** — that is the whole point of the
/// selection, and it replaced two earlier dead ends: a wall of hundreds of head-truncated paths in
/// this pane, and scoping the graph canvas, which showed almost nothing because the canvas draws
/// WIKILINKS while themes are formed mostly from embedding similarity (the 300-note "Documentation
/// and Policies" theme had zero wikilink edges among its members).
///
/// So: the pane is the map, the notes tree is where you walk. The canvas is now independent of it.
///
/// Rendering rules worth keeping:
///  - a community with `summary == nil` is normal, not an error (the engine may have built the graph
///    with no summary provider); it simply shows its machine-derived title;
///  - `stale` is a badge, never a reason to hide data — the engine still serves a stale graph on
///    purpose, and hiding it would be worse than showing it labelled.
struct GraphCommunitiesPane: View {
    @ObservedObject var model: GraphModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            levelPicker
            Divider().overlay(ThemeColor.separator)
            staleBanner

            if model.communitiesLoading && model.communities.isEmpty {
                LoadingStateView("Разчитане на темите…")
            } else if model.visibleCommunities.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(width: 260)
        .background(ThemeColor.surface)
    }

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            Text("ТЕМИ")
                .font(Typography.caption)
                .foregroundStyle(ThemeColor.textTertiary)
            // The badge is the FALLBACK now: it stays for engines that cannot count what changed
            // (older than contract 0.26.0, or incremental attachment off). When the engine can count,
            // the banner below says how much and offers to fix it — a badge alone tells the operator
            // something is wrong and nothing about what to do.
            if model.communitiesStale && model.newSinceBuild == nil {
                Text("остаряло")
                    .font(Typography.caption)
                    .padding(.horizontal, Spacing.xs)
                    .padding(.vertical, Spacing.xxs)
                    .background(ThemeColor.conflictSubtle, in: RoundedRectangle(cornerRadius: Radii.sm))
                    .foregroundStyle(ThemeColor.conflict)
                    .help("Хранилището се е променило след последния строеж. Резултатите още се показват.")
            }
            Spacer()
            if model.selectedCommunityID != nil {
                Button {
                    withAnimation(Motion.standard) { model.selectedCommunityID = nil }
                    Task { await model.selectCommunity(nil) }
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .help("Изчисти избора и покажи целия граф")
            }
            Button {
                Task { await model.rebuildCommunities() }
            } label: {
                if model.communitiesLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .disabled(model.communitiesLoading)
            .help("Построй темите наново")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    /// Picks which level of the hierarchy the pane lists.
    ///
    /// Only shown when the graph actually has more than one level. The coarsest level is the least
    /// precise: measured on the real vault its median theme holds 44 notes and the largest holds 320,
    /// while one level down the median is 7 — small enough to mean something. The API supported
    /// `level` from the start; the pane simply never offered it.
    @ViewBuilder
    private var levelPicker: some View {
        if model.levelCount > 1 {
            HStack(spacing: Spacing.xs) {
                Text("ПОДРОБНОСТ")
                    .font(Typography.caption2)
                    .foregroundStyle(ThemeColor.textTertiary)
                Picker("Ниво", selection: levelBinding) {
                    Text("Едро").tag(model.levelCount - 1)
                    ForEach(Array(0..<(model.levelCount - 1)).reversed(), id: \.self) { l in
                        Text(l == 0 ? "Ситно" : "Ниво \(l)").tag(l)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .disabled(model.communitiesLoading)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.bottom, Spacing.sm)
        }
    }

    /// nil means "the engine's default", which is the coarsest level — surfaced as that index so the
    /// menu always shows what is actually on screen rather than an empty selection.
    private var levelBinding: Binding<Int> {
        Binding(
            get: { model.level ?? max(model.levelCount - 1, 0) },
            set: { next in Task { await model.showLevel(next) } }
        )
    }

    /// Says how many notes arrived since the last full build, and offers the rebuild that folds them in.
    ///
    /// Shown only when the engine actually counted (contract 0.26.0 with incremental attachment on).
    /// A reported **0** is a real answer — nothing is missing — so the banner disappears rather than
    /// showing a reassuring zero.
    @ViewBuilder
    private var staleBanner: some View {
        if let new = model.newSinceBuild, new > 0 {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(Typography.caption)
                        .foregroundStyle(ThemeColor.textTertiary)
                    Text(new == 1 ? "1 нова бележка след строежа" : "\(new) нови бележки след строежа")
                        .font(Typography.caption)
                        .foregroundStyle(ThemeColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The two halves are materially different: attached notes ARE findable through the
                // themes, the pending ones are on no theme at all. Only the second is a reason to
                // rebuild now.
                if model.pendingNotes > 0 {
                    Text(
                        model.pendingNotes == 1
                            ? "1 от тях още не е в никоя тема"
                            : "\(model.pendingNotes) от тях още не са в никоя тема"
                    )
                    .font(Typography.caption2)
                    .foregroundStyle(ThemeColor.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                // Drift is the OTHER half of "is a rebuild worth it": attached notes are on the map,
                // but a high share of them would now be filed elsewhere. Shown only above a
                // threshold, because a couple of percent is noise the operator cannot act on.
                if let drift = model.driftRatio, drift >= 0.2 {
                    Text("≈\(Int((drift * 100).rounded()))% от закачените вече не пасват на темата си")
                        .font(Typography.caption2)
                        .foregroundStyle(ThemeColor.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help("Оценка по извадка. Пълният строеж прегрупира всичко наново.")
                }
                Button("Построй наново") {
                    Task { await model.rebuildCommunities() }
                }
                .buttonStyle(.link)
                .font(Typography.caption)
                .disabled(model.communitiesLoading)
                .help("Пълният строеж прегрупира темите и написва обобщенията наново — отнема минути.")
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ThemeColor.conflictSubtle)
            .accessibilityElement(children: .combine)
            Divider().overlay(ThemeColor.separator)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(model.communitiesState == "BUILDING" ? "Строи се…" : "Няма построени теми")
                .font(Typography.body)
                .foregroundStyle(ThemeColor.textSecondary)
            if model.communitiesState != "BUILDING" {
                Text("Темите се извеждат от връзките между бележките и от близостта им по смисъл.")
                    .font(Typography.caption)
                    .foregroundStyle(ThemeColor.textTertiary)
            }
            Spacer()
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(model.visibleCommunities) { community in
                    communityRow(community)
                }
            }
            .padding(Spacing.sm)
        }
    }

    /// Filename first, folder as secondary — a head-truncated full path reads as noise.
    private func memberRow(_ path: String) -> some View {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let folder = path.contains("/") ? String(path[path.startIndex..<path.lastIndex(of: "/")!]) : ""
        return Button {
            app.selectedPath = path
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(name.hasSuffix(".md") ? String(name.dropLast(3)) : name)
                    .font(Typography.caption)
                    .foregroundStyle(app.selectedPath == path ? ThemeColor.accent : ThemeColor.textSecondary)
                    .lineLimit(1)
                if !folder.isEmpty {
                    Text(folder)
                        .font(Typography.caption2)
                        .foregroundStyle(ThemeColor.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .help(path)
    }

    /// How many member paths the pane previews before deferring to the notes tree.
    private let MEMBER_PREVIEW = 8

    @ViewBuilder
    private func communityRow(_ community: GraphCommunity) -> some View {
        let isSelected = model.selectedCommunityID == community.id

        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Text(community.title)
                    .font(Typography.headline)
                    .foregroundStyle(ThemeColor.textPrimary)
                    .lineLimit(2)
                Spacer(minLength: Spacing.xs)
                // Notes attached after the summary was written. Shown because the summary below is
                // deliberately NOT regenerated for them — without this the count and the description
                // would quietly disagree.
                if let grown = community.addedSinceSummary, grown > 0 {
                    Text("+\(grown)")
                        .font(Typography.caption2)
                        .foregroundStyle(ThemeColor.textTertiary)
                        .monospacedDigit()
                        .help("\(grown) нови бележки след обобщението — то не ги описва.")
                }
                Text("\(community.size)")
                    .font(Typography.caption)
                    .foregroundStyle(ThemeColor.textTertiary)
                    .monospacedDigit()
            }

            if let summary = community.summary {
                Text(summary)
                    .font(Typography.caption)
                    .foregroundStyle(ThemeColor.textSecondary)
                    .lineLimit(isSelected ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isSelected {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    // A preview, not the membership: selecting a theme filters the notes tree, which
                    // is where you actually browse it. Listing hundreds of head-truncated paths here
                    // was unreadable and led nowhere.
                    ForEach(community.members.prefix(MEMBER_PREVIEW), id: \.self) { path in
                        memberRow(path)
                    }
                    if community.size > community.members.count || community.size > MEMBER_PREVIEW {
                        Text("и още \(community.size - min(community.members.count, MEMBER_PREVIEW)) — вижте ги в списъка с бележки вляво")
                            .font(Typography.caption2)
                            .foregroundStyle(ThemeColor.textTertiary)
                            .padding(.top, Spacing.xxs)
                    }
                }
                .padding(.top, Spacing.xxs)
            }
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radii.md)
                .fill(isSelected ? ThemeColor.surfaceSelected : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            let next = isSelected ? nil : community.id
            withAnimation(Motion.standard) { model.selectedCommunityID = next }
            Task { await model.selectCommunity(next) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(community.title), \(community.size) бележки")
    }
}
