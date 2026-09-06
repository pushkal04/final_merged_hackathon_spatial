import SwiftUI

@main
struct FinalMergedHackathonSpatialApp: App {
    @State private var appModel = AppModel()
    @State private var chain = OptionsChainModel()
    @State private var portfolio = PortfolioManager()
    @State private var marketStream = MarketStreamService()
    
    var body: some Scene {
        // 1. Lightweight Launcher Hub (Floating Control Bar)
        WindowGroup(id: "launcher") {
            UnifiedLauncherView()
        }
        .windowStyle(.plain)
        .defaultSize(width: 480, height: 100)

        // 2. Volatility Explorer Scene
        WindowGroup(id: "volatility-explorer") {
            VolatilityRootView()
                .environment(appModel)
                .environment(chain)
                .environment(portfolio)
                .environment(marketStream)
        }
        .windowStyle(.volumetric)
        .defaultSize(width: 2.4, height: 2.0, depth: 3.0, in: .meters)

        // Scanner Readout (Volatility Explorer component)
        WindowGroup(id: "ScannerReadout") {
            ScannerReadoutView()
                .environment(chain)
                .environment(portfolio)
        }
        .defaultSize(width: 440, height: 620)
        .defaultWindowPlacement { content, context in
            if let mainVolume = context.windows.first(where: { $0.id == "volatility-explorer" }) {
                return WindowPlacement(.trailing(mainVolume), size: content.sizeThatFits(.unspecified))
            }
            return WindowPlacement(size: content.sizeThatFits(.unspecified))
        }

        // Active Portfolio (Volatility Explorer component)
        WindowGroup(id: "ActivePortfolio") {
            ActivePortfolioView()
                .environment(portfolio)
                .environment(chain)
        }
        .defaultSize(width: 400, height: 620)
        .defaultWindowPlacement { content, context in
            if let mainVolume = context.windows.first(where: { $0.id == "volatility-explorer" }) {
                return WindowPlacement(.leading(mainVolume), size: content.sizeThatFits(.unspecified))
            }
            return WindowPlacement(size: content.sizeThatFits(.unspecified))
        }

        ImmersiveSpace(id: appModel.immersiveSpaceID) {
            ImmersiveView()
                .environment(appModel)
                .onAppear {
                    appModel.immersiveSpaceState = .open
                }
                .onDisappear {
                    appModel.immersiveSpaceState = .closed
                }
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)

        // 3. Spatial Workstation Dashboard Scene
        WindowGroup(id: "spatial-workstation") {
            WorkstationRootView()
        }
        .windowStyle(.automatic)
        .defaultSize(width: 1000, height: 700)
    }
}
