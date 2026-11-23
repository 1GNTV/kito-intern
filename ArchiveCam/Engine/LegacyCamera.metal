#include <metal_stdlib>
using namespace metal;

struct FilterUniforms {
    float4 sensor, optics, tone, red, green, blue, encoding, timing;
};
constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);

// The compact measures only the part of the sensor visible in the 4:3 finder.
// A single bright lamp occupies too little of this grid to put the camera in daylight.
kernel void compactMeter(texture2d<float, access::read> source [[texture(0)]],
                         device float2 &result [[buffer(0)]],
                         uint lane [[thread_index_in_threadgroup]]) {
    float2 size = float2(source.get_width(), source.get_height());
    float2 uv = (float2(lane % 16u, lane / 16u) + 0.5) / 16.0;
    float scale = (size.x / size.y) / (4.0 / 3.0);
    uv = (uv - 0.5) * float2(min(1.0, 1.0/scale), min(1.0, scale)) + 0.5;
    float y = dot(source.read(min(uint2(uv * size), uint2(size) - 1u)).rgb,
                  float3(0.299, 0.587, 0.114));
    threadgroup float2 samples[256];
    samples[lane] = float2(smoothstep(0.44, 0.75, y), smoothstep(0.12, 0.42, y));
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = 128u; stride > 0u; stride >>= 1u) {
        if (lane < stride) samples[lane] += samples[lane + stride];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lane == 0u) {
        float2 mean = samples[0] / 256.0;
        result.x = smoothstep(0.045, 0.23, mean.x) * smoothstep(0.24, 0.50, mean.y);
        result.y = 1.0 - smoothstep(0.10, 0.48, mean.y);
    }
}

float hash21(float2 p) {
    // Integer mixing retains per-pixel variation even after a long capture.
    uint2 coord = uint2(p);
    uint bits = coord.x * 0x85ebca6bu + coord.y * 0xc2b2ae35u + 0x9e3779b9u;
    bits ^= bits >> 16;
    bits *= 0x7feb352du;
    bits ^= bits >> 15;
    return float(bits >> 8) / 16777216.0;
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
    // Compress only the brightest part of the response. This leaves a band
    // of detail between the diffuse highlights and the final sensor clip.
    float3 level = rgb / p.tone.w;
    float3 excess = max(level - 0.67, 0.0);
    rgb = min(min(level, 0.67) + excess / (1.0 + 1.42 * excess), 1.0);
    return pow(rgb, float3(p.tone.z / 2.2));
}
// A neutral grey stays on the grey axis. Mid-strength colours get a gentle
// boost; already vivid colours retain their hue at the edge of the RGB gamut.
float3 cameraColor(float3 rgb, float daylight) {
    rgb = clamp(rgb, 0.0, 1.0);
    float y = dot(rgb, float3(0.299, 0.587, 0.114));
    float3 chroma = rgb - y;
    float high = max(chroma.r, max(chroma.g, chroma.b));
    float low = -min(chroma.r, min(chroma.g, chroma.b));
    float range = high + low;
    float strength = smoothstep(0.015, 0.12, range) * (1.0 - smoothstep(0.42, 0.92, range));
    float warmth = smoothstep(0.0, 0.12, rgb.r - rgb.g) * smoothstep(0.0, 0.09, rgb.g - rgb.b);
    float gain = 1.0 + 0.24 * strength * (1.0 - 0.55 * warmth) * smoothstep(0.035, 0.17, y);
    float tone = 0.010 + 0.98 * y + 0.035 * (4.0 * y * (1.0 - y)) * (2.0 * y - 0.72);
    // Change luminance, protecting hue and keeping the black/white endpoints.
    float shade = smoothstep(0.02, 0.13, y) * (1.0 - smoothstep(0.22, 0.48, y));
    float sun = smoothstep(0.36, 0.78, y) * (1.0 - smoothstep(0.91, 1.0, y));
    tone = clamp(tone + daylight * (0.067 * sun - 0.022 * shade), 0.0, 1.0);
    float room = min((1.0 - tone) / max(high, 0.00001), tone / max(low, 0.00001));
    return clamp(tone + chroma * min(gain, room), 0.0, 1.0);
}
float3 sensorPixel(texture2d<float, access::sample> first,
                   texture2d<float, access::sample> second,
                   constant FilterUniforms &p, float2 scene, uint2 gid, float2 size) {
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
    // Aperture correction follows luminance transitions alone. The dead band
    // leaves flat sky and fine sensor noise out of the sharpening path.
    float edge = dot(centre - surround, float3(0.299, 0.587, 0.114));
    float contour = sign(edge) * min(max(abs(edge) - 0.004, 0.0), 0.09);
    rgb += contour * p.optics.y;
    float2 radial = (uv0-0.5)*footprint*p.optics.z;
    rgb.r = mix(rgb.r, field ? second.sample(linearSampler,uv+radial).r : first.sample(linearSampler,uv+radial).r, 0.25);
    rgb.b = mix(rgb.b, field ? second.sample(linearSampler,uv-radial).b : first.sample(linearSampler,uv-radial).b, 0.25);
    rgb *= 1.0-p.optics.w*radius*radius;
    // Charge from bright neighbours spreads close to a light/dark boundary.
    // A uniform bright sky has no local excess to spill.
    float3 spill = max(surround - max(centre, float3(0.72)), 0.0);
    rgb += spill * (p.encoding.w + 0.16 * scene.y);
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
    // In a dark frame the high-gain colour path is coarser than its daylight path.
    darkness *= 1.0 + 0.55 * scene.y * (1.0 - clamp(y, 0.0, 1.0));
    float2 seed = float2(gid)+p.timing.x;
    y += normalNoise(seed)*p.sensor.z*gain*darkness;
    float2 chromaSeed = floor(float2(gid)/p.encoding.xy)+p.timing.x;
    cbcr += float2(normalNoise(chromaSeed+83),normalNoise(chromaSeed+197))*p.sensor.w*gain*darkness;
    float levels = p.encoding.z;
    y = round(y*levels)/levels;
    cbcr = round(cbcr*levels)/levels;
    rgb = float3(y+1.403*cbcr.y,y-0.344*cbcr.x-0.714*cbcr.y,y+1.773*cbcr.x);
    return cameraColor(rgb, scene.x);
}

// Orthonormal 8-point cosine basis, indexed by frequency then position.
constant float basis[64] = {
    0.35355339f, 0.35355339f, 0.35355339f, 0.35355339f, 0.35355339f, 0.35355339f, 0.35355339f, 0.35355339f,
    0.49039264f, 0.41573481f, 0.27778512f, 0.09754516f, -0.09754516f, -0.27778512f, -0.41573481f, -0.49039264f,
    0.46193977f, 0.19134172f, -0.19134172f, -0.46193977f, -0.46193977f, -0.19134172f, 0.19134172f, 0.46193977f,
    0.41573481f, -0.09754516f, -0.49039264f, -0.27778512f, 0.27778512f, 0.49039264f, 0.09754516f, -0.41573481f,
    0.35355339f, -0.35355339f, -0.35355339f, 0.35355339f, 0.35355339f, -0.35355339f, -0.35355339f, 0.35355339f,
    0.27778512f, -0.49039264f, 0.09754516f, 0.41573481f, -0.41573481f, -0.09754516f, 0.49039264f, -0.27778512f,
    0.19134172f, -0.46193977f, 0.46193977f, -0.19134172f, -0.19134172f, 0.46193977f, -0.46193977f, 0.19134172f,
    0.09754516f, -0.27778512f, 0.41573481f, -0.49039264f, 0.49039264f, -0.41573481f, 0.27778512f, -0.09754516f
};

kernel void retroKernel(
    texture2d<float, access::sample> first [[texture(0)]],
    texture2d<float, access::sample> second [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant FilterUniforms &p [[buffer(0)]],
    constant float2 &scene [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 lane [[thread_position_in_threadgroup]]
) {
    uint2 size = uint2(output.get_width(), output.get_height());
    // Woven PAL frames have two source times. Transform each field separately.
    if (p.timing.z > 0.5) {
        uint phase = (gid.y / 8u) & 1u;
        gid.y = (gid.y / 16u) * 16u + lane.y * 2u + phase;
    }
    float3 rgb = sensorPixel(first, second, p, scene, min(gid, size - 1u), float2(size));
    float y = dot(rgb, float3(0.299, 0.587, 0.114));
    threadgroup float3 a[8][8], b[8][8];
    uint u = lane.x, v = lane.y;
    a[v][u] = 255.0 * float3(y - 0.5, (rgb.b-y)*0.564, (rgb.r-y)*0.713);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float3 row = 0.0;
    for (uint n=0; n<8; ++n) row += basis[u*8+n] * a[v][n];
    b[v][u] = row;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float3 coeff = 0.0;
    for (uint n=0; n<8; ++n) coeff += basis[v*8+n] * b[n][u];

    // Quantise actual coefficients; flat blocks keep their own average and
    // sharp silhouettes retain low-frequency shape plus characteristic ringing.
    float freq = float(u+v);
    float luma = (u+v == 0u) ? 38.0 : 12.0 + 3.5*freq + 0.58*freq*freq;
    float chroma = (u+v == 0u) ? 44.0 : min(210.0, 21.0 + 11.0*freq + 1.2*freq*freq);
    float3 step = float3(luma, chroma, chroma) * p.red.w;
    a[v][u] = round(coeff / step) * step;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float3 column = 0.0;
    for (uint k=0; k<8; ++k) column += basis[k*8+v] * a[k][u];
    b[v][u] = column;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float3 decoded = 0.0;
    for (uint k=0; k<8; ++k) decoded += basis[k*8+u] * b[v][k];
    decoded /= 255.0;
    y = decoded.x + 0.5;
    rgb = float3(y+1.402*decoded.z, y-0.344136*decoded.y-0.714136*decoded.z, y+1.772*decoded.y);
    if (all(gid < size)) output.write(float4(clamp(rgb,0.0,1.0),1.0),gid);
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
