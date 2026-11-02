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

// MARK: - The warp mesh
//
// Drawn over the plain cross-fade while two related photos change places.
// Each vertex glides from where its bit of picture is in the first photo to
// where it is in the second; the triangles between them stay nearly rigid,
// so regions move, scale and turn as solid pieces. Colours shift with them:
// the first photo's pixels are re-tinted toward the second's light while
// the second's start out tinted like the first. Where the two then agree,
// they hand over quickly; where they still differ (something genuinely
// appears or leaves) they cross-fade slowly instead of being pulled around.
//
//   m[0] viewSize.xy, unit, halfHeight
//   m[1] frameCenter.xy, cornerRadius, blend
//   m[2] quickBlend, motion, opacity, strength
//   m[3..5] world → frame unit square, rows

struct LiquidMeshVertex {
    float2 worldA;
    float2 worldB;
    float2 uvA;
    float2 uvB;
    float4 gain;    // rgb gain; w = match confidence
    float4 offset;  // rgb offset
};

struct LiquidMeshOut {
    float4 position [[position]];
    float2 uvA;
    float2 uvB;
    float4 gain;
    float3 offset;
};

vertex LiquidMeshOut liquidMeshVertex(
    uint vid [[vertex_id]],
    constant float4 *m [[buffer(0)]],
    constant LiquidMeshVertex *vertices [[buffer(1)]]
) {
    LiquidMeshVertex v = vertices[vid];
    float motion = m[2].y * m[2].w;
    float2 world = mix(v.worldA, v.worldB, motion);
    float3 h = float3(dot(m[3].xyz, float3(world, 1.0)), dot(m[4].xyz, float3(world, 1.0)), dot(m[5].xyz, float3(world, 1.0)));
    float2 unitSquare = h.xy / h.z;
    float2 stage = float2(unitSquare.x - 0.5, (unitSquare.y - 0.5) * 2.0 * m[0].w);
    float2 pixel = m[1].xy + stage * m[0].z;
    LiquidMeshOut out;
    out.position = float4(pixel.x / m[0].x * 2.0 - 1.0, 1.0 - pixel.y / m[0].y * 2.0, 0.0, 1.0);
    // Where nothing matched, the pieces only ride the camera.
    out.uvA = v.uvA;
    out.uvB = v.uvB;
    out.gain = v.gain;
    out.offset = v.offset.rgb;
    return out;
}

fragment half4 liquidMeshFragment(
    LiquidMeshOut in [[stage_in]],
    constant float4 *m [[buffer(0)]],
    texture2d<half> texA [[texture(0)]],
    texture2d<half> texB [[texture(1)]]
) {
    float unit = m[0].z, halfHeight = m[0].w, radius = m[1].z;
    float2 p = (in.position.xy - m[1].xy) / unit;
    float2 q = abs(p) - float2(0.5, halfHeight) + radius;
    float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    float coverage = saturate(0.5 - dist * unit) * m[2].z;
    float validA = inside(in.uvA), validB = inside(in.uvB);
    if (coverage <= 0.0 || validA + validB < 0.01) {
        discard_fragment();
    }

    float motion = m[2].y;
    float3 gain = in.gain.rgb, offset = in.offset;
    float3 a = float3(texA.sample(photoSampler, in.uvA).rgb);
    float3 b = float3(texB.sample(photoSampler, in.uvB).rgb);
    // The first photo takes on the second's colours as it goes; the second
    // starts out in the first's.
    float3 aTinted = a * mix(float3(1.0), gain, motion) + offset * motion;
    float3 bTinted = (b - offset * (1.0 - motion)) / max(mix(gain, float3(1.0), motion), float3(0.05));
    float3 d = abs(aTinted - bTinted);
    float disagreement = max(d.r, max(d.g, d.b));

    float matched = in.gain.w * (1.0 - smoothstep(0.06, 0.22, disagreement));
    float w = mix(m[1].w, m[2].x, matched);
    float wa = (1.0 - w) * validA, wb = w * validB;
    if (wa + wb < 1e-5) {
        discard_fragment();
    }
    float3 color = (aTinted * wa + bTinted * wb) / (wa + wb);
    // Only where the mesh has something to add over the plain cross-fade.
    float alpha = coverage * saturate(in.gain.w * 4.0);
    return half4(half3(color) * half(alpha), half(alpha));
}
