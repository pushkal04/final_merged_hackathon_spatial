//
//  MarketStreamService.swift
//  VolatilityExplorer
//
//  Created by Pushkal Mondal on 05/09/26.
//

import Foundation
import Observation

/// A simulated live market feed: an asynchronous tick loop that nudges the
/// active chain's spot price (geometric Brownian motion) and a rotating
/// subset of its contracts' Actual IV (an Ornstein-Uhlenbeck process
/// reverting toward each contract's own Fitted IV), so the 3D graph, the
/// readout, and the portfolio all feel "alive" without any real market data.
///
/// Everything here runs on the main actor rather than as a true background
/// `actor`: every consumer of its output (`OptionsChainModel`, RealityKit
/// entities via `VolatilitySurfaceController`, every SwiftUI view) is already
/// main-actor-bound, so a background actor would only add cross-actor hops
/// for numerically trivial math, without freeing up any real work from the
/// main thread. It still qualifies as an "asynchronous service" — its tick
/// cadence is driven by a suspending `Task` loop, not a synchronous timer.
@MainActor
@Observable
final class MarketStreamService {
    private(set) var isRunning = false

    /// How often the tick loop wakes up and applies a batch of contract
    /// ticks — capped to the requested 5-10Hz band so RealityKit never gets
    /// more mesh/dot updates than it can comfortably animate.
    private static let renderInterval: Duration = .milliseconds(120)
    private static var renderIntervalMilliseconds: Double {
        Double(Self.renderInterval.components.seconds) * 1000
            + Double(Self.renderInterval.components.attoseconds) / 1e15
    }
    /// For the "LIVE MARKET SIM" badge — the actual configured tick rate.
    var tickRateDescription: String {
        let hz = 1000.0 / Self.renderIntervalMilliseconds
        return "\(Int(hz.rounded())) Hz"
    }

    private var loopTask: Task<Void, Never>?
    private var nextSpotTickAt: ContinuousClock.Instant = .now

    /// Illustrative annualized volatility per ticker — NOT sourced from real
    /// market data, just enough spread that NVDA/TSLA visibly jitter more
    /// than SPY, matching real-world relative risk.
    private static let annualVolatility: [String: Double] = [
        "SPY": 0.14,
        "AAPL": 0.27,
        "MSFT": 0.23,
        "NVDA": 0.50,
        "TSLA": 0.58
    ]

    func start(chain: OptionsChainModel) {
        guard !isRunning else { return }
        isRunning = true
        scheduleNextSpotTick()
        loopTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                self.tick(chain: chain)
                try? await Task.sleep(for: Self.renderInterval)
            }
        }
    }

    func stop() {
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
    }

    private func scheduleNextSpotTick() {
        let intervalMs = Int64.random(in: 500...1500)
        nextSpotTickAt = .now + .milliseconds(intervalMs)
    }

    private func tick(chain: OptionsChainModel) {
        if .now >= nextSpotTickAt {
            applySpotPriceStep(chain: chain)
            scheduleNextSpotTick()
        }
        applyContractTicks(chain: chain)
    }

    /// One geometric Brownian motion step: dS = S * (mu*dt + sigma*sqrt(dt)*Z).
    /// `dt` is deliberately not wall-clock-accurate (a real GBM dt over a
    /// 500-1500ms tick would be imperceptibly small) — it's tuned so each
    /// tick produces a small but visible move, which is what this simulation
    /// is actually for.
    private func applySpotPriceStep(chain: OptionsChainModel) {
        let sigma = Self.annualVolatility[chain.ticker] ?? 0.30
        let dtYears = 60.0 / (365.0 * 24.0 * 60.0 * 60.0)
        let z = Self.gaussianRandom()
        let drift = -0.5 * sigma * sigma * dtYears
        let diffusion = sigma * dtYears.squareRoot() * z
        let newPrice = chain.spotPrice * exp(drift + diffusion)
        chain.updateSpotPrice(newPrice)
    }

    /// Thins a Poisson-process-like tick across contracts: each contract has
    /// its own per-cycle fire probability weighted toward near-the-money and
    /// short-DTE strikes (where real quote activity concentrates), and on a
    /// fire, its Actual IV takes one Ornstein-Uhlenbeck step back toward its
    /// own fixed Fitted IV — realistic bid/ask-style noise that never
    /// permanently drifts away from the theoretical curve.
    private func applyContractTicks(chain: OptionsChainModel) {
        guard !chain.contracts.isEmpty else { return }
        let baseIntensity = 0.06

        for contract in chain.contracts {
            let ntmWeight = Double(chain.approximateDelta(for: contract))
            let dteWeight = 1.0 / (1.0 + contract.dte / 30.0)
            let weight = (ntmWeight + 0.15) * dteWeight
            let probability = min(1.0, baseIntensity * weight)
            guard Double.random(in: 0..<1) < probability else { continue }

            let theta = 0.4
            let eta = 0.02
            let z = Self.gaussianRandom()
            let reversion = theta * (contract.fittedIV - contract.actualIV)
            let diffusion = eta * z
            let newIV = min(2.0, max(0.02, contract.actualIV + reversion + diffusion))
            chain.applyIVTick(contractID: contract.id, newActualIV: newIV)
        }
    }

    /// Box-Muller transform: two uniform samples in (0,1) become one
    /// standard-normal sample.
    private static func gaussianRandom() -> Double {
        let u1 = Double.random(in: 0.0001...0.9999)
        let u2 = Double.random(in: 0..<1)
        return (-2 * Foundation.log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
