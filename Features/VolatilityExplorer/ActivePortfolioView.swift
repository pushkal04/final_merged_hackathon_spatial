//
//  ActivePortfolioView.swift
//  VolatilityExplorer
//
//  Created by Pushkal Mondal on 05/09/26.
//

import SwiftUI

/// The "Active Portfolio" window: mock cash balance, every contract bought
/// via the 3D graph's Execute Trade button, and each position's illustrative
/// P&L. Anchored to the left side of the main volumetric window (see
/// VolatilityExplorerApp) so it reads as a trading desk framing the graph.
struct ActivePortfolioView: View {
    @Environment(PortfolioManager.self) private var portfolio
    @Environment(OptionsChainModel.self) private var chain

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            if portfolio.positions.isEmpty {
                emptyState
            } else {
                positionsList
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 380, minHeight: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Active Portfolio")
                .font(.title.bold())

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Cash").foregroundStyle(.secondary)
                    Text(portfolio.cashBalance, format: .currency(code: "USD"))
                        .fontWeight(.semibold)
                }
                GridRow {
                    Text("Premium Deployed").foregroundStyle(.secondary)
                    Text(portfolio.totalPremiumPaid, format: .currency(code: "USD"))
                }
                GridRow {
                    Text("Unrealized P&L").foregroundStyle(.secondary)
                    let totalPL = portfolio.totalUnrealizedPL(liveChain: chain)
                    Text(totalPL, format: .currency(code: "USD").sign(strategy: .always()))
                        .foregroundStyle(totalPL >= 0 ? .green : .red)
                        .fontWeight(.semibold)
                        .contentTransition(.numericText())
                }
            }
            .font(.callout.monospacedDigit())

            Text("Mock premiums and P&L are illustrative, not real options pricing.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No positions yet")
                .font(.headline)
            Text("Tap a contract in the 3D graph, then Execute Trade.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var positionsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Positions")
                .font(.headline)

            HStack {
                Text("Ticker").frame(width: 60, alignment: .leading)
                Text("Strike").frame(width: 70, alignment: .leading)
                Text("DTE").frame(width: 50, alignment: .leading)
                Text("Premium").frame(width: 80, alignment: .leading)
                Text("P&L").frame(width: 80, alignment: .leading)
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(portfolio.positions) { position in
                        positionRow(position)
                        Divider()
                    }
                }
            }
        }
    }

    private func positionRow(_ position: PortfolioPosition) -> some View {
        let pl = portfolio.unrealizedPL(for: position, liveChain: chain)
        return HStack {
            Text(position.ticker).frame(width: 60, alignment: .leading)
            Text(position.strike, format: .currency(code: "USD").precision(.fractionLength(0)))
                .frame(width: 70, alignment: .leading)
            Text("\(Int(position.dte))d").frame(width: 50, alignment: .leading)
            Text(position.premiumPaid, format: .currency(code: "USD").precision(.fractionLength(0)))
                .frame(width: 80, alignment: .leading)
            Text(pl, format: .currency(code: "USD").precision(.fractionLength(0)).sign(strategy: .always()))
                .foregroundStyle(pl >= 0 ? .green : .red)
                .frame(width: 80, alignment: .leading)
                .contentTransition(.numericText())
        }
        .font(.caption.monospacedDigit())
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .animation(.easeOut(duration: 0.2), value: pl)
    }
}

#Preview(windowStyle: .automatic) {
    ActivePortfolioView()
        .environment(PortfolioManager())
        .environment(OptionsChainModel())
}
