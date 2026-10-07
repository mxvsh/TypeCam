//
//  ContentView.swift
//  TypeCam
//
//  Created by Monawwar Abdullah on 07/10/26.
//

import SwiftUI

// Placeholder until the camera screen lands (see docs/ROADMAP.md, M1).
struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("TypeCam")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
        }
    }
}

#Preview {
    ContentView()
}
