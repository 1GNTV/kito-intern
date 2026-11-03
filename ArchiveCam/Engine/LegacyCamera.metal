#include <metal_stdlib>
using namespace metal;

// All coefficients here are experimental; they are not camera-specific measurements.
struct FilterUniforms {
    float saturation;
    float contrast;
    float warmth;
    float sensorNoise;
    float opticalSoftness;
    float highlightBloom;
    float chromaMisregistration;
    float cornerFalloff;
    float timeSeconds;
    float seed;
    uint useTemporalFields;
    uint reserved;
};

float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}

float2 cropToAspect(float2 uv, float sourceAspect, float targetAspect) {
    if (sourceAspect > targetAspect) {
        float factor = targetAspect / sourceAspect;
        uv.x = (uv.x - 0.5) * factor + 0.5;
    } else {
        float factor = sourceAspect / targetAspect;
        uv.y = (uv.y - 0.5) * factor + 0.5;
    }
    return uv;
}

kernel void retroKernel(
    texture2d<float, access::sample> first [[texture(0)]],
    texture2d<float, access::sample> second [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant FilterUniforms &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;

    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 dstSize = float2(output.get_width(), output.get_height());
    float2 srcSize = float2(first.get_width(), first.get_height());
    float2 screenUV = (float2(gid) + 0.5) / dstSize;
    float2 uv = cropToAspect(screenUV, srcSize.x/srcSize.y, dstSize.x/dstSize.y);

    // When two adjacent capture instants exist, alternate scan lines from
    // those two samples. A single-frame fallback never falsely claims 50i.
    bool secondField = p.useTemporalFields != 0 && (gid.y & 1u) == 1u;
    float3 rgb = secondField ? second.sample(s, uv).rgb : first.sample(s, uv).rgb;

    float edge = clamp(length((screenUV - 0.5) * 1.5), 0.0, 1.0);
    float2 step = 1.0 / srcSize;
    float softness = p.opticalSoftness * (0.3 + edge * 0.7);
    float2 dx = float2(step.x * (1.0 + softness * 2.0), 0.0);
    float2 dy = float2(0.0, step.y * (1.0 + softness * 2.0));

    float3 neighbors = (
       (secondField ? second.sample(s, uv + dx).rgb : first.sample(s, uv + dx).rgb) +
       (secondField ? second.sample(s, uv - dx).rgb : first.sample(s, uv - dx).rgb) +
       (secondField ? second.sample(s, uv + dy).rgb : first.sample(s, uv + dy).rgb) +
       (secondField ? second.sample(s, uv - dy).rgb : first.sample(s, uv - dy).rgb)
    ) * 0.25;

    rgb = mix(rgb, neighbors, clamp(softness * 0.48, 0.0, 0.45));

    // Modest off-axis channel misregistration, correlated with distance to center.
    float2 radial = (screenUV - 0.5) * step * p.chromaMisregistration * 8.0;
    rgb.r = mix(rgb.r, (secondField ? second.sample(s, uv + radial).r : first.sample(s, uv + radial).r), 0.40);
    rgb.b = mix(rgb.b, (secondField ? second.sample(s, uv - radial).b : first.sample(s, uv - radial).b), 0.40);

    rgb = max(rgb, 0.0);
    rgb = (rgb - 0.5) * p.contrast + 0.5;
    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = mix(float3(luma), rgb, p.saturation);
    rgb.r += p.warmth;
    rgb.b -= p.warmth;

    // Bright-source halo, not an arbitrary full-screen "light leak".
    float3 around = max(
        (secondField ? second.sample(s, uv + dx * 2.4).rgb : first.sample(s, uv + dx * 2.4).rgb),
        (secondField ? second.sample(s, uv - dy * 2.4).rgb : first.sample(s, uv - dy * 2.4).rgb)
    );
    float bright = max(max(around.r, around.g), around.b);
    rgb += smoothstep(0.82, 1.0, bright) * p.highlightBloom * 0.10;

    // Post-processing approximation: noise rises in shadows, and chroma
    // noise is partially decorrelated. We cannot reconstruct pre-ISP electrons.
    float dark = 1.0 - clamp(luma, 0.0, 1.0);
    float noise = p.sensorNoise * (0.38 + dark * 1.50);
    float2 noiseSeed = float2(gid) + p.seed + floor(p.timeSeconds * 51.0);
    float lumNoise = (hash21(noiseSeed) - 0.5) * noise;
    float chromaR = (hash21(noiseSeed + 41.2) - 0.5) * noise * 0.72;
    float chromaB = (hash21(noiseSeed + 89.1) - 0.5) * noise * 0.91;
    rgb += float3(lumNoise + chromaR, lumNoise, lumNoise + chromaB);

    float falloff = 1.0 - p.cornerFalloff * smoothstep(0.15, 0.90, edge);
    rgb *= falloff;
    output.write(float4(clamp(rgb, 0.0, 1.0), 1.0), gid);
}

struct FullscreenVertex {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenVertex fullscreenVertex(uint id [[vertex_id]]) {
    const float2 points[6] = {
        {-1.0, -1.0}, { 1.0, -1.0}, {-1.0,  1.0},
        {-1.0,  1.0}, { 1.0, -1.0}, { 1.0,  1.0}
    };
    FullscreenVertex v;
    float2 xy = points[id];
    v.position = float4(xy, 0.0, 1.0);
    v.uv = float2((xy.x + 1.0) * 0.5, (1.0 - xy.y) * 0.5);
    return v;
}

fragment float4 fullscreenFragment(
    FullscreenVertex in [[stage_in]],
    texture2d<float> frame [[texture(0)]]
) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    return frame.sample(s, in.uv);
}
