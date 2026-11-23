#include <metal_stdlib>
using namespace metal;

struct FilterUniforms {
    float4 sensor, optics, tone, red, green, blue, encoding, timing;
};
constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

float hash21(float2 p) {
    p = fract(p * float2(123.34, 345.45));
    p += dot(p, p + 34.345);
    return fract(p.x * p.y);
}
float normalNoise(float2 p) {
    return sqrt(-2.0 * log(max(hash21(p), 0.0001))) *
           cos(6.2831853 * hash21(p + 37.1));
}
float2 cropToAspect(float2 uv, float sourceAspect, float targetAspect) {
    if (sourceAspect > targetAspect) uv.x = (uv.x - 0.5) * targetAspect/sourceAspect + 0.5;
    else uv.y = (uv.y - 0.5) * sourceAspect/targetAspect + 0.5;
    return uv;
}
// Integrate over the output sensor footprint: downsampling happens BEFORE noise,
// sharpening and colour encoding. V1 only resampled the iPhone's sharp image.
float3 sensorSample(texture2d<float, access::sample> source, float2 uv, float2 footprint) {
    float2 d = footprint * 0.28;
    return (source.sample(linearSampler, uv + d).rgb +
            source.sample(linearSampler, uv - d).rgb +
            source.sample(linearSampler, uv + float2(d.x, -d.y)).rgb +
            source.sample(linearSampler, uv + float2(-d.x, d.y)).rgb) * 0.25;
}
float3 cameraResponse(float3 rgb, constant FilterUniforms &p) {
    // Input has already passed through the iPhone ISP. Approximate linear light;
    // these matrices describe a tuned output response, not measured CCD spectral data.
    rgb = pow(max(rgb, 0.0), float3(2.2));
    rgb = max(float3(dot(p.red.xyz, rgb), dot(p.green.xyz, rgb),
                     dot(p.blue.xyz, rgb)), 0.0);
    rgb = max(rgb * p.tone.y - p.tone.x, 0.0);
    rgb = min(rgb, p.tone.w) / p.tone.w;
    return pow(rgb, float3(p.tone.z / 2.2));
}
kernel void retroKernel(
    texture2d<float, access::sample> first [[texture(0)]],
    texture2d<float, access::sample> second [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant FilterUniforms &p [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 size = float2(output.get_width(), output.get_height());
    float2 uv0 = (float2(gid) + 0.5) / size;
    float sourceAspect = float(first.get_width()) / first.get_height();
    float targetAspect = size.x/size.y;
    float2 uv = cropToAspect(uv0, sourceAspect, targetAspect);
    float2 footprint = (cropToAspect(uv0 + 1.0/size, sourceAspect, targetAspect) - uv);
    // All optical taps use the SAME instant for a given output field.
    bool field = p.timing.z > 0.5 && (gid.y & 1u) != 0;
    bool camcorder = p.timing.w > 0.5;
    // SD luma is band limited before aperture correction. Vertical averaging
    // also suppresses twitter from fine horizontal lines on a field display.
    float2 dx = float2(footprint.x * (camcorder ? 1.35 : 1.0), 0);
    float2 dy = float2(0, footprint.y);
    float3 centre, horizontal, vertical;
    if (field) {
        centre = sensorSample(second, uv, footprint);
        horizontal = 0.5 * (sensorSample(second, uv+dx, footprint) + sensorSample(second, uv-dx, footprint));
        vertical = 0.5 * (sensorSample(second, uv+dy, footprint) + sensorSample(second, uv-dy, footprint));
    } else {
        centre = sensorSample(first, uv, footprint);
        horizontal = 0.5 * (sensorSample(first, uv+dx, footprint) + sensorSample(first, uv-dx, footprint));
        vertical = 0.5 * (sensorSample(first, uv+dy, footprint) + sensorSample(first, uv-dy, footprint));
    }
    float3 surround = mix(horizontal, vertical, camcorder ? 0.38 : 0.50);
    float radius = length((uv0 - 0.5)*1.4142);
    float3 rgb = mix(centre, surround, min(0.8, p.optics.x * (0.55 + radius*0.45)));
    rgb += clamp(centre-surround, -0.16, 0.16)*p.optics.y;
    float2 radial = (uv0-0.5)*footprint*p.optics.z;
    rgb.r = mix(rgb.r, field ? second.sample(linearSampler,uv+radial).r : first.sample(linearSampler,uv+radial).r, 0.25);
    rgb.b = mix(rgb.b, field ? second.sample(linearSampler,uv-radial).b : first.sample(linearSampler,uv-radial).b, 0.25);
    rgb *= 1.0-p.optics.w*radius*radius;
    // Charge from bright neighbours spreads close to a light/dark boundary.
    // A uniform bright sky has no local excess to spill.
    float3 spill = max(surround - max(centre, float3(0.72)), 0.0);
    rgb += spill * p.encoding.w;
    rgb = cameraResponse(rgb,p);
    float y = dot(rgb,float3(0.299,0.587,0.114));
    // Sample colour at a reduced lattice, preserving full luminance resolution.
    float2 cell = (floor(float2(gid)/p.encoding.xy)*p.encoding.xy + p.encoding.xy*0.5)/size;
    float2 cuv = cropToAspect(cell,sourceAspect,targetAspect);
    float2 chromaFootprint = footprint * p.encoding.xy;
    float3 chromaSample = field ? sensorSample(second,cuv,chromaFootprint)
                                : sensorSample(first,cuv,chromaFootprint);
    if (camcorder) {
        // Horizontal colour bandwidth is lower than luma. Model the mild
        // phase delay in the colour path before forming colour differences.
        float2 previousCell = cuv - float2(chromaFootprint.x, 0);
        float3 previous = field ? sensorSample(second,previousCell,chromaFootprint)
                                : sensorSample(first,previousCell,chromaFootprint);
        chromaSample = mix(chromaSample, previous, 0.30);
    }
    float3 low = cameraResponse(chromaSample,p);
    float lowY = dot(low,float3(0.299,0.587,0.114));
    float2 cbcr = float2((low.b-lowY)*0.564,(low.r-lowY)*0.713);
    float gain = sqrt(clamp(p.timing.y,1.0,16.0));
    float darkness = 0.3 + 1.4*pow(1.0-clamp(y,0.0,1.0),2.0);
    float2 seed = float2(gid)+p.timing.x;
    y += normalNoise(seed)*p.sensor.z*gain*darkness;
    float2 chromaSeed = floor(float2(gid)/p.encoding.xy)+p.timing.x;
    cbcr += float2(normalNoise(chromaSeed+83),normalNoise(chromaSeed+197))*p.sensor.w*gain*darkness;
    float levels = p.encoding.z;
    y = round(y*levels)/levels;
    cbcr = round(cbcr*levels)/levels;
    rgb = float3(y+1.403*cbcr.y,y-0.344*cbcr.x-0.714*cbcr.y,y+1.773*cbcr.x);
    output.write(float4(clamp(rgb,0.0,1.0),1.0),gid);
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
