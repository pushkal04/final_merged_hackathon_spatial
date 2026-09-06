//
//  VolatilityAxisLabels.swift
//  VolatilityExplorer
//
//  Created by Pushkal Mondal on 31/08/26.
//

import RealityKit
import UIKit
import simd

/// Floating 3D axis lines and text labels along the surface's edges, giving the
/// strike-price, days-to-expiration, and implied-volatility axes real-world
/// units. Every label carries a `BillboardComponent`, so it's always readable
/// without the user having to manually rotate the graph to face it.
@MainActor
enum VolatilityAxisLabels {
    /// Where the X/Z axis lines and their tick labels sit, relative to the
    /// surface's own local origin — comfortably below the typical valley
    /// floor so they read as a "floor" the surface hovers above.
    private static let floorY: Float = -0.85
    private static let axisLineThickness: Float = 0.006
    private static let axisColor = UIColor.white.withAlphaComponent(0.55)

    /// Real CSV chains can carry far more strikes/DTEs than the old
    /// deterministic matrix did (AAPL alone has 17 strikes), so ticks are
    /// thinned to this many representative labels per axis instead of one
    /// per grid line — with the whole graph rendered at a fraction of its
    /// former size (see VolatilitySurfaceController's parent scale), showing
    /// every single strike would collide into unreadable overlapping text.
    private static let maxTicksPerAxis = 6

    static func makeLabels(widthSpan: Float, depthSpan: Float, strikes: [Double], dtes: [Double]) -> [Entity] {
        var nodes: [Entity] = []
        let halfWidth = widthSpan / 2
        let halfDepth = depthSpan / 2
        let strikeAxisZ = halfDepth + 0.12
        let expiryAxisX = -halfWidth - 0.12

        // Strike-price axis (X): a line along the front edge, a thinned set
        // of tick labels across the actual listed strikes, plus the axis title.
        nodes.append(makeAxisLine(
            from: SIMD3<Float>(-halfWidth, floorY, strikeAxisZ),
            to: SIMD3<Float>(halfWidth, floorY, strikeAxisZ)
        ))
        for index in tickIndices(count: strikes.count) {
            let t = strikes.count > 1 ? Float(index) / Float(strikes.count - 1) : 0
            let x = t * widthSpan - halfWidth
            let label = makeTextLabel("$\(Int(strikes[index]))", fontSize: 0.042)
            label.position = SIMD3<Float>(x, floorY - 0.09, strikeAxisZ)
            nodes.append(label)
        }
        let strikeTitle = makeTextLabel("Strike Price ->", fontSize: 0.065, color: .cyan)
        strikeTitle.position = SIMD3<Float>(0, floorY - 0.2, strikeAxisZ + 0.02)
        nodes.append(strikeTitle)

        // Days-to-expiration axis (Z): a line along the left edge, a thinned
        // set of tick labels across the actual listed DTEs, plus the axis title.
        nodes.append(makeAxisLine(
            from: SIMD3<Float>(expiryAxisX, floorY, -halfDepth),
            to: SIMD3<Float>(expiryAxisX, floorY, halfDepth)
        ))
        for index in tickIndices(count: dtes.count) {
            let t = dtes.count > 1 ? Float(index) / Float(dtes.count - 1) : 0
            let z = t * depthSpan - halfDepth
            let label = makeTextLabel("\(Int(dtes[index]))d", fontSize: 0.042)
            label.position = SIMD3<Float>(expiryAxisX - 0.08, floorY - 0.02, z)
            nodes.append(label)
        }
        // No manual rotation here: `makeTextLabel` already attaches a
        // BillboardComponent, which drives orientation every frame to face
        // the viewer — a fixed axis-relative rotation would just be
        // overwritten the moment the graph (or the viewer) moves.
        let expiryTitle = makeTextLabel("<- Days to Expiration (DTE)", fontSize: 0.065, color: .cyan)
        expiryTitle.position = SIMD3<Float>(expiryAxisX - 0.1, floorY - 0.02, 0)
        nodes.append(expiryTitle)

        // Implied-volatility axis (Y): a vertical line at the near-left corner.
        let ivAxisTop: Float = 1.6
        nodes.append(makeAxisLine(
            from: SIMD3<Float>(expiryAxisX, floorY, strikeAxisZ),
            to: SIMD3<Float>(expiryAxisX, ivAxisTop, strikeAxisZ)
        ))
        let ivTicks: [(text: String, y: Float)] = [
            ("Low", floorY + 0.1),
            ("High", ivAxisTop - 0.1)
        ]
        for tick in ivTicks {
            let label = makeTextLabel(tick.text, fontSize: 0.045)
            label.position = SIMD3<Float>(expiryAxisX - 0.08, tick.y, strikeAxisZ)
            nodes.append(label)
        }
        let ivTitle = makeTextLabel("Implied Volatility (IV) ->", fontSize: 0.065, color: .cyan)
        ivTitle.position = SIMD3<Float>(expiryAxisX - 0.08, ivAxisTop + 0.12, strikeAxisZ)
        nodes.append(ivTitle)

        return nodes
    }

    /// Evenly spaced indices into a `count`-element array, always including
    /// the first and last, capped at `maxTicksPerAxis` — so a 17-strike chain
    /// shows ~6 representative ticks instead of all 17.
    private static func tickIndices(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        guard count > maxTicksPerAxis else { return Array(0..<count) }
        let stepCount = maxTicksPerAxis - 1
        return (0...stepCount).map { step in
            Int((Float(step) / Float(stepCount) * Float(count - 1)).rounded())
        }.reduce(into: [Int]()) { result, index in
            if result.last != index { result.append(index) }
        }
    }

    private static func makeAxisLine(from start: SIMD3<Float>, to end: SIMD3<Float>) -> Entity {
        let delta = end - start
        let length = simd_length(delta)
        let mesh = MeshResource.generateBox(size: SIMD3<Float>(
            max(length, axisLineThickness),
            axisLineThickness,
            axisLineThickness
        ))
        let bar = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: axisColor)])
        bar.position = (start + end) / 2
        if length > .ulpOfOne {
            // Rotate the box (built along +X) so it points from start to end.
            let direction = simd_normalize(delta)
            bar.orientation = simd_quatf(from: SIMD3<Float>(1, 0, 0), to: direction)
        }
        // Axis lines are geometric reference marks, not text — they stay fixed
        // with the graph rather than billboarding to face the viewer.
        return bar
    }

    private static func makeTextLabel(_ text: String, fontSize: Float = 0.05, color: UIColor = .white) -> Entity {
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.002,
            font: .systemFont(ofSize: CGFloat(fontSize)),
            alignment: .center
        )
        let material = UnlitMaterial(color: color)
        let textEntity = ModelEntity(mesh: mesh, materials: [material])

        // generateText's origin is the glyph run's bottom-left; recenter the mesh
        // within a wrapper so the wrapper's own position marks the label's midpoint.
        let extents = mesh.bounds.extents
        textEntity.position = SIMD3<Float>(-extents.x / 2, -extents.y / 2, 0)

        let wrapper = Entity()
        wrapper.addChild(textEntity)
        // Always rotates to face the user, so every label stays legible from
        // any viewing angle without the user having to manually rotate the graph.
        wrapper.components.set(BillboardComponent())
        return wrapper
    }
}
