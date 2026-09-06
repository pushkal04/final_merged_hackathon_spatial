import SwiftUI

struct UnifiedLauncherView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        HStack(spacing: 20) {
            Button {
                openWindow(id: "volatility-explorer")
            } label: {
                Label("Volatility Explorer", systemImage: "chart.xyaxis.line")
            }
            .buttonStyle(.borderedProminent)

            Divider()
                .frame(height: 30)

            Button {
                openWindow(id: "spatial-workstation")
            } label: {
                Label("Spatial Workstation", systemImage: "square.grid.2x2")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .glassBackgroundEffect()
    }
}
