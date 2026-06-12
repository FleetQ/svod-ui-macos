import CoreGraphics
import Foundation

// ════════════════════════════════════════════════════════════════════════
// OWNED BY TEAMMATE 3 — Graph View (Features/Graph/)
// ════════════════════════════════════════════════════════════════════════
//
// A small, allocation-free force-directed layout. Topology (nodes, edges,
// degree) is built once from a `Graph`; the per-frame integrator then mutates
// flat position/velocity arrays in place so the hot loop allocates nothing and
// stays cheap enough to run at ~60fps for the note-graph sizes we expect.
//
// Forces, all classic Fruchterman–Reingold-ish:
//   • repulsion  — every node pushes every other apart (O(n²); fine to a few
//                  hundred notes, capped iteration count keeps it bounded).
//   • springs    — edges pull their endpoints toward a rest length.
//   • centering  — a gentle pull to the origin so the graph doesn't drift away.
//   • damping    — velocity decays each step so motion settles instead of ringing.
//
// The sim reports its own kinetic energy; when it falls below a threshold the
// caller freezes the redraw loop (and Reduce Motion freezes it immediately,
// after pre-settling, so the layout is static).

struct GraphLayout {

    // Stable identity / metadata, indexed 0..<count. Parallel arrays (struct of
    // arrays) keep the integrator branch-free and cache-friendly.
    private(set) var ids: [String]
    private(set) var degree: [Int]
    private var index: [String: Int]

    // Mutable physics state — flat, reused every frame.
    var px: [CGFloat]
    var py: [CGFloat]
    private var vx: [CGFloat]
    private var vy: [CGFloat]

    // Edge endpoints as resolved integer indices (resolved targets only).
    private var edgeA: [Int]
    private var edgeB: [Int]

    var count: Int { ids.count }

    // MARK: tunables (in layout-space points, applied before view zoom)
    private let repulsion: CGFloat = 9_000     // node-node separation strength
    private let springK: CGFloat = 0.045       // edge stiffness
    private let restLength: CGFloat = 92       // preferred edge length
    private let centerK: CGFloat = 0.012       // pull toward origin
    private let damping: CGFloat = 0.86        // velocity retained per step
    private let maxStep: CGFloat = 28          // clamp per-step displacement

    /// Build topology from a graph. Only resolved edges (both endpoints are real
    /// nodes) participate in the physics; unresolved targets are laid out by the
    /// view relative to their single source, not simulated.
    init(graph: Graph) {
        let nodes = graph.nodes
        var ids = [String](); ids.reserveCapacity(nodes.count)
        var index = [String: Int](minimumCapacity: nodes.count)
        for (i, n) in nodes.enumerated() { ids.append(n.id); index[n.id] = i }

        var degree = [Int](repeating: 0, count: nodes.count)
        var edgeA = [Int](); var edgeB = [Int]()
        edgeA.reserveCapacity(graph.edges.count); edgeB.reserveCapacity(graph.edges.count)
        for e in graph.edges {
            guard let a = index[e.source], let b = index[e.target], a != b else { continue }
            edgeA.append(a); edgeB.append(b)
            degree[a] += 1; degree[b] += 1
        }

        self.ids = ids
        self.index = index
        self.degree = degree
        self.edgeA = edgeA
        self.edgeB = edgeB

        // Seed on a deterministic phyllotaxis spiral so successive launches and
        // previews look identical and the sim starts from a sane, spread layout.
        let golden = CGFloat.pi * (3 - (5 as CGFloat).squareRoot())
        var px = [CGFloat](repeating: 0, count: nodes.count)
        var py = [CGFloat](repeating: 0, count: nodes.count)
        for i in 0..<nodes.count {
            let r = 14 * (CGFloat(i) + 1).squareRoot()
            let a = CGFloat(i) * golden
            px[i] = r * cos(a)
            py[i] = r * sin(a)
        }
        self.px = px
        self.py = py
        self.vx = [CGFloat](repeating: 0, count: nodes.count)
        self.vy = [CGFloat](repeating: 0, count: nodes.count)
    }

    func position(of id: String) -> CGPoint? {
        guard let i = index[id] else { return nil }
        return CGPoint(x: px[i], y: py[i])
    }

    func indexOf(_ id: String) -> Int? { index[id] }

    /// Advance one integration step. Returns total kinetic energy so the caller
    /// can decide when the layout has settled. Allocation-free.
    @discardableResult
    mutating func step() -> CGFloat {
        let n = ids.count
        guard n > 0 else { return 0 }

        // Repulsion — O(n²). Symmetric, so accumulate both sides per pair.
        var i = 0
        while i < n {
            var fx: CGFloat = 0, fy: CGFloat = 0
            let xi = px[i], yi = py[i]
            var j = 0
            while j < n {
                if j != i {
                    var dx = xi - px[j]
                    var dy = yi - py[j]
                    var d2 = dx * dx + dy * dy
                    if d2 < 0.01 { dx = (CGFloat(i) - CGFloat(j)) * 0.1 + 0.01; dy = 0.01; d2 = 0.0002 }
                    let inv = repulsion / d2
                    let d = d2.squareRoot()
                    fx += dx / d * inv
                    fy += dy / d * inv
                }
                j += 1
            }
            vx[i] = (vx[i] + fx) * damping
            vy[i] = (vy[i] + fy) * damping
            i += 1
        }

        // Springs — pull edge endpoints toward rest length.
        var e = 0
        while e < edgeA.count {
            let a = edgeA[e], b = edgeB[e]
            let dx = px[b] - px[a]
            let dy = py[b] - py[a]
            let dist = max(0.01, (dx * dx + dy * dy).squareRoot())
            let f = springK * (dist - restLength)
            let ux = dx / dist, uy = dy / dist
            vx[a] += ux * f; vy[a] += uy * f
            vx[b] -= ux * f; vy[b] -= uy * f
            e += 1
        }

        // Centering + integrate, accumulating kinetic energy.
        var energy: CGFloat = 0
        i = 0
        while i < n {
            vx[i] -= px[i] * centerK
            vy[i] -= py[i] * centerK
            var sx = vx[i], sy = vy[i]
            if sx > maxStep { sx = maxStep } else if sx < -maxStep { sx = -maxStep }
            if sy > maxStep { sy = maxStep } else if sy < -maxStep { sy = -maxStep }
            px[i] += sx
            py[i] += sy
            energy += sx * sx + sy * sy
            i += 1
        }
        return energy
    }

    /// Run the sim forward without rendering — used to pre-settle a static layout
    /// (Reduce Motion) or to warm-start before the first frame.
    mutating func settle(maxIterations: Int = 320, energyFloor: CGFloat = 0.6) {
        for _ in 0..<maxIterations where step() > energyFloor {}
    }
}
