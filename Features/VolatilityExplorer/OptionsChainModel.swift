//
//  OptionsChainModel.swift
//  VolatilityExplorer
//
//  Created by Pushkal Mondal on 31/08/26.
//

import Foundation
import Observation
import SwiftUI

/// Which side of the trade the scanner is currently framed for. No longer
/// affects color (see `OptionsChainModel.isRich(_:)`) — only which delta band
/// the 3D graph recenters on.
enum ScannerMode: String, CaseIterable, Identifiable {
    case sell = "Sell"
    case buy = "Buy"
    var id: String { rawValue }
}

/// One listed, tradeable contract at a specific (strike, DTE), loaded
/// directly from a row of OptionChainData.csv. `fittedIV` is treated as the
/// stable "theoretical model" value and never changes after load; `actualIV`
/// is the live/tradeable market price, which `MarketStreamService` perturbs
/// tick-by-tick once streaming is running — real markets don't re-fit their
/// theoretical curve every few hundred milliseconds, but the quoted price
/// absolutely does move.
struct OptionContract: Identifiable {
    let id: Int
    let strikeIndex: Int
    let expiryIndex: Int
    let strike: Double
    let dte: Double
    let fittedIV: Double
    var actualIV: Double

    /// Static classification straight from the CSV, independent of the
    /// baseline slider. (The 3D dot's *color*, and the info pane's live
    /// label, instead use `OptionsChainModel.isRich(_:)`, which reacts to the
    /// slider — see its doc comment for why those two can disagree.)
    var staticRichness: Double { actualIV - fittedIV }
}

/// Whether a live-streamed value's most recent tick moved up or down —
/// drives the brief green/red flash in the readout before it fades, via
/// `OptionsChainModel.spotPriceFlash`/`contractFlashes`.
enum TickFlash {
    case up
    case down
}

/// One row parsed out of OptionChainData.csv.
private struct CSVOptionRow {
    let ticker: String
    let spotPrice: Double
    let strike: Double
    let dte: Double
    let fittedIV: Double
    let actualIV: Double
}

/// The single source of truth for the whole scanner: an option chain loaded
/// from OptionChainData.csv (headers: Ticker, SpotPrice, Strike, DTE,
/// FittedIV, ActualIV). Both the 3D graph and the 2D info pane read from this
/// exact same `contracts` array, so they can never show different data.
@MainActor
@Observable
final class OptionsChainModel {
    /// Every ticker present in the CSV — useful for a future ticker switcher;
    /// only one ticker's chain is loaded and displayed at a time today.
    static let availableTickers: [String] = OptionChainCSVLoader.availableTickers()

    private(set) var ticker: String
    /// Bumped every time `load(ticker:)` swaps in a different ticker's chain
    /// (including a different strike/DTE grid size) — `ContentView` observes
    /// this to know when the RealityKit mesh/dots need a full teardown and
    /// rebuild, rather than just a data refresh.
    private(set) var tickerRevision = 0

    /// The underlying's spot price. Starts at the CSV's static value and
    /// then drifts continuously once `MarketStreamService` is running — the
    /// Spot Plane cuts through the graph here.
    private(set) var spotPrice: Double = 0
    /// Direction of the most recent spot-price tick, for the readout's brief
    /// flash; cleared back to nil ~300ms after each tick by `updateSpotPrice`.
    private(set) var spotPriceFlash: TickFlash?
    private var spotFlashGeneration = 0

    /// Direction of each contract's most recent live IV tick, keyed by
    /// `OptionContract.id`, for the readout table's per-row flash. Entries
    /// are removed automatically ~300ms after each tick.
    private(set) var contractFlashes: [Int: TickFlash] = [:]
    private var contractFlashGenerations: [Int: Int] = [:]

    /// The exact strikes and DTEs present in the CSV for this ticker, sorted
    /// ascending — the mesh grid uses these same points, not an interpolation.
    private(set) var strikes: [Double] = []
    private(set) var dtes: [Double] = []

    var strikeColumns: Int { strikes.count }
    var expiryRows: Int { dtes.count }
    var minStrike: Double { strikes.first ?? 0 }
    var maxStrike: Double { strikes.last ?? 0 }
    var minExpiryDays: Double { dtes.first ?? 0 }
    var maxExpiryDays: Double { dtes.last ?? 0 }

    /// Built once at load from the CSV; never reshuffled. Ordered row-major
    /// (DTE outer, strike inner) to match the mesh grid's own vertex order.
    private(set) var contracts: [OptionContract] = []

    /// Which dot the user last tapped, for the 2D info pane to display.
    var selectedContract: OptionContract?

    /// "Buy" vs "Sell" framing — only affects which delta band the graph
    /// recenters on (see ContentView.recenterForMode); no longer affects color.
    var mode: ScannerMode = .sell {
        didSet {
            guard oldValue != mode else { return }
            modeRevision += 1
        }
    }
    private(set) var modeRevision = 0

    /// The "baseline parameter" ornament control. Moves ONLY the fitted mesh's
    /// Y position — the floating dots are real listed prices and stay at
    /// their fixed absolute IV height no matter what this is set to.
    var heightScale: Float = 1.0

    /// The mid-range value subtracted from raw IV before scaling to height,
    /// so low IV dips below y=0 and high IV rises above it. Computed from
    /// this chain's own data (its mean Fitted IV) rather than a fixed
    /// constant, since different tickers' IV levels can differ enormously
    /// (AAPL's chain tops out under 40%; TSLA's exceeds 70%).
    var heightReference: Float {
        guard !contracts.isEmpty else { return 0.3 }
        let sum = contracts.reduce(0.0) { $0 + $1.fittedIV }
        return Float(sum / Double(contracts.count))
    }

    init(ticker: String = "AAPL") {
        self.ticker = ticker
        load(ticker: ticker)
    }

    /// Parses OptionChainData.csv and replaces this model's entire chain with
    /// the rows for `ticker`. Does nothing if the ticker isn't found.
    func load(ticker: String) {
        let rows = OptionChainCSVLoader.loadRows(ticker: ticker)
        guard !rows.isEmpty else {
            print("OptionsChainModel: no CSV rows found for ticker \(ticker)")
            return
        }

        self.ticker = ticker
        self.spotPrice = rows[0].spotPrice

        let strikeValues = Array(Set(rows.map(\.strike))).sorted()
        let dteValues = Array(Set(rows.map(\.dte))).sorted()
        self.strikes = strikeValues
        self.dtes = dteValues

        var nextID = 0
        var built: [OptionContract] = []
        built.reserveCapacity(rows.count)
        for row in rows {
            guard let strikeIndex = strikeValues.firstIndex(of: row.strike),
                  let expiryIndex = dteValues.firstIndex(of: row.dte) else { continue }
            built.append(OptionContract(
                id: nextID,
                strikeIndex: strikeIndex,
                expiryIndex: expiryIndex,
                strike: row.strike,
                dte: row.dte,
                fittedIV: row.fittedIV,
                actualIV: row.actualIV
            ))
            nextID += 1
        }
        contracts = built
        selectedContract = nil
        contractFlashes.removeAll()
        contractFlashGenerations.removeAll()
        spotPriceFlash = nil
        tickerRevision += 1
    }

    // MARK: - Live streaming mutations (see MarketStreamService)

    /// Applies one GBM step's worth of spot-price movement and flashes the
    /// readout. A no-op if the price didn't actually change (shouldn't
    /// happen with continuous GBM, but keeps this safe to call defensively).
    func updateSpotPrice(_ newPrice: Double) {
        guard newPrice != spotPrice else { return }
        let direction: TickFlash = newPrice > spotPrice ? .up : .down
        spotPrice = newPrice
        spotPriceFlash = direction
        spotFlashGeneration += 1
        let generation = spotFlashGeneration
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard spotFlashGeneration == generation else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                spotPriceFlash = nil
            }
        }
    }

    /// Applies one live tick to a single contract's Actual IV (the market
    /// price) and flashes its readout row. `fittedIV` — the theoretical
    /// model — is never touched here or anywhere post-load.
    func applyIVTick(contractID: Int, newActualIV: Double) {
        guard let index = contracts.firstIndex(where: { $0.id == contractID }) else { return }
        let old = contracts[index].actualIV
        guard newActualIV != old else { return }
        contracts[index].actualIV = newActualIV
        flashContract(contractID, direction: newActualIV > old ? .up : .down)
    }

    private func flashContract(_ id: Int, direction: TickFlash) {
        contractFlashes[id] = direction
        let generation = (contractFlashGenerations[id] ?? 0) + 1
        contractFlashGenerations[id] = generation
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard contractFlashGenerations[id] == generation else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                contractFlashes[id] = nil
            }
        }
    }

    // MARK: - Dynamic (baseline-slider-dependent) height & color

    /// The fitted mesh's *current* Y height at this contract's grid cell,
    /// after the baseline slider's scale is applied.
    func meshHeight(for contract: OptionContract) -> Float {
        (Float(contract.fittedIV) - heightReference) * heightScale
    }

    /// The dot's fixed Y height — deliberately independent of `heightScale`,
    /// since a real listed contract's price doesn't move just because you're
    /// adjusting how the theoretical model is drawn.
    func dotHeight(for contract: OptionContract) -> Float {
        Float(contract.actualIV) - heightReference
    }

    /// Displayed Fitted IV = Base Fitted IV (from the CSV) + Slider Offset:
    /// the IV value the theoretical model is *currently* implying at this
    /// contract's cell, after "Baseline Scale" is applied — not just its
    /// fixed CSV number. Exact inverse of `meshHeight`, so it always matches
    /// what the mesh is visually showing, and reduces to `contract.fittedIV`
    /// exactly when heightScale == 1.
    func displayedFittedIV(for contract: OptionContract) -> Double {
        Double(meshHeight(for: contract)) + Double(heightReference)
    }

    /// Positive when the (fixed) dot is currently sitting above the
    /// (slider-adjustable) mesh. Algebraically identical to
    /// `contract.actualIV - displayedFittedIV(for: contract)`, just expressed
    /// in height units — the two can never disagree.
    func richness(for contract: OptionContract) -> Float {
        dotHeight(for: contract) - meshHeight(for: contract)
    }

    /// Absolute, unconditional rule: green ("Rich"/overpriced) exactly when
    /// Actual IV currently sits above the mesh; red ("Cheap"/underpriced)
    /// otherwise. Buy/Sell mode does **not** flip this — that mode-based
    /// inversion was the bug in the previous build.
    func isRich(_ contract: OptionContract) -> Bool {
        richness(for: contract) > 0
    }

    // MARK: - Buy/Sell recentering

    /// Crude moneyness-based proxy for option delta (0 = far out-of-the-money,
    /// 1 = at-the-money) — there's no real pricing model behind this, just
    /// enough signal to bucket contracts into a "near the money" vs "far OTM"
    /// band for the Buy/Sell recentering behavior.
    func approximateDelta(for contract: OptionContract) -> Float {
        let halfRange = Float((maxStrike - minStrike) / 2)
        guard halfRange > 0 else { return 1 }
        let distance = abs(Float(contract.strike - spotPrice))
        return max(0, 1 - distance / halfRange)
    }
}

// MARK: - CSV loading

/// A minimal, dependency-free CSV reader for OptionChainData.csv. The file's
/// values never contain commas or quoted fields, so a plain split is safe —
/// no need to pull in a full CSV parsing library for a hackathon-scale file.
private enum OptionChainCSVLoader {
    private static func allRows() -> [CSVOptionRow] {
        guard let url = Bundle.main.url(forResource: "OptionChainData", withExtension: "csv") else {
            print("OptionChainCSVLoader: OptionChainData.csv not found in the app bundle")
            return []
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("OptionChainCSVLoader: failed to read OptionChainData.csv")
            return []
        }

        var rows: [CSVOptionRow] = []
        let lines = text.split(whereSeparator: \.isNewline)
        for line in lines.dropFirst() { // skip the header row
            let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 6,
                  let spotPrice = Double(fields[1]),
                  let strike = Double(fields[2]),
                  let dte = Double(fields[3]),
                  let fittedIV = Double(fields[4]),
                  let actualIV = Double(fields[5]) else { continue }
            rows.append(CSVOptionRow(
                ticker: fields[0],
                spotPrice: spotPrice,
                strike: strike,
                dte: dte,
                fittedIV: fittedIV,
                actualIV: actualIV
            ))
        }
        return rows
    }

    static func loadRows(ticker: String) -> [CSVOptionRow] {
        allRows().filter { $0.ticker == ticker }
    }

    static func availableTickers() -> [String] {
        var seen: [String] = []
        for row in allRows() where !seen.contains(row.ticker) {
            seen.append(row.ticker)
        }
        return seen
    }
}
