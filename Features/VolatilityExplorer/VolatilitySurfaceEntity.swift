//
//  VolatilitySurfaceEntity.swift
//  VolatilityExplorer
//
//  Created by Pushkal Mondal on 31/08/26.
//

import RealityKit
import RealityKitContent
import simd
import UIKit

/// Owns the whole 3D scanner scene: the fitted wireframe surface, the floating
/// contract dots, the spot-price plane, and the axis labels — all parented
/// under one rotatable root entity so a drag gesture can grab and orbit the
/// entire graph as a rigid group.
@MainActor
final class VolatilitySurfaceController {
    /// The rotatable/repositionable group everything else hangs off of. The
    /// drag-to-rotate gesture and the Buy/Sell recentering animation both act
    /// on this entity, never on the individual pieces. Its own transform is
    /// left untouched across ticker switches (see `rebuild(chain:)`), so the
    /// user's current rotation survives.
    let rootEntity: Entity
    private var surfaceEntity: ModelEntity
    private var mesh: VolatilitySurfaceMesh
    private var dotEntities: [ModelEntity] = []
    private var spotPlaneEntity: ModelEntity
    private var labelEntities: [Entity] = []
    /// Loaded once and reused across ticker switches — the heatmap material
    /// doesn't depend on grid size, so there's no reason to reload it.
    private let material: any Material

    var widthSpan: Float { mesh.widthSpan }
    var depthSpan: Float { mesh.depthSpan }

    /// Positions the graph below eye level and out in front, like a physical
    /// desk.
    static let defaultPosition = SIMD3<Float>(x: 0, y: -0.6, z: -0.75)
    /// The mesh/dots/labels are built at large pre-scale units (see
    /// VolatilitySurfaceMesh.widthSpan/depthSpan) so grid math stays easy to
    /// reason about; this single parent-entity scale is what actually brings
    /// the whole graph down to a comfortable ~1.0m wide x 0.5m high x 1.0m
    /// deep footprint the user can see all at once without moving their head.
    static let rootScale: Float = 0.2

    init(chain: OptionsChainModel) async throws {
        let material = await Self.loadHeatmapMaterial()
        self.material = material

        let built = try await Self.buildContent(chain: chain, material: material)
        self.mesh = built.mesh
        self.surfaceEntity = built.surface
        self.dotEntities = built.dots
        self.spotPlaneEntity = built.spotPlane
        self.labelEntities = built.labels

        let root = Entity()
        root.position = Self.defaultPosition
        root.scale = SIMD3<Float>(repeating: Self.rootScale)
        root.addChild(built.surface)
        built.labels.forEach { root.addChild($0) }
        built.dots.forEach { root.addChild($0) }
        root.addChild(built.spotPlane)
        self.rootEntity = root

        refresh(chain: chain)
    }

    /// Loads the hand-authored ShaderGraphMaterial that reads the mesh's per-vertex
    /// richness color (see VolatilityHeatmap.usda + the Geometry Color node) and
    /// falls back to a flat tint if that material can't be loaded, so the surface
    /// still renders even before/without the Reality Composer Pro asset in place.
    private static func loadHeatmapMaterial() async -> any Material {
        do {
            return try await ShaderGraphMaterial(
                named: "/Root/VolatilityHeatmap",
                from: "Materials/VolatilityHeatmap",
                in: realityKitContentBundle
            )
        } catch {
            print("VolatilitySurfaceController: falling back to flat tint, couldn't load VolatilityHeatmap material: \(error)")
            var fallback = PhysicallyBasedMaterial()
            fallback.baseColor.tint = .init(red: 0.55, green: 0.56, blue: 0.6, alpha: 1.0)
            fallback.emissiveColor.color = .init(red: 0.35, green: 0.4, blue: 0.45, alpha: 1.0)
            fallback.roughness.scale = 0.35
            fallback.metallic.scale = 0.0
            fallback.faceCulling = .none
            return fallback
        }
    }

    private struct BuiltContent {
        let mesh: VolatilitySurfaceMesh
        let surface: ModelEntity
        let dots: [ModelEntity]
        let spotPlane: ModelEntity
        let labels: [Entity]
    }

    /// Builds a fresh mesh/dots/spot-plane/labels set sized to `chain`'s own
    /// strike/DTE grid. Used both by `init` and by `rebuild(chain:)` — a
    /// ticker switch can change the grid's column/row count entirely (AAPL's
    /// 17x8 vs. NVDA's own count), and `LowLevelMesh` can't be resized in
    /// place, so a ticker switch always means building this from scratch.
    private static func buildContent(chain: OptionsChainModel, material: any Material) async throws -> BuiltContent {
        let mesh = try VolatilitySurfaceMesh(columns: chain.strikeColumns, rows: chain.expiryRows)
        let meshResource = try await MeshResource(from: mesh.lowLevelMesh)

        let surface = ModelEntity(mesh: meshResource, materials: [material])
        // Generous collision box over the whole graph: this is a broad "grab
        // anywhere to rotate" target, not a precision hover surface (only the
        // individual contract dots need precise per-entity hover).
        let collisionSize = SIMD3<Float>(mesh.widthSpan, 2.6, mesh.depthSpan)
        surface.components.set(CollisionComponent(shapes: [.generateBox(size: collisionSize)]))
        surface.components.set(InputTargetComponent())

        let labels = VolatilityAxisLabels.makeLabels(widthSpan: mesh.widthSpan, depthSpan: mesh.depthSpan, strikes: chain.strikes, dtes: chain.dtes)
        let dots = OptionContractDots.makeDots(mesh: mesh, chain: chain)
        let spotPlane = SpotPricePlane.make(mesh: mesh, chain: chain)

        return BuiltContent(mesh: mesh, surface: surface, dots: dots, spotPlane: spotPlane, labels: labels)
    }

    /// Tears down and rebuilds the mesh, dots, spot plane, and axis labels
    /// for a newly selected ticker. The root entity's own transform is left
    /// untouched, so the graph's on-screen placement and the user's current
    /// rotation both survive the switch. Callers should serialize calls to
    /// this (never start a second rebuild while one is in flight) — see
    /// ContentView's `isRebuildingSurface` guard.
    func rebuild(chain: OptionsChainModel) async {
        do {
            let built = try await Self.buildContent(chain: chain, material: material)

            surfaceEntity.removeFromParent()
            dotEntities.forEach { $0.removeFromParent() }
            spotPlaneEntity.removeFromParent()
            labelEntities.forEach { $0.removeFromParent() }

            mesh = built.mesh
            surfaceEntity = built.surface
            dotEntities = built.dots
            spotPlaneEntity = built.spotPlane
            labelEntities = built.labels

            rootEntity.addChild(built.surface)
            built.labels.forEach { rootEntity.addChild($0) }
            built.dots.forEach { rootEntity.addChild($0) }
            rootEntity.addChild(built.spotPlane)

            refresh(chain: chain)
        } catch {
            print("VolatilitySurfaceController: failed to rebuild for ticker \(chain.ticker): \(error)")
        }
    }

    /// Pushes the mesh, the dots, and the spot plane to their current state.
    /// The fitted-IV grid only actually changes when a ticker is (re)loaded,
    /// but the richness grid is recomputed from scratch every call, since it
    /// depends on both the current "Baseline Scale" slider position and each
    /// contract's live (possibly just-ticked) Actual IV.
    func refresh(chain: OptionsChainModel) {
        var fittedIVGrid = [Float](repeating: 0, count: chain.contracts.count)
        var richnessGrid = [Float](repeating: 0, count: chain.contracts.count)
        for contract in chain.contracts {
            let index = contract.expiryIndex * chain.strikeColumns + contract.strikeIndex
            fittedIVGrid[index] = Float(contract.fittedIV)
            richnessGrid[index] = chain.richness(for: contract)
        }

        mesh.update(
            fittedIVGrid: fittedIVGrid,
            richnessGrid: richnessGrid,
            heightScale: chain.heightScale,
            heightReference: chain.heightReference
        )
        OptionContractDots.refresh(dotEntities, mesh: mesh, chain: chain)
        SpotPricePlane.update(spotPlaneEntity, mesh: mesh, chain: chain)
    }

    /// The surface's local X coordinate for a given strike index, for callers
    /// (e.g. the Buy/Sell recentering animation) that need to reason about
    /// where a delta band sits without reaching into `mesh`.
    func localX(forStrikeIndex strikeIndex: Int) -> Float {
        mesh.localPosition(forStrikeIndex: strikeIndex, expiryIndex: 0, rawValue: 0, heightScale: 0, heightReference: 0).x
    }
}
