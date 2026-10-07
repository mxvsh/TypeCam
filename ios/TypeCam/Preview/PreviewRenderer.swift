//
//  PreviewRenderer.swift
//  TypeCam
//

import CoreVideo
import MetalKit

/// Must match `PreviewUniforms` in Preview.metal (48 bytes).
private struct PreviewUniforms {
    var scale: SIMD2<Float>
    var quarterTurns: Int32
    var padding: Int32 = 0
    var zebraThreshold: Float = 0
    var peakingEnabled: Float = 0
    var stripePhase: Float = 0
    var padding2: Float = 0
    var peakingColor: SIMD4<Float> = .zero
}

/// Draws the newest captured NV12 frame aspect-fill into an `MTKView` (edges past the screen are cropped). Rendering the same
/// buffers the encoder gets keeps the preview identical to the stream; overlays (M6) hook in here.
final class PreviewRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let mailbox: FrameMailbox

    private var currentBuffer: CVPixelBuffer?
    private var currentRotation = 0
    private var currentOverlays = PreviewOverlays()
    private var needsRedraw = false
    private var stripePhase: Float = 0

    init?(mailbox: FrameMailbox) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "previewVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "previewFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }

        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.textureCache = cache
        self.mailbox = mailbox
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        needsRedraw = true
    }

    func draw(in view: MTKView) {
        let rotation = mailbox.previewRotation
        let overlays = mailbox.overlays
        if let fresh = mailbox.take() {
            currentBuffer = fresh
        } else if !needsRedraw && rotation == currentRotation && overlays == currentOverlays {
            return
        }
        needsRedraw = false
        currentRotation = rotation
        currentOverlays = overlays
        stripePhase = (stripePhase + 0.5).truncatingRemainder(dividingBy: 12)

        guard let buffer = currentBuffer,
              let luma = makeTexture(buffer, plane: 0, format: .r8Unorm),
              let chroma = makeTexture(buffer, plane: 1, format: .rg8Unorm),
              let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commands = commandQueue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        let quarterTurns = ((rotation / 90) % 4 + 4) % 4
        var uniforms = PreviewUniforms(
            scale: aspectFillScale(buffer: buffer, quarterTurns: quarterTurns, drawableSize: view.drawableSize),
            quarterTurns: Int32(quarterTurns),
            zebraThreshold: overlays.zebraThreshold,
            peakingEnabled: overlays.peakingColor == nil ? 0 : 1,
            stripePhase: stripePhase,
            peakingColor: overlays.peakingColor.map { SIMD4($0, 1) } ?? .zero
        )

        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<PreviewUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<PreviewUniforms>.stride, index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(luma), index: 0)
        encoder.setFragmentTexture(CVMetalTextureGetTexture(chroma), index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        // Keep the CV textures (and their IOSurface) alive until the GPU is done.
        commands.addCompletedHandler { _ in withExtendedLifetime((luma, chroma)) {} }
        commands.present(drawable)
        commands.commit()
    }

    private func makeTexture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> CVMetalTexture? {
        var texture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, buffer, nil, format,
            CVPixelBufferGetWidthOfPlane(buffer, plane),
            CVPixelBufferGetHeightOfPlane(buffer, plane),
            plane, &texture
        )
        return texture
    }

    private func aspectFillScale(buffer: CVPixelBuffer, quarterTurns: Int, drawableSize: CGSize) -> SIMD2<Float> {
        var width = Float(CVPixelBufferGetWidth(buffer))
        var height = Float(CVPixelBufferGetHeight(buffer))
        if quarterTurns % 2 == 1 { swap(&width, &height) }
        guard width > 0, height > 0, drawableSize.width > 0, drawableSize.height > 0 else { return [1, 1] }
        let content = width / height
        let view = Float(drawableSize.width / drawableSize.height)
        return content > view ? [content / view, 1] : [1, view / content]
    }
}
