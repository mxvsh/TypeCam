//
//  PreviewGeometry.swift
//  TypeCam
//

import CoreGraphics

/// Inverse of the preview transform in `Preview.metal`: maps a point on screen to the captured
/// frame, then to the device's point-of-interest space (sensor-native, unmirrored, 0…1).
nonisolated enum PreviewGeometry {
    /// Where the full captured frame lands on screen (aspect-fill, so it may extend past the edges).
    static func frameRect(viewSize: CGSize, bufferSize: CGSize, rotation: Int) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0, bufferSize.width > 0, bufferSize.height > 0 else {
            return CGRect(origin: .zero, size: viewSize)
        }
        var width = bufferSize.width, height = bufferSize.height
        if (((rotation / 90) % 4 + 4) % 4) % 2 == 1 { swap(&width, &height) }
        let scale = max(viewSize.width / width, viewSize.height / height)
        let size = CGSize(width: width * scale, height: height * scale)
        return CGRect(x: (viewSize.width - size.width) / 2, y: (viewSize.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    /// Returns nil when the point lies outside the visible image.
    static func devicePoint(
        viewPoint: CGPoint,
        viewSize: CGSize,
        bufferSize: CGSize,
        rotation: Int,
        mirrored: Bool
    ) -> CGPoint? {
        guard viewSize.width > 0, viewSize.height > 0, bufferSize.width > 0, bufferSize.height > 0 else { return nil }
        let quarterTurns = ((rotation / 90) % 4 + 4) % 4

        // Same aspect-fill scale as PreviewRenderer.
        var width = bufferSize.width, height = bufferSize.height
        if quarterTurns % 2 == 1 { swap(&width, &height) }
        let content = width / height
        let view = viewSize.width / viewSize.height
        let scale = content > view ? CGPoint(x: content / view, y: 1) : CGPoint(x: 1, y: view / content)

        // Screen → clip space → quad space.
        let clipX = viewPoint.x / viewSize.width * 2 - 1
        let clipY = 1 - viewPoint.y / viewSize.height * 2
        let quadX = clipX / scale.x
        let quadY = clipY / scale.y
        guard abs(quadX) <= 1, abs(quadY) <= 1 else { return nil }

        // Quad → texture UV, applying the shader's counter-rotation.
        var uv = CGPoint(x: (quadX + 1) / 2, y: 1 - (quadY + 1) / 2)
        for _ in 0..<quarterTurns {
            uv = CGPoint(x: uv.y, y: 1 - uv.x)
        }
        // A mirrored buffer's x runs opposite to the sensor's.
        if mirrored { uv.x = 1 - uv.x }
        return uv
    }
}
