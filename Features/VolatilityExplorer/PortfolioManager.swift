//
//  PortfolioManager.swift
//  VolatilityExplorer
//
//  Created by Pushkal Mondal on 05/09/26.
//

import Foundation
import Observation

/// One executed mock trade — the entry snapshot (strike/DTE/premium/IVs) as
/// of the moment "Execute Trade" was tapped, plus the originating contract's
/// `id` so a live mark-to-market can find its still-ticking counterpart in
/// `OptionsChainModel.contracts` if that ticker is the one currently loaded.
/// `PortfolioManager.unrealizedPL(for:liveChain:)` does that lookup — the
/// position itself deliberately holds only the entry snapshot, since a
/// position that's no longer being streamed (a different ticker is loaded)
/// has nothing live to read and should just show its last-known snapshot.
struct PortfolioPosition: Identifiable {
    let id: UUID
    let contractID: Int
    let ticker: String
    let strike: Double
    let dte: Double
    let fittedIVAtEntry: Double
    let actualIVAtEntry: Double
    let premiumPaid: Double
}

/// Tracks the end-to-end mock trading simulation: a starting cash balance,
/// every contract "bought" via the 3D graph's Execute Trade button, and each
/// position's illustrative P&L. Shared between the Info Pane (which executes
/// trades) and the Active Portfolio window (which displays the results) via
/// `.environment(_:)`, so both always agree on the current state.
@MainActor
@Observable
final class PortfolioManager {
    private(set) var cashBalance: Double = 100_000
    private(set) var positions: [PortfolioPosition] = []

    var totalPremiumPaid: Double {
        positions.reduce(0) { $0 + $1.premiumPaid }
    }

    /// Buys one contract at its current mock premium, deducting that premium
    /// from cash and adding the fill to `positions`. A no-op if cash can't
    /// cover the premium — starting with $100,000 against contract-sized
    /// premiums, this should rarely bind, but it keeps the balance honest.
    func executeTrade(_ contract: OptionContract, ticker: String) {
        let premium = Self.mockPremium(for: contract)
        guard cashBalance >= premium else { return }

        cashBalance -= premium
        positions.append(PortfolioPosition(
            id: UUID(),
            contractID: contract.id,
            ticker: ticker,
            strike: contract.strike,
            dte: contract.dte,
            fittedIVAtEntry: contract.fittedIV,
            actualIVAtEntry: contract.actualIV,
            premiumPaid: premium
        ))
    }

    /// Illustrative mock unrealized P&L — NOT a real options pricing model
    /// (no Black-Scholes, no time decay). Approximates the theoretical edge:
    /// positive exactly when the contract is rich (Actual IV above Fitted
    /// IV), scaled by the same dollars-per-IV-point factor as the mock
    /// premium. When `liveChain` is currently showing this position's own
    /// ticker, this marks against that contract's live, still-ticking Actual
    /// IV; otherwise (a different ticker is loaded, so this one isn't being
    /// streamed right now) it falls back to the entry snapshot.
    func unrealizedPL(for position: PortfolioPosition, liveChain: OptionsChainModel?) -> Double {
        let actualIV = liveActualIV(for: position, liveChain: liveChain)
        return (actualIV - position.fittedIVAtEntry) * position.strike * 0.4 * sqrt(position.dte / 365.0)
    }

    func isRich(_ position: PortfolioPosition, liveChain: OptionsChainModel?) -> Bool {
        liveActualIV(for: position, liveChain: liveChain) > position.fittedIVAtEntry
    }

    func totalUnrealizedPL(liveChain: OptionsChainModel?) -> Double {
        positions.reduce(0) { $0 + unrealizedPL(for: $1, liveChain: liveChain) }
    }

    private func liveActualIV(for position: PortfolioPosition, liveChain: OptionsChainModel?) -> Double {
        guard let liveChain, liveChain.ticker == position.ticker,
              let live = liveChain.contracts.first(where: { $0.id == position.contractID }) else {
            return position.actualIVAtEntry
        }
        return live.actualIV
    }

    /// Illustrative mock premium — NOT real options pricing. Loosely scales
    /// with IV, strike, and time-to-expiry the way a real premium roughly
    /// would, just enough to make the simulation feel grounded.
    static func mockPremium(for contract: OptionContract) -> Double {
        contract.actualIV * contract.strike * 0.4 * sqrt(contract.dte / 365.0)
    }
}
