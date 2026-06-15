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

struct GraphLayout: Sendable {

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
    /// Number of leading nodes that participate in the physics (degree ≥ 1). Orphans
    /// (degree 0) are stored after these with static peripheral positions and are never
    /// simulated — they're the bulk of a real vault and would otherwise dominate the
    /// O(n²) cost and clutter the layout.
    private(set) var simulatedCount: Int = 0

    // MARK: tunables (in layout-space points, applied before view zoom)
    private let repulsion: CGFloat = 9_000     // node-node separation strength
    private let springK: CGFloat = 0.045       // edge stiffness
    private let restLength: CGFloat = 92       // preferred edge length
    private let centerK: CGFloat = 0.012       // pull toward origin
    private let damping: CGFloat = 0.86        // velocity retained per step
    private let maxStep: CGFloat = 28          // clamp per-step displacement

    // Global cooling (d3-style). Per-step displacement is scaled by `alpha`, which
    // decays geometrically toward `alphaMin`. This guarantees the sim settles even in
    // a large/dense graph where force-balance alone never reaches a low-energy rest
    // state (overlap impulses keep injecting motion). Re-heat on user interaction.
    let alphaMin: CGFloat = 0.004
    private let alphaDecay: CGFloat = 0.0225   // ~300 steps from 1 → alphaMin
    private(set) var alpha: CGFloat = 1
    mutating func reheat() { alpha = 1 }

    /// Build topology from a graph. Only resolved edges (both endpoints are real
    /// nodes) participate in the physics; unresolved targets are laid out by the
    /// view relative to their single source, not simulated.
    init(graph: Graph) {
        let nodes = graph.nodes
        // Pass 1 — tally degree in original order.
        var orig = [String: Int](minimumCapacity: nodes.count)
        for (i, n) in nodes.enumerated() { orig[n.id] = i }
        var deg0 = [Int](repeating: 0, count: nodes.count)
        for e in graph.edges {
            guard let a = orig[e.source], let b = orig[e.target], a != b else { continue }
            deg0[a] += 1; deg0[b] += 1
        }

        // Partition: connected nodes (degree ≥ 1) first, orphans (degree 0) last,
        // preserving original order within each group. Only the connected prefix is
        // simulated; orphans get a static halo.
        var order = [Int](); order.reserveCapacity(nodes.count)
        for i in 0..<nodes.count where deg0[i] > 0 { order.append(i) }
        let simCount = order.count
        for i in 0..<nodes.count where deg0[i] == 0 { order.append(i) }

        var ids = [String](); ids.reserveCapacity(nodes.count)
        var degree = [Int](); degree.reserveCapacity(nodes.count)
        var index = [String: Int](minimumCapacity: nodes.count)
        for (newI, oldI) in order.enumerated() {
            let id = nodes[oldI].id
            ids.append(id); degree.append(deg0[oldI]); index[id] = newI
        }

        var edgeA = [Int](); var edgeB = [Int]()
        edgeA.reserveCapacity(graph.edges.count); edgeB.reserveCapacity(graph.edges.count)
        for e in graph.edges {
            guard let a = index[e.source], let b = index[e.target], a != b else { continue }
            edgeA.append(a); edgeB.append(b)   // both endpoints have degree ≥ 1 ⇒ a,b < simCount
        }

        self.ids = ids
        self.index = index
        self.degree = degree
        self.edgeA = edgeA
        self.edgeB = edgeB
        self.simulatedCount = simCount

        // Connected nodes: a tight phyllotaxis spiral the physics relaxes. Orphans: a
        // wider, static spiral beyond the connected core (never simulated). Deterministic
        // so launches/previews look identical.
        let golden = CGFloat.pi * (3 - (5 as CGFloat).squareRoot())
        var px = [CGFloat](repeating: 0, count: nodes.count)
        var py = [CGFloat](repeating: 0, count: nodes.count)
        for i in 0..<simCount {
            let r = 14 * (CGFloat(i) + 1).squareRoot()
            let a = CGFloat(i) * golden
            px[i] = r * cos(a); py[i] = r * sin(a)
        }
        let haloBase = 80 + 30 * CGFloat(simCount).squareRoot()
        for j in simCount..<nodes.count {
            let k = j - simCount
            let r = haloBase + 22 * (CGFloat(k) + 1).squareRoot()
            let a = CGFloat(k) * golden
            px[j] = r * cos(a); py[j] = r * sin(a)
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
        let n = simulatedCount          // only connected nodes participate; orphans stay put
        guard n > 0 else { return 0 }

        // Repulsion — O(n²) over the connected core only. Symmetric, accumulate per pair.
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
            sx *= alpha; sy *= alpha          // cool: motion shrinks toward zero as alpha decays
            px[i] += sx
            py[i] += sy
            energy += sx * sx + sy * sy
            i += 1
        }
        if alpha > alphaMin { alpha -= alpha * alphaDecay } else { alpha = alphaMin }
        return energy
    }

    /// Run the sim forward without rendering — used to pre-settle a static layout
    /// (Reduce Motion) or to warm-start before the first frame.
    mutating func settle(maxIterations: Int = 400) {
        var k = 0
        while k < maxIterations && alpha > alphaMin { step(); k += 1 }
    }
}
