//
//  ImmersiveView.swift
//  VolatilityExplorer
//
//  Created by Pushkal Mondal on 31/08/26.
//

import SwiftUI
import RealityKit
import RealityKitContent

struct ImmersiveView: View {

    var body: some View {
        // The volatility surface lives in ContentView's volumetric window; this
        // space is intentionally left empty for now rather than loading the
        // default RealityKitContent template scene.
        RealityView { _ in }
    }
}

#Preview(immersionStyle: .mixed) {
    ImmersiveView()
        .environment(AppModel())
}
