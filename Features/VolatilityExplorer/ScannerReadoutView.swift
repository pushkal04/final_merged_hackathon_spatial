//
//  ScannerReadoutView.swift
//  VolatilityExplorer
//
//  Created by Pushkal Mondal on 31/08/26.
//

import SwiftUI

/// A plain 2D readout that floats beside the 3D graph: what's being scanned,
/// how to read the color coding in the current Buy/Sell mode, the currently
/// tapped contract's exact numbers, and a scrollable table of every plotted
/// contract — so someone looking at the 3D scanner for the first time (a
/// hackathon judge, say) can immediately tell what data produced it, without
/// having to interpret the shape alone.
struct ScannerReadoutView: View {
    @Environment(OptionsChainModel.self) private var chain
    @Environment(PortfolioManager.self) private var portfolio

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            legend
            if let selected = chain.selectedContract {
                Divider()
                selectedContractCard(selected)
            }
            Divider()
            contractTable
        }
        .padding(24)
        .frame(minWidth: 440, minHeight: 660)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(chain.ticker)
                .font(.title.bold())
            HStack(spacing: 4) {
                Text("Option Chain Scanner — Spot")
                Text(chain.spotPrice, format: .currency(code: "USD"))
                    .fontWeight(.semibold)
                    .foregroundStyle(flashColor(chain.spotPriceFlash) ?? .secondary)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: chain.spotPriceFlash)
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text("\(chain.contracts.count) contracts plotted • \(chain.mode.rawValue) mode")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func flashColor(_ flash: TickFlash?) -> Color? {
        switch flash {
        case .up: return .green
        case .down: return .red
        case nil: return nil
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reading the graph")
                .font(.headline)

            HStack(spacing: 8) {
                Circle().fill(.green).frame(width: 10, height: 10)
                Text(chain.mode == .sell
                     ? "Rich — premium worth selling"
                     : "Cheap — premium worth buying")
                    .font(.caption)
            }
            HStack(spacing: 8) {
                Circle().fill(.red).frame(width: 10, height: 10)
                Text(chain.mode == .sell
                     ? "Cheap — not attractive to sell"
                     : "Rich — not attractive to buy")
                    .font(.caption)
            }

            Text("X: Strike Price   •   Y: Implied Volatility   •   Z: Days to Expiration")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("The wireframe is the fitted volatility model; each dot is one real listed contract at its own actual IV. Dragging \"Baseline Scale\" moves the mesh; when the live market sim is running, dots also drift on their own as Actual IV ticks — either way, a dot's color can flip as it crosses the mesh. Tap a dot to inspect it here.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func selectedContractCard(_ contract: OptionContract) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Selected Contract")
                    .font(.headline)
                Spacer()
                Text(isRich(contract) ? "RICH" : "CHEAP")
                    .font(.caption.bold())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isRich(contract) ? Color.green : Color.red, in: Capsule())
                    .foregroundStyle(.white)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("Strike").foregroundStyle(.secondary)
                    Text(contract.strike, format: .currency(code: "USD").precision(.fractionLength(0)))
                }
                GridRow {
                    Text("DTE").foregroundStyle(.secondary)
                    Text("\(Int(contract.dte)) days")
                }
                GridRow {
                    Text("Fitted IV").foregroundStyle(.secondary)
                    Text(chain.displayedFittedIV(for: contract), format: .percent.precision(.fractionLength(1)))
                }
                GridRow {
                    Text("Actual IV").foregroundStyle(.secondary)
                    Text(contract.actualIV, format: .percent.precision(.fractionLength(1)))
                }
            }
            .font(.callout.monospacedDigit())

            Button {
                portfolio.executeTrade(contract, ticker: chain.ticker)
            } label: {
                Label("Execute Trade", systemImage: "bolt.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var contractTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Plotted Contracts")
                .font(.headline)

            HStack {
                Text("Strike").frame(width: 70, alignment: .leading)
                Text("DTE").frame(width: 55, alignment: .leading)
                Text("Fitted IV").frame(width: 80, alignment: .leading)
                Text("Actual IV").frame(width: 80, alignment: .leading)
                Text("Status").frame(width: 70, alignment: .leading)
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sortedContracts) { contract in
                        contractRow(contract)
                        Divider()
                    }
                }
            }
        }
    }

    private var sortedContracts: [OptionContract] {
        chain.contracts.sorted {
            $0.dte == $1.dte ? $0.strike < $1.strike : $0.dte < $1.dte
        }
    }

    private func contractRow(_ contract: OptionContract) -> some View {
        let flash = chain.contractFlashes[contract.id]
        return HStack {
            Text(contract.strike, format: .currency(code: "USD").precision(.fractionLength(0)))
                .frame(width: 70, alignment: .leading)
            Text("\(Int(contract.dte))d")
                .frame(width: 55, alignment: .leading)
            Text(chain.displayedFittedIV(for: contract), format: .percent.precision(.fractionLength(1)))
                .frame(width: 80, alignment: .leading)
            Text(contract.actualIV, format: .percent.precision(.fractionLength(1)))
                .frame(width: 80, alignment: .leading)
                .contentTransition(.numericText())
            Text(isRich(contract) ? "Rich" : "Cheap")
                .foregroundStyle(isRich(contract) ? .green : .red)
                .frame(width: 70, alignment: .leading)
        }
        .font(.caption.monospacedDigit())
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            rowBackground(flash: flash, isSelected: contract.id == chain.selectedContract?.id),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .animation(.easeOut(duration: 0.3), value: flash)
        .contentShape(Rectangle())
        .onTapGesture {
            chain.selectedContract = contract
        }
    }

    private func rowBackground(flash: TickFlash?, isSelected: Bool) -> Color {
        switch flash {
        case .up: return Color.green.opacity(0.3)
        case .down: return Color.red.opacity(0.3)
        case nil: return isSelected ? Color.accentColor.opacity(0.15) : Color.clear
        }
    }

    /// Same absolute "is this dot currently green" rule the 3D graph uses —
    /// see `OptionsChainModel.isRich(_:)` — so the info pane's Rich/Cheap
    /// label always matches the color the 3D dot is actually showing right now.
    private func isRich(_ contract: OptionContract) -> Bool {
        chain.isRich(contract)
    }
}

#Preview(windowStyle: .automatic) {
    ScannerReadoutView()
        .environment(OptionsChainModel())
        .environment(PortfolioManager())
}
