//
//  ContentView.swift
//  VolatilityExplorer
//
//  Created by Pushkal Mondal on 31/08/26.
//

import SwiftUI
import RealityKit
import RealityKitContent

struct VolatilityRootView: View {

    @Environment(OptionsChainModel.self) private var chain
    @Environment(MarketStreamService.self) private var marketStream
    @Environment(\.openWindow) private var openWindow
    @State private var surfaceController: VolatilitySurfaceController?
    /// Guards against starting a second `rebuild(chain:)` while one from a
    /// prior ticker switch is still in flight (e.g. the user taps through
    /// tickers faster than a rebuild completes).
    @State private var isRebuildingSurface = false

    /// Accumulated yaw/pitch, tracked as separate angles (not a single
    /// composed quaternion) so pitch can be clamped independently of however
    /// much the graph has been spun around — a data surface flipped upside
    /// down is disorienting, not useful, and unclamped tilt would need a much
    /// larger — and mostly wasted — volumetric window to never clip.
    @State private var accumulatedYaw: Float = 0
    @State private var accumulatedPitch: Float = 0
    @State private var yawAtDragStart: Float = 0
    @State private var pitchAtDragStart: Float = 0
    @State private var isDragging = false
    /// Radians of rotation per meter of hand translation.
    private let rotationSensitivity: Float = 1.0
    private let maxPitch: Float = 0.6

    var body: some View {
        RealityView { content in
            do {
                let controller = try await VolatilitySurfaceController(chain: chain)
                surfaceController = controller
                content.add(controller.rootEntity)
            } catch {
                print("ContentView: failed to build option chain scanner: \(error)")
            }
        } update: { content in
            surfaceController?.refresh(chain: chain)
        }
        .gesture(
            // Pinch-and-drag anywhere on the graph orbits the whole thing, like
            // grabbing a physical model — not a per-point deformation.
            DragGesture()
                .targetedToAnyEntity()
                .onChanged { value in
                    guard let root = surfaceController?.rootEntity else { return }
                    if !isDragging {
                        isDragging = true
                        yawAtDragStart = accumulatedYaw
                        pitchAtDragStart = accumulatedPitch
                    }
                    // `translation3D` is reported in the coordinate space of
                    // whichever entity the drag actually started on — the
                    // surface, a dot, or the spot plane, which carries its own
                    // 90-degree rotation to face along the strike axis.
                    // Without converting into one fixed frame, grabbing the
                    // plane scrambled which hand direction meant yaw vs. pitch,
                    // which is what made rotation feel erratic and made the
                    // plane look like it was spinning independently of the
                    // rest of the graph instead of rotating together with it.
                    let translation = value.convert(value.translation3D, from: .local, to: root)
                    accumulatedYaw = yawAtDragStart + translation.x * rotationSensitivity
                    let rawPitch = pitchAtDragStart + translation.y * rotationSensitivity
                    accumulatedPitch = max(-maxPitch, min(maxPitch, rawPitch))

                    let yawRotation = simd_quatf(angle: accumulatedYaw, axis: SIMD3<Float>(0, 1, 0))
                    let pitchRotation = simd_quatf(angle: accumulatedPitch, axis: SIMD3<Float>(1, 0, 0))
                    root.orientation = yawRotation * pitchRotation
                }
                .onEnded { _ in
                    isDragging = false
                }
        )
        // Passive gaze/hover can't be observed from app code on visionOS —
        // that's deliberate, for privacy (the OS renders HoverEffectComponent's
        // glow entirely on its own, with no callback to Swift). Selecting a
        // contract for the info pane needs an explicit action, so a tap (a
        // pinch while looking at the dot) is what actually drives it; the
        // hover glow remains a purely visual "this is tappable" affordance.
        .simultaneousGesture(
            TapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    guard value.entity.name.hasPrefix(OptionContractDots.namePrefix),
                          let idString = value.entity.name.split(separator: "_").last,
                          let id = Int(idString),
                          let contract = chain.contracts.first(where: { $0.id == id }) else { return }
                    chain.selectedContract = contract
                }
        )
        .onChange(of: chain.modeRevision) {
            recenterForMode()
        }
        .onChange(of: chain.tickerRevision) {
            guard !isRebuildingSurface else { return }
            isRebuildingSurface = true
            Task {
                await surfaceController?.rebuild(chain: chain)
                isRebuildingSurface = false
            }
        }
        .task {
            // The readout and the portfolio dashboard should already be open,
            // framing the graph, rather than requiring a manual step.
            openWindow(id: "ScannerReadout")
            openWindow(id: "ActivePortfolio")
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            VolatilityControlsOrnament(chain: chain, marketStream: marketStream)
        }
    }

    /// Animates the whole graph sideways so the delta band relevant to the
    /// current Buy/Sell mode sits centered in front of the viewer: near-the-money
    /// (high delta) for Sell, far out-of-the-money (low delta) for Buy.
    private func recenterForMode() {
        guard let controller = surfaceController else { return }
        let threshold: Float = chain.mode == .sell ? 0.6 : 0.35
        let relevant = chain.contracts.filter { contract in
            let delta = chain.approximateDelta(for: contract)
            return chain.mode == .sell ? delta > threshold : delta < threshold
        }
        guard !relevant.isEmpty else { return }

        let averageLocalX = relevant.map { controller.localX(forStrikeIndex: $0.strikeIndex) }.reduce(0, +) / Float(relevant.count)
        let targetX = VolatilitySurfaceController.defaultPosition.x - averageLocalX * 0.6

        Task {
            let root = controller.rootEntity
            let startX = root.position.x
            let steps = 24
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                let t = Float(step) / Float(steps)
                // Ease-out so the recenter settles smoothly rather than snapping.
                let eased = 1 - (1 - t) * (1 - t)
                root.position.x = startX + (targetX - startX) * eased
            }
        }
    }
}

#Preview(windowStyle: .automatic) {
    VolatilityRootView()
        .environment(AppModel())
        .environment(OptionsChainModel())
        .environment(MarketStreamService())
        .environment(PortfolioManager())
}
