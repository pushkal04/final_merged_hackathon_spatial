//
//  VolatilityControlsOrnament.swift
//  VolatilityExplorer
//
//  Created by Pushkal Mondal on 31/08/26.
//

import SwiftUI

/// All controls — ticker switcher, Buy/Sell mode, baseline height scale, live
/// market sim — housed in a single window bottom ornament, stacked as two
/// rows so nothing is crowded. (An earlier version put the ticker switcher in
/// its own `.scene(.top)` ornament, but that anchors to the top of the whole
/// declared window volume, not the top of the visible graph — with the
/// window's generous height it rendered up near the ceiling. Keeping every
/// control in one bottom ornament avoids that entirely.) Intentionally left
/// unstyled beyond padding so it relies on the ornament's system-standard
/// glass material background.
struct VolatilityControlsOrnament: View {
    @Bindable var chain: OptionsChainModel
    var marketStream: MarketStreamService
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 16) {
                Picker("Ticker", selection: Binding(
                    get: { chain.ticker },
                    set: { chain.load(ticker: $0) }
                )) {
                    ForEach(OptionsChainModel.availableTickers, id: \.self) { ticker in
                        Text(ticker).tag(ticker)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)

                Text(chain.spotPrice, format: .currency(code: "USD"))
                    .font(.callout.monospacedDigit().bold())
                    .foregroundStyle(flashColor(chain.spotPriceFlash) ?? .primary)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: chain.spotPriceFlash)
                    .frame(width: 90, alignment: .leading)

                Divider().frame(height: 20)

                Button {
                    if marketStream.isRunning {
                        marketStream.stop()
                    } else {
                        marketStream.start(chain: chain)
                    }
                } label: {
                    Label(marketStream.isRunning ? "Pause" : "Go Live", systemImage: marketStream.isRunning ? "pause.fill" : "play.fill")
                }
                if marketStream.isRunning {
                    LiveMarketBadge(rateDescription: marketStream.tickRateDescription)
                }
            }

            HStack(spacing: 16) {
                Picker("Mode", selection: $chain.mode) {
                    ForEach(ScannerMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)

                Divider().frame(height: 20)

                Text("Baseline Scale")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $chain.heightScale, in: 0.25...2.5)
                    .frame(width: 200)
                Text(chain.heightScale, format: .number.precision(.fractionLength(2)))
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)

                Divider().frame(height: 20)

                Button {
                    openWindow(id: "ScannerReadout")
                } label: {
                    Label("Readout", systemImage: "list.bullet.rectangle")
                }

                ToggleImmersiveSpaceButton()
            }
        }
        .padding(20)
    }

    private func flashColor(_ flash: TickFlash?) -> Color? {
        switch flash {
        case .up: return .green
        case .down: return .red
        case nil: return nil
        }
    }
}

/// A small pulsating "live" indicator, shown only while the market
/// simulation is running.
private struct LiveMarketBadge: View {
    let rateDescription: String
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.green)
                .frame(width: 8, height: 8)
                .opacity(pulse ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            Text("LIVE MARKET SIM · \(rateDescription)")
                .font(.caption2.bold())
        }
        .onAppear { pulse = true }
    }
}
