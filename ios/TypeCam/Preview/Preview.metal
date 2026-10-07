//
//  Preview.metal
//  TypeCam
//
//  Preview only: zebra and focus peaking are drawn here and never reach the stream.
//

#include <metal_stdlib>
using namespace metal;

struct PreviewUniforms {
    float2 scale;          // aspect-fill scale of the quad in clip space (may exceed ±1)
    int quarterTurns;      // clockwise 90° turns applied to the image
    int padding;
    float zebraThreshold;  // full-range luma; 0 = off
    float peakingEnabled;  // 0 or 1
    float stripePhase;     // advances per frame so zebra stripes crawl
    float padding2;
    float4 peakingColor;
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
                                texture2d<float> chroma [[texture(1)]],
                                constant PreviewUniforms &uniforms [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float y = luma.sample(s, in.uv).r;
    float2 c = chroma.sample(s, in.uv).rg - 0.5;
    // Full-range BT.709 YCbCr → RGB.
    float3 rgb = saturate(float3(y + 1.5748 * c.y,
                                 y - 0.1873 * c.x - 0.4681 * c.y,
                                 y + 1.8556 * c.x));

    if (uniforms.peakingEnabled > 0.5) {
        // Sobel on luma at the source's texel spacing: strong edges only appear where the image is sharp.
        float2 texel = 1.0 / float2(luma.get_width(), luma.get_height());
        float tl = luma.sample(s, in.uv + texel * float2(-1, -1)).r;
        float t  = luma.sample(s, in.uv + texel * float2( 0, -1)).r;
        float tr = luma.sample(s, in.uv + texel * float2( 1, -1)).r;
        float l  = luma.sample(s, in.uv + texel * float2(-1,  0)).r;
        float r  = luma.sample(s, in.uv + texel * float2( 1,  0)).r;
        float bl = luma.sample(s, in.uv + texel * float2(-1,  1)).r;
        float b  = luma.sample(s, in.uv + texel * float2( 0,  1)).r;
        float br = luma.sample(s, in.uv + texel * float2( 1,  1)).r;
        float gx = (tr + 2.0 * r + br) - (tl + 2.0 * l + bl);
        float gy = (bl + 2.0 * b + br) - (tl + 2.0 * t + tr);
        float edge = smoothstep(0.22, 0.4, length(float2(gx, gy)));
        rgb = mix(rgb, uniforms.peakingColor.rgb, edge);
    }

    if (uniforms.zebraThreshold > 0.0 && y >= uniforms.zebraThreshold) {
        // Diagonal stripes in screen space, 6 px on / 6 px off.
        float band = fmod(in.position.x + in.position.y + uniforms.stripePhase, 12.0);
        if (band < 6.0) {
            rgb = mix(rgb, float3(0.0), 0.65);
        }
    }
    return float4(rgb, 1.0);
}
