//
//  RootView.swift
//  TypeCam
//

import AVFoundation
import SwiftUI

struct RootView: View {
    let camera: CameraModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch camera.authorization {
            case .authorized, .notDetermined:
                CameraScreen(camera: camera)
            default:
                PermissionView()
            }
        }
        .task { await camera.start() }
        .onChange(of: scenePhase, initial: true) { _, phase in
            // Locking the phone stops capture, so never let it auto-lock while open.
            UIApplication.shared.isIdleTimerDisabled = phase == .active
            switch phase {
            case .active: camera.resume()
            case .background: camera.suspend()
            default: break
            }
        }
    }
}

private struct PermissionView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.accent)
            Text("Camera access needed")
                .font(.title3.weight(.semibold))
            Text("TypeCam streams your camera to OBS on your Mac. Allow camera access in Settings to continue.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .preferredColorScheme(.dark)
    }
}
