//
//  Preview.metal
//  TypeCam
//

#include <metal_stdlib>
using namespace metal;

struct PreviewUniforms {
    float2 scale;      // aspect-fill scale of the quad in clip space (may exceed ±1)
    int quarterTurns;  // clockwise 90° turns applied to the image
    int padding;
};

struct PreviewVertex {
    float4 position [[position]];
    float2 uv;
};

vertex PreviewVertex previewVertex(uint vid [[vertex_id]],
                                   constant PreviewUniforms &uniforms [[buffer(0)]]) {
    // Triangle strip covering clip space: (-1,-1) (1,-1) (-1,1) (1,1).
    float2 position = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? 1.0 : -1.0);
    // Screen-space UV with a top-left origin.
    float2 uv = float2((position.x + 1.0) * 0.5, 1.0 - (position.y + 1.0) * 0.5);
    // Rotating the image clockwise means sampling at counter-rotated coordinates.
    for (int i = 0; i < uniforms.quarterTurns; i++) {
        uv = float2(uv.y, 1.0 - uv.x);
    }
    PreviewVertex out;
    out.position = float4(position * uniforms.scale, 0.0, 1.0);
    out.uv = uv;
    return out;
}

fragment float4 previewFragment(PreviewVertex in [[stage_in]],
                                texture2d<float> luma [[texture(0)]],
                                texture2d<float> chroma [[texture(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y = luma.sample(s, in.uv).r;
    float2 c = chroma.sample(s, in.uv).rg - 0.5;
    // Full-range BT.709 YCbCr → RGB.
    float3 rgb = float3(y + 1.5748 * c.y,
                        y - 0.1873 * c.x - 0.4681 * c.y,
                        y + 1.8556 * c.x);
    return float4(saturate(rgb), 1.0);
}
