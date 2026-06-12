import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 3 — Graph View (Features/Graph/)
// ════════════════════════════════════════════════════════════════════════
//
// The wikilink graph pane. Loads via GraphModel, renders a force-directed layout
// in a single `Canvas` (edges then nodes, labels on hover/zoom), and supports
// pan, zoom, hover-to-highlight a node's neighborhood, click-to-open, a
// Global/Local scope toggle, keyboard node cycling, and VoiceOver per-node labels.
//
// Rendering is Canvas-only (no per-node SwiftUI views) so node count scales; the
// physics runs in GraphScene's redraw loop and freezes when it settles. Reduce
// Motion pre-settles the layout and never animates.

struct GraphView: View {
    @ObservedObject var model: GraphModel
    @EnvironmentObject var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ThemeColor.background.ignoresSafeArea()

            if model.isLoading && model.graph == nil {
                LoadingStateView("Building graph…")
            } else if let error = model.errorMessage {
                ErrorStateView(message: error) { Task { await model.load() } }
            } else if let scoped = model.scopedGraph(), !scoped.nodes.isEmpty {
                GraphCanvasContainer(model: model, graph: scoped, reduceMotion: reduceMotion)
                    // Recreate the scene when the rendered topology changes.
                    .id(sceneIdentity(scoped))
            } else {
                EmptyStateView(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: model.scope == .local ? "No links here" : "No graph yet",
                    message: model.scope == .local
                        ? "This note has no resolved links to neighboring notes."
                        : "Notes you link together with [[wikilinks]] will appear here.")
            }

            VStack {
                scopeBar
                Spacer()
            }
            .padding(Spacing.md)
        }
        .task { if model.graph == nil { await model.load() } }
    }

    // MARK: scope toggle
    private var scopeBar: some View {
        HStack {
            Picker("Scope", selection: $model.scope) {
                Text("Global").tag(GraphModel.Scope.global)
                Text("Local").tag(GraphModel.Scope.local)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 180)
            .help("Show the whole vault, or just the open note's neighborhood.")
            Spacer()
        }
    }

    /// Topology-only identity: rebuild the scene when nodes/edges change, but not
    /// when only hover state moves.
    private func sceneIdentity(_ g: Graph) -> Int {
        var hasher = Hasher()
        hasher.combine(model.scope)
        hasher.combine(reduceMotion)
        for n in g.nodes { hasher.combine(n.id) }
        hasher.combine(g.edges.count)
        hasher.combine(g.unresolved.count)
        return hasher.finalize()
    }
}

// MARK: - Canvas container (owns a GraphScene for one topology)
private struct GraphCanvasContainer: View {
    @ObservedObject var model: GraphModel
    @StateObject private var scene: GraphScene
    @EnvironmentObject var app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Index of the keyboard-focused node (drives the focus ring + ⏎ open).
    @State private var keyboardFocus: Int = 0
    @FocusState private var canvasFocused: Bool

    init(model: GraphModel, graph: Graph, reduceMotion: Bool) {
        self.model = model
        _scene = StateObject(wrappedValue: GraphScene(graph: graph, reduceMotion: reduceMotion))
    }

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2 + scene.pan.width,
                                 y: geo.size.height / 2 + scene.pan.height)

            Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
                _ = scene.tick   // redraw dependency
                draw(ctx, size: size, center: center)
            }
            .contentShape(Rectangle())
            .gesture(panGesture)
            .gesture(magnifyGesture)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): updateHover(at: p, center: center)
                case .ended: model.hoveredNodeID = nil
                }
            }
            .onTapGesture { p in handleTap(at: p, center: center) }
            // Keyboard: ←/→ cycle nodes, ⏎ opens the focused node.
            .focusable()
            .focused($canvasFocused)
            .onMoveCommand { dir in moveFocus(dir) }
            .onKeyPress(.return) { openFocused(); return .handled }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilitySummary)
            .accessibilityValue(accessibilityFocusValue)
            .accessibilityAdjustableAction { cycle($0) }
            .accessibilityAction(named: "Open note") { openFocused() }
            .overlay(alignment: .bottomTrailing) { zoomControls }
            .onAppear { scene.start(); canvasFocused = true }
            .onDisappear { scene.stop() }
            // Re-center the local view whenever the open note changes.
            .onChange(of: app.selectedPath) { _, _ in if model.scope == .local { keyboardFocus = 0 } }
        }
    }

    // MARK: drawing — edges first (under), then nodes, then labels.
    private func draw(_ ctx: GraphicsContext, size: CGSize, center: CGPoint) {
        let z = scene.zoom
        func screen(_ p: CGPoint) -> CGPoint { CGPoint(x: center.x + p.x * z, y: center.y + p.y * z) }

        let hovered = model.hoveredNodeID
        let neighbors = hovered.map { neighborhood(of: $0) }
        let dimmed = hovered != nil

        // Resolved edges.
        for e in scene.graph.edges {
            guard let a = scene.layout.position(of: e.source),
                  let b = scene.layout.position(of: e.target) else { continue }
            let lit = neighbors?.contains(e.source) == true && neighbors?.contains(e.target) == true
            var path = Path()
            path.move(to: screen(a)); path.addLine(to: screen(b))
            let color = lit ? ThemeColor.borderStrong : ThemeColor.separator
            ctx.stroke(path, with: .color(color.opacity(dimmed && !lit ? 0.35 : 1)), lineWidth: lit ? 1.4 : 0.8)
        }

        // Unresolved edges + leaf pins — distinct dashed link in linkUnresolved.
        for pin in scene.unresolvedPoints {
            guard let s = scene.layout.position(of: pin.source),
                  let p = scene.position(of: pin) else { continue }
            let lit = neighbors?.contains(pin.source) == true
            var path = Path()
            path.move(to: screen(s)); path.addLine(to: screen(p))
            ctx.stroke(path, with: .color(ThemeColor.linkUnresolved.opacity(dimmed && !lit ? 0.3 : 0.7)),
                       style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
            let r: CGFloat = 4 * z
            let rect = CGRect(x: screen(p).x - r, y: screen(p).y - r, width: r * 2, height: r * 2)
            ctx.stroke(Circle().path(in: rect),
                       with: .color(ThemeColor.linkUnresolved.opacity(dimmed && !lit ? 0.4 : 0.95)), lineWidth: 1.2)
            if z > 1.3 || lit { drawLabel(ctx, pin.label, at: screen(p), z: z, color: ThemeColor.linkUnresolved, dim: dimmed && !lit) }
        }

        // Nodes.
        for i in 0..<scene.nodeCount {
            let id = scene.layout.ids[i]
            let pos = CGPoint(x: scene.layout.px[i], y: scene.layout.py[i])
            let r = scene.radius(at: i) * z
            let sp = screen(pos)
            let rect = CGRect(x: sp.x - r, y: sp.y - r, width: r * 2, height: r * 2)

            let isFocus = id == model.focusPath
            let isHovered = id == hovered
            let isNeighbor = neighbors?.contains(id) == true
            let lit = !dimmed || isNeighbor
            let fill: Color = isFocus ? ThemeColor.accent
                : (lit ? ThemeColor.accentMuted : ThemeColor.textTertiary)
            ctx.fill(Circle().path(in: rect), with: .color(fill.opacity(lit ? 1 : 0.4)))

            if isHovered || (i == keyboardFocus && canvasFocused) {
                let ring = rect.insetBy(dx: -3, dy: -3)
                ctx.stroke(Circle().path(in: ring), with: .color(ThemeColor.accent), lineWidth: 1.5)
            } else if isFocus {
                let ring = rect.insetBy(dx: -2, dy: -2)
                ctx.stroke(Circle().path(in: ring), with: .color(ThemeColor.accent.opacity(0.5)), lineWidth: 1)
            }

            // Labels: on hover/neighborhood, on the focus note, or when zoomed in.
            if isHovered || isNeighbor || isFocus || z > 1.4 {
                drawLabel(ctx, Self.label(for: id), at: CGPoint(x: sp.x, y: sp.y + r + 8),
                          z: z, color: lit ? ThemeColor.textSecondary : ThemeColor.textTertiary, dim: !lit)
            }
        }
    }

    private func drawLabel(_ ctx: GraphicsContext, _ text: String, at p: CGPoint, z: CGFloat, color: Color, dim: Bool) {
        let resolved = ctx.resolve(
            Text(text).font(Typography.caption).foregroundStyle(color.opacity(dim ? 0.5 : 1)))
        ctx.draw(resolved, at: p, anchor: .top)
    }

    // MARK: hit-testing & interaction
    /// Nearest node within its radius of the screen point, else nil.
    private func nodeHit(at p: CGPoint, center: CGPoint) -> Int? {
        let z = scene.zoom
        var best: Int? = nil
        var bestD: CGFloat = .greatestFiniteMagnitude
        for i in 0..<scene.nodeCount {
            let sx = center.x + scene.layout.px[i] * z
            let sy = center.y + scene.layout.py[i] * z
            let r = scene.radius(at: i) * z + 4
            let dx = p.x - sx, dy = p.y - sy
            let d2 = dx * dx + dy * dy
            if d2 <= r * r && d2 < bestD { bestD = d2; best = i }
        }
        return best
    }

    private func updateHover(at p: CGPoint, center: CGPoint) {
        let id = nodeHit(at: p, center: center).map { scene.layout.ids[$0] }
        if id != model.hoveredNodeID { model.hoveredNodeID = id }
    }

    private func handleTap(at p: CGPoint, center: CGPoint) {
        canvasFocused = true
        if let i = nodeHit(at: p, center: center) {
            keyboardFocus = i
            app.open(path: scene.layout.ids[i])
        }
    }

    private func openFocused() {
        guard scene.nodeCount > 0 else { return }
        app.open(path: scene.layout.ids[min(keyboardFocus, scene.nodeCount - 1)])
    }

    private func moveFocus(_ dir: MoveCommandDirection) {
        switch dir {
        case .right, .down: cycle(.increment)
        case .left, .up: cycle(.decrement)
        @unknown default: break
        }
    }

    private func cycle(_ d: AccessibilityAdjustmentDirection) {
        guard scene.nodeCount > 0 else { return }
        switch d {
        case .increment: keyboardFocus = (keyboardFocus + 1) % scene.nodeCount
        case .decrement: keyboardFocus = (keyboardFocus - 1 + scene.nodeCount) % scene.nodeCount
        @unknown default: break
        }
        model.hoveredNodeID = scene.layout.ids[keyboardFocus]
    }

    // MARK: gestures
    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { v in scene.panBy(CGSize(width: v.translation.width - lastPan.width,
                                                 height: v.translation.height - lastPan.height))
                lastPan = v.translation }
            .onEnded { _ in lastPan = .zero }
    }
    @State private var lastPan: CGSize = .zero

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let f = v.magnification / lastMag
                scene.magnify(by: f)
                lastMag = v.magnification
            }
            .onEnded { _ in lastMag = 1 }
    }
    @State private var lastMag: CGFloat = 1

    // MARK: zoom chrome
    private var zoomControls: some View {
        HStack(spacing: Spacing.xs) {
            Button { scene.magnify(by: 0.8) } label: { Image(systemName: "minus") }
            Button { scene.resetView() } label: { Image(systemName: "scope") }
            Button { scene.magnify(by: 1.25) } label: { Image(systemName: "plus") }
        }
        .buttonStyle(.plain)
        .font(Typography.caption)
        .foregroundStyle(ThemeColor.textSecondary)
        .padding(Spacing.xs)
        .background(ThemeColor.surfaceRaised, in: RoundedRectangle(cornerRadius: Radii.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radii.sm, style: .continuous).strokeBorder(ThemeColor.borderSubtle))
        .padding(Spacing.md)
    }

    // MARK: neighborhood
    /// Node id + all ids one hop away (resolved edges only).
    private func neighborhood(of id: String) -> Set<String> {
        var set: Set<String> = [id]
        for e in scene.graph.edges {
            if e.source == id { set.insert(e.target) }
            if e.target == id { set.insert(e.source) }
        }
        return set
    }

    private func degree(of id: String) -> Int {
        scene.layout.indexOf(id).map { scene.layout.degree[$0] } ?? 0
    }

    // MARK: labels & a11y
    static func label(for id: String) -> String {
        (id as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
    }

    private var accessibilitySummary: String {
        "Link graph, \(scene.nodeCount) notes. Swipe up or down to move between notes."
    }

    private var accessibilityFocusValue: String {
        guard scene.nodeCount > 0 else { return "Empty" }
        let id = scene.layout.ids[min(keyboardFocus, scene.nodeCount - 1)]
        let n = degree(of: id)
        return "Note \(Self.label(for: id)), \(n) link\(n == 1 ? "" : "s")"
    }
}

// MARK: - Previews
#Preview("Global") {
    let app = AppModel(client: MockSvodClient.preview)
    return GraphView(model: app.graph)
        .environmentObject(app)
        .frame(width: 720, height: 560)
        .preferredColorScheme(.dark)
}

#Preview("Local") {
    let app = AppModel(client: MockSvodClient.preview)
    app.selectedPath = "vault/architecture.md"
    app.graph.scope = .local
    return GraphView(model: app.graph)
        .environmentObject(app)
        .frame(width: 720, height: 560)
        .preferredColorScheme(.dark)
}

#Preview("Empty") {
    let app = AppModel(client: MockSvodClient.empty)
    return GraphView(model: app.graph)
        .environmentObject(app)
        .frame(width: 720, height: 560)
        .preferredColorScheme(.dark)
}

#Preview("Loading") {
    let app = AppModel(client: MockSvodClient(behavior: .slow))
    return GraphView(model: app.graph)
        .environmentObject(app)
        .frame(width: 720, height: 560)
        .preferredColorScheme(.dark)
}
