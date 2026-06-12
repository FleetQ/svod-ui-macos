import SwiftUI

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 3 — Graph View (Features/Graph/)
// ════════════════════════════════════════════════════════════════════════
//
// Holds the live layout + view transform for one rendered graph, and drives the
// redraw loop. It is deliberately separate from GraphModel (which owns the data
// contract): GraphScene is throwaway per-graph render state, rebuilt whenever the
// scoped graph changes, and never touches the network.
//
// The redraw loop is a single ticking `Timer`-free CADisplayLink-style cadence
// approximated by a Task that yields each frame; SwiftUI redraws because `tick`
// is @Published. We freeze (stop ticking) once kinetic energy settles, and never
// start ticking at all under Reduce Motion (the layout is pre-settled instead).

@MainActor
final class GraphScene: ObservableObject {

    // Rendered state — read by the Canvas.
    private(set) var layout: GraphLayout
    let graph: Graph
    /// Unresolved targets get a synthetic position orbiting their source so they
    /// render as distinct leaf pins without joining the physics.
    private(set) var unresolvedPoints: [UnresolvedPin]

    struct UnresolvedPin: Identifiable {
        let id: String          // "<target>\u{0001}<edgeIndex>" — unique per edge
        let source: String      // resolved source node id
        /// The raw [[wikilink]] target, suffix stripped.
        var displayTarget: String { String(id.prefix { $0 != "\u{0001}" }) }
        var label: String {
            (displayTarget as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
        }
    }

    // View transform.
    @Published var zoom: CGFloat = 1
    @Published var pan: CGSize = .zero

    // Frame counter — bumping this is what asks SwiftUI to redraw the Canvas.
    @Published private(set) var tick: UInt64 = 0
    @Published private(set) var isSettled = false

    private var loopTask: Task<Void, Never>?
    private let reduceMotion: Bool

    init(graph: Graph, reduceMotion: Bool) {
        self.graph = graph
        self.reduceMotion = reduceMotion
        var layout = GraphLayout(graph: graph)
        // One pin per unresolved edge whose source is a real node. The id carries
        // a per-edge suffix (after U+0001) so duplicate targets stay distinct;
        // `displayTarget` strips it for the label.
        self.unresolvedPoints = graph.unresolved.enumerated().compactMap { idx, e in
            guard layout.indexOf(e.source) != nil else { return nil }
            return UnresolvedPin(id: "\(e.target)\u{0001}\(idx)", source: e.source)
        }
        if reduceMotion {
            layout.settle()              // static, pre-settled layout
            self.isSettled = true
        }
        self.layout = layout
    }

    deinit { loopTask?.cancel() }

    var nodeCount: Int { layout.count }

    /// Degree-scaled radius for a node, in layout space (pre-zoom).
    func radius(at i: Int) -> CGFloat {
        let d = CGFloat(layout.degree[i])
        return 5 + min(10, d * 1.6)
    }

    /// World position of an unresolved pin: offset from its source along a stable
    /// per-target angle so siblings fan out instead of stacking.
    func position(of pin: UnresolvedPin) -> CGPoint? {
        guard let s = layout.position(of: pin.source) else { return nil }
        var hash: UInt64 = 1469598103934665603
        for b in pin.id.utf8 { hash = (hash ^ UInt64(b)) &* 1099511628211 }
        let angle = CGFloat(hash % 360) * .pi / 180
        return CGPoint(x: s.x + cos(angle) * 64, y: s.y + sin(angle) * 64)
    }

    // MARK: redraw loop
    func start() {
        guard !reduceMotion, loopTask == nil else { return }
        isSettled = false
        loopTask = Task { [weak self] in
            var settledFrames = 0
            while let self, !Task.isCancelled {
                let energy = self.layout.step()
                self.tick &+= 1
                if energy < 0.6 { settledFrames += 1 } else { settledFrames = 0 }
                if settledFrames > 24 {            // ~0.4s calm → freeze
                    self.isSettled = true
                    break
                }
                try? await Task.sleep(nanoseconds: 16_000_000)   // ~60fps
            }
        }
    }

    func stop() { loopTask?.cancel(); loopTask = nil }

    /// Re-energize and resume ticking (e.g. after the user drags a node or pans
    /// into a stale layout). No-op under Reduce Motion.
    func nudge() {
        guard !reduceMotion else { return }
        if loopTask == nil { start() }
    }

    func magnify(by factor: CGFloat) {
        zoom = min(3, max(0.3, zoom * factor))
    }

    func panBy(_ t: CGSize) {
        pan = CGSize(width: pan.width + t.width, height: pan.height + t.height)
    }

    func resetView() {
        withAnimation(Motion.standard) { zoom = 1; pan = .zero }
    }
}
