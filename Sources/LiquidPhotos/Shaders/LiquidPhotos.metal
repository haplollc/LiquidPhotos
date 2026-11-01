//
//  LiquidPhotos.metal
//  LiquidPhotos
//
//  One full-screen pass. Each pixel of the photo frame is mapped by the
//  camera into the first photo's world (see LiquidMorph.swift), follows
//  the pair's flow back to where that bit of picture sits in each photo,
//  and blends the two, trusting each photo less where its pixel has no
//  counterpart in the other (an arm that moved, a side that came into view).
//  At rest it is a single texture read.
//
//  Uniforms are float4 slots so the Swift side needs no bridging header:
//    u[0] viewSize.xy, unit (pixels per stage width), halfHeight
//    u[1] frameCenter.xy (pixels), cornerRadius (widths), blend
//    u[2] view row 0, motion        (frame unit square → world)
//    u[3] view row 1, heightA
//    u[4] view row 2, heightB
//    u[5] toB row 0, hasB           (world → second photo)
//    u[6] toB row 1, flowGain
//    u[7] toB row 2, opacity
//    u[8] flowOrigin.xy, flowSize.xy (world)
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

constexpr sampler photoSampler(address::clamp_to_edge, filter::linear, mip_filter::linear);
constexpr sampler flowSampler(address::clamp_to_edge, filter::linear);

/// 1 inside the unit square, easing to 0 just outside it.
static float inside(float2 uv) {
    float2 e = smoothstep(-0.004, 0.004, uv) * smoothstep(-0.004, 0.004, 1.0 - uv);
    return e.x * e.y;
}

fragment half4 liquidFragment(
    LiquidVertexOut in [[stage_in]],
    constant float4 *u [[buffer(0)]],
    texture2d<half> texA [[texture(0)]],
    texture2d<half> texB [[texture(1)]],
    texture2d<float> flowAB [[texture(2)]],
    texture2d<float> flowBA [[texture(3)]]
) {
    float unit = u[0].z;
    float halfHeight = u[0].w;
    float2 p = (in.position.xy - u[1].xy) / unit;

    // The frame: full width, `halfHeight` above and below its centre.
    float radius = u[1].z;
    float2 q = abs(p) - float2(0.5, halfHeight) + radius;
    float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    float coverage = saturate(0.5 - dist * unit) * u[7].w;
    if (coverage <= 0.0) {
        return half4(0.0);
    }

    // Camera: frame unit square → world.
    float3 f = float3(p.x + 0.5, (p.y + halfHeight) / (2.0 * halfHeight), 1.0);
    float3 wh = float3(dot(u[2].xyz, f), dot(u[3].xyz, f), dot(u[4].xyz, f));
    float2 world = wh.xy / wh.z;
    float heightA = u[3].w, heightB = u[4].w;

    if (u[5].w < 0.5) {
        half4 color = texA.sample(photoSampler, float2(world.x, world.y / heightA));
        color.a = 1.0h;
        return color * half(coverage);
    }

    float motion = u[2].w;
    float blend = u[1].w;
    float gain = u[6].w;
    float4 fa = float4(0.0, 0.0, 1.0, 0.0), fb = float4(0.0, 0.0, 1.0, 0.0);
    if (gain > 0.0) {
        float2 fuv = (world - u[8].xy) / u[8].zw;
        fa = flowAB.sample(flowSampler, fuv);
        fb = flowBA.sample(flowSampler, fuv);
    }

    // Each photo's pixels travel along the flow: the first's from where they
    // were, the second's toward where they will be.
    float2 pa = world - motion * gain * fa.xy;
    float2 pb = world - (1.0 - motion) * gain * fb.xy;
    float2 uvA = float2(pa.x, pa.y / heightA);
    float3 qb = float3(dot(u[5].xyz, float3(pb, 1.0)), dot(u[6].xyz, float3(pb, 1.0)), dot(u[7].xyz, float3(pb, 1.0)));
    float2 uvB = float2(qb.x / qb.z, qb.y / qb.z / heightB);

    float validA = inside(uvA), validB = inside(uvB);
    float wa = (1.0 - blend) * validA * mix(1.0, fa.z, 0.85) + 1e-4 * validA;
    float wb = blend * validB * mix(1.0, fb.z, 0.85) + 1e-4 * validB;
    if (wa + wb < 1e-5) {
        wa = 1.0 - blend;
        wb = blend;
    }
    half4 color = (texA.sample(photoSampler, uvA) * half(wa) + texB.sample(photoSampler, uvB) * half(wb)) / half(wa + wb);
    color.a = 1.0h;
    return color * half(coverage);
}
