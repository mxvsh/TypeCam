//
//  TypeCamApp.swift
//  TypeCam
//
//  Created by Monawwar Abdullah on 07/10/26.
//

import SwiftUI

@main
struct TypeCamApp: App {
    @State private var camera = CameraModel(store: SettingsStore())

    var body: some Scene {
        WindowGroup {
            RootView(camera: camera)
                .preferredColorScheme(.dark)
        }
    }
}
