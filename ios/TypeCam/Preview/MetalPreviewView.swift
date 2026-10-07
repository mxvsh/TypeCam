//
//  MetalPreviewView.swift
//  TypeCam
//

import MetalKit
import SwiftUI

struct MetalPreviewView: UIViewRepresentable {
    let mailbox: FrameMailbox
    /// Receives the view's layer once, for `AVCaptureDevice.RotationCoordinator`.
    var onLayer: (CALayer) -> Void

    func makeCoordinator() -> PreviewRenderer? {
        PreviewRenderer(mailbox: mailbox)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator?.device)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.backgroundColor = .black
        let layer = view.layer
        DispatchQueue.main.async { onLayer(layer) }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}
