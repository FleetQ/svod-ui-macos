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
            Divider().overlay(ThemeColor.separator)

            if model.communitiesLoading && model.communities.isEmpty {
                LoadingStateView("Разчитане на темите…")
            } else if model.communities.isEmpty {
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
            if model.communitiesStale {
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
                ForEach(model.communities) { community in
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
