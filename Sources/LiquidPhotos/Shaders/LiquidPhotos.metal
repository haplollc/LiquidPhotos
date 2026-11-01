//
//  LiquidPhotos.metal
//  LiquidPhotos
//
//  One full-screen pass. Each pixel finds its place in the photo frame, then
//  in anchor space (see LiquidCamera.swift), follows the pair's flow back to
//  where each photo's content comes from, and dissolves between the two in
//  soft, noisy patches. At rest it is a single texture read.
//
//  Uniforms are float4 slots so the Swift side needs no bridging header:
//    u[0] viewSize.xy, unit (pixels per stage width), halfHeight
//    u[1] frameCenter.xy (pixels), cornerRadius (widths), morph
//    u[2] center.xy, scale, blur (widths)
//    u[3] anchorA.xy, sizeA, heightA
//    u[4] anchorB.xy, sizeB, heightB
//    u[5] flowOrigin.xy, flowSize.xy
//    u[6] flowGain, flowSwap, hasB, opacity
//    u[7] seed, spread, texWidthA, texWidthB
//    u[8] camera velocity.xy (widths/s), zoom rate (log scale/s), exposure (s)
//

#include <metal_stdlib>
using namespace metal;

struct LiquidVertexOut {
    float4 position [[position]];
};

vertex LiquidVertexOut liquidVertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    LiquidVertexOut out;
    out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    return out;
}

constexpr sampler photoSampler(address::mirrored_repeat, filter::linear, mip_filter::linear);
constexpr sampler flowSampler(address::clamp_to_edge, filter::linear);

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 s = f * f * (3.0 - 2.0 * f);
    float a = hash21(i), b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1)), d = hash21(i + float2(1, 1));
    return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
}

/// Defocus and motion blur in one 12-tap kernel: a golden-angle disc of
/// `radius`, sheared along `streak` (how far the content moved while the
/// virtual shutter was open). Both in photo widths; `height` is the photo's
/// height in widths. Sharp content is a single read.
static half4 samplePhoto(texture2d<half> tex, float2 uv, float radius, float2 streak, float height, float texWidth) {
    float rpx = radius * texWidth;
    float spx = length(streak) * texWidth;
    if (rpx < 0.6 && spx < 1.0) {
        return tex.sample(photoSampler, uv);
    }
    float lod = max(0.0, log2(max(rpx / 2.5, spx / 10.0)));
    half4 sum = half4(0.0);
    for (int i = 0; i < 12; i++) {
        float r = radius * sqrt((float(i) + 0.5) / 12.0);
        float a = float(i) * 2.39996323;
        // A low-discrepancy position along the streak, decorrelated from the disc.
        float along = fract(float(i) * 0.618034 + 0.5) - 0.5;
        float2 o = float2(cos(a), sin(a)) * r + streak * along;
        sum += tex.sample(photoSampler, uv + float2(o.x, o.y / height), level(lod));
    }
    return sum / 12.0h;
}

fragment half4 liquidFragment(
    LiquidVertexOut in [[stage_in]],
    constant float4 *u [[buffer(0)]],
    texture2d<half> texA [[texture(0)]],
    texture2d<half> texB [[texture(1)]],
    texture2d<float> flow [[texture(2)]]
) {
    float unit = u[0].z;
    float halfHeight = u[0].w;
    float2 p = (in.position.xy - u[1].xy) / unit;

    // The frame: full width, `halfHeight` above and below its centre.
    float radius = u[1].z;
    float2 q = abs(p) - float2(0.5, halfHeight) + radius;
    float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    float coverage = saturate(0.5 - dist * unit) * u[6].w;
    if (coverage <= 0.0) {
        return half4(0.0);
    }

    float morph = u[1].w;
    float2 eta = (p - u[2].xy) / u[2].z;
    float blur = u[2].w;
    // Where this bit of picture is heading: the camera's glide plus its zoom.
    float2 streak = (u[8].xy + u[8].z * (p - u[2].xy)) * u[8].w;
    bool hasB = u[6].z > 0.5;

    float2 flowAB = float2(0.0), flowBA = float2(0.0);
    if (hasB && u[6].x > 0.0) {
        float4 f = flow.sample(flowSampler, (eta - u[5].xy) / u[5].zw);
        f = u[6].y > 0.5 ? f.zwxy : f;
        flowAB = f.xy * u[6].x;
        flowBA = f.zw * u[6].x;
    }

    // Each region crosses over at its own moment, so the next photo seeps in
    // in patches instead of fading evenly.
    float w = 0.0;
    if (hasB) {
        float2 np = eta * 0.6 + u[7].x;
        float n = 0.65 * valueNoise(np) + 0.35 * valueNoise(np * 2.3 + 17.0);
        float spread = u[7].y;
        w = smoothstep(0.0, 1.0, morph * (1.0 + spread) - spread * n);
    }

    half4 color = half4(0.0);
    if (w < 0.999) {
        float2 e = eta - morph * flowAB;
        float2 qa = u[3].xy + e * u[3].z;
        float2 uv = float2(qa.x + 0.5, qa.y / u[3].w + 0.5);
        float k = u[3].z / u[2].z;
        color = samplePhoto(texA, uv, blur * k, streak * k, u[3].w, u[7].z) * half(1.0 - w);
    }
    if (w > 0.001) {
        float2 e = eta - (1.0 - morph) * flowBA;
        float2 qb = u[4].xy + e * u[4].z;
        float2 uv = float2(qb.x + 0.5, qb.y / u[4].w + 0.5);
        float k = u[4].z / u[2].z;
        color += samplePhoto(texB, uv, blur * k, streak * k, u[4].w, u[7].w) * half(w);
    }
    color.a = 1.0h;
    return color * half(coverage);
}
