//
//  OptionContractDots.swift
//  VolatilityExplorer
//
//  Created by Pushkal Mondal on 31/08/26.
//

import RealityKit
import UIKit
import simd

/// Builds, repositions, and recolors the individual floating spheres — one
/// per listed contract — that sit above or below the fitted surface at their
/// own actual implied volatility. A contract's price doesn't move just
/// because the "Baseline Scale" slider is being dragged, so `refresh` never
/// reacts to `chain.heightScale`; it exists to track `contract.actualIV`
/// itself changing, which now happens continuously once `MarketStreamService`
/// is running — each tick animates the affected dots to their new height
/// instead of snapping.
@MainActor
enum OptionContractDots {
    static let radius: Float = 0.018
    /// Entity-name prefix used to recover which contract a tapped dot
    /// represents (see ContentView's tap gesture), since RealityKit entities
    /// don't otherwise carry a reference back to arbitrary Swift model data.
    static let namePrefix = "ContractDot_"

    /// Creates one sphere entity per contract, positioned at its fixed,
    /// slider-independent height, with hover + collision so gazing at one
    /// glows it and tapping it can select it.
    static func makeDots(mesh: VolatilitySurfaceMesh, chain: OptionsChainModel) -> [ModelEntity] {
        chain.contracts.map { contract in
            let dot = ModelEntity(
                mesh: .generateSphere(radius: radius),
                materials: [material(for: contract, chain: chain)]
            )
            // heightScale fixed at 1.0 here, deliberately never chain.heightScale:
            // this position is set once and is never recomputed, so it doesn't
            // matter that heightScale can change later — the dot simply never
            // reads it again.
            dot.position = mesh.localPosition(
                forStrikeIndex: contract.strikeIndex,
                expiryIndex: contract.expiryIndex,
                rawValue: Float(contract.actualIV),
                heightScale: 1.0,
                heightReference: chain.heightReference
            )
            dot.components.set(CollisionComponent(shapes: [.generateSphere(radius: radius * 1.6)]))
            dot.components.set(InputTargetComponent())
            dot.components.set(HoverEffectComponent())
            dot.name = "\(namePrefix)\(contract.id)"
            return dot
        }
    }

    /// Recolors an already-built set of dots to match the current
    /// (slider-dependent) richness, and smoothly animates any dot whose
    /// `actualIV` has moved (from a live market tick) to its new height —
    /// called every refresh cycle, including every streaming tick.
    static func refresh(_ dots: [ModelEntity], mesh: VolatilitySurfaceMesh, chain: OptionsChainModel) {
        for (dot, contract) in zip(dots, chain.contracts) {
            let target = mesh.localPosition(
                forStrikeIndex: contract.strikeIndex,
                expiryIndex: contract.expiryIndex,
                rawValue: Float(contract.actualIV),
                heightScale: 1.0,
                heightReference: chain.heightReference
            )
            if simd_distance(dot.position, target) > 0.0001 {
                var transform = dot.transform
                transform.translation = target
                dot.move(to: transform, relativeTo: dot.parent, duration: 0.15, timingFunction: .easeInOut)
            }
            dot.model?.materials = [material(for: contract, chain: chain)]
        }
    }

    private static func material(for contract: OptionContract, chain: OptionsChainModel) -> UnlitMaterial {
        UnlitMaterial(color: richnessColor(chain.richness(for: contract)))
    }

    /// Mirrors `richnessColor` in VolatilityShaders.metal exactly, so the dots
    /// and the surface always agree on what counts as rich vs. cheap. Absolute
    /// rule, no Buy/Sell mode flip: green exactly when richness is positive.
    static func richnessColor(_ richness: Float) -> UIColor {
        let cheap = SIMD3<Float>(0.85, 0.16, 0.16)
        let neutral = SIMD3<Float>(0.55, 0.56, 0.6)
        let rich = SIMD3<Float>(0.15, 0.85, 0.35)

        let normalizer: Float = 0.06
        let magnitude = min(max(abs(richness) / normalizer, 0), 1)
        let target = richness >= 0 ? rich : cheap
        let blended = neutral + (target - neutral) * magnitude
        return UIColor(red: CGFloat(blended.x), green: CGFloat(blended.y), blue: CGFloat(blended.z), alpha: 1.0)
    }
}
