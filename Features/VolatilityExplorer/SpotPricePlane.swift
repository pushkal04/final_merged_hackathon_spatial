//
//  SpotPricePlane.swift
//  VolatilityExplorer
//
//  Created by Pushkal Mondal on 31/08/26.
//

import RealityKit
import UIKit
import simd

/// A flat, semi-transparent plane that cuts vertically through the graph at
/// the underlying's current spot price, so a trader can see at a glance which
/// contracts are in-the-money vs. out-of-the-money.
@MainActor
enum SpotPricePlane {
    static func make(mesh: VolatilitySurfaceMesh, chain: OptionsChainModel) -> ModelEntity {
        // `generatePlane(width:height:)` builds a plane in the local X/Y plane
        // facing +Z; rotating 90 degrees around Y turns that into a plane
        // spanning Y (height/IV) and Z (DTE), facing along X — i.e. perpendicular
        // to the strike axis, exactly like a vertical cutting plane.
        let planeMesh = MeshResource.generatePlane(width: mesh.depthSpan + 0.3, height: 3.0, cornerRadius: 0)
        var material = UnlitMaterial(color: .init(red: 0.4, green: 0.85, blue: 1.0, alpha: 1.0))
        material.blending = .transparent(opacity: .init(floatLiteral: 0.16))
        material.faceCulling = .none

        let plane = ModelEntity(mesh: planeMesh, materials: [material])
        plane.orientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        let x = mesh.localX(forStrike: chain.spotPrice, minStrike: chain.minStrike, maxStrike: chain.maxStrike)
        plane.position = SIMD3<Float>(x, 0.35, 0)
        plane.name = "SpotPricePlane"
        return plane
    }

    /// Repositions an existing plane to a new spot price (e.g. after a rescan).
    static func update(_ plane: ModelEntity, mesh: VolatilitySurfaceMesh, chain: OptionsChainModel) {
        plane.position.x = mesh.localX(forStrike: chain.spotPrice, minStrike: chain.minStrike, maxStrike: chain.maxStrike)
    }
}
