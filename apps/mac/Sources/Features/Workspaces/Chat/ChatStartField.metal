// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// The new chat page's surface: one light behind the composer, seen through
// fogged glass that the pointer wipes clear.
//
// This used to be a 72 pixel CPU raster, bicubically upscaled and blurred, so
// every curve had to be broad enough to survive that and nothing could depend
// on a real pixel. On the GPU the surface is evaluated per pixel, which is
// what pays for the three things the CPU version could not have: condensation
// that a pointer wipes a healing hole in, rings that travel out from a click
// and bend the surface as they pass, and chromatic dispersion on any face
// steep enough to deserve it.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

namespace tokenstat {

/// Where the light sits and how far it reaches, in fractions of the pane.
/// Centred a little above the middle, because the composer is.
constant float2 kLightCentre = float2(0.5, 0.46);
constant float2 kLightRadii = float2(0.62, 0.58);
/// Points per unit of fold space. The folds are measured in hundreds of
/// points so they stay broad and slow at any window size.
constant float kFoldScale = 205.0;
/// How far a ring's front travels each second, in points.
constant float kRingSpeed = 430.0;

static float hash21(float2 p) {
    float3 q = fract(float3(p.x, p.y, p.x) * float3(0.1031, 0.1030, 0.0973));
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

static float valueNoise(float2 p) {
    float2 cell = floor(p);
    float2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash21(cell);
    float b = hash21(cell + float2(1.0, 0.0));
    float c = hash21(cell + float2(0.0, 1.0));
    float d = hash21(cell + float2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

static float fbm(float2 p) {
    float sum = 0.0;
    float amplitude = 0.5;
    for (int octave = 0; octave < 4; ++octave) {
        sum += valueNoise(p) * amplitude;
        p *= 2.03;
        amplitude *= 0.5;
    }
    return sum;
}

/// Full across the composer, nothing at the corners. Everything else is
/// multiplied by this, so the room stays the near-black it was designed as.
static float keyLight(float2 point, float2 size) {
    // A pane can be reported at zero size for a frame during a resize, and
    // the divide would then carry NaN past the caller's own test for it.
    if (size.x < 1.0 || size.y < 1.0) { return 0.0; }
    float2 offset = (point / size - kLightCentre) / kLightRadii;
    return 1.0 - smoothstep(0.28, 1.0, length(offset));
}

/// Two curved optical layers travelling at slightly different rates. The
/// low-frequency warp keeps the folds asymmetric without smoke, particles, a
/// noisy texture, or repeated concentric bands.
struct Surface {
    float depth;
    float tide;
    /// The specular crease along the side of a fold.
    float crease;
};

static Surface surfaceAt(float2 point, float time) {
    float2 p = point / kFoldScale;
    float2 drift = float2(time * 0.009, -time * 0.006);
    float2 q = float2(valueNoise(p * 0.39 + drift),
                      valueNoise(p * 0.32 + float2(4.7, 8.1) - drift * 0.7));
    float2 warped = p + (q - 0.5) * 2.1;
    float a = warped.x * 1.28 + warped.y * 0.42 + sin(warped.y * 0.8 + q.y) * 0.8 - time * 0.012;
    float b = warped.y * 1.14 - warped.x * 0.53 + q.y * 1.6 + time * 0.008;
    float first = 0.5 + 0.5 * sin(a);
    float second = 0.5 + 0.5 * sin(b);
    Surface surface;
    surface.depth = pow(first, 1.7) * 0.76 + pow(second, 2.4) * 0.24;
    surface.tide = second;
    surface.crease = min(1.0,
        pow(max(0.0, 1.0 - abs(sin(a + 0.55))), 11.0) * (0.45 + second * 0.55)
        + pow(max(0.0, 1.0 - abs(sin(b - 0.8))), 13.0) * first * 0.30);
    return surface;
}

/// A ring travelling out from a click, with a couple of crests behind its
/// front. The front outruns its own envelope, so the disturbance passes
/// through a place and leaves it flat again rather than settling as a halo.
static float ringHeight(float2 point, float4 ring) {
    if (ring.w <= 0.0) { return 0.0; }
    float age = ring.z;
    float reach = length(point - ring.xy);
    float band = reach - age * kRingSpeed;
    float envelope = exp(-abs(band) / 125.0) * exp(-age / 1.25);
    float spread = 1.0 / (1.0 + reach * 0.0055);
    return sin(band * 0.055) * envelope * spread * ring.w;
}

static float ringsAt(float2 point, float4 first, float4 second, float4 third) {
    return ringHeight(point, first) + ringHeight(point, second) + ringHeight(point, third);
}

/// What one pointer sample does: drags the surface along the path it took,
/// and wipes the condensation off it. The drag relaxes in under a second,
/// the clearing heals over about two, so a sweep leaves a bright trail that
/// closes behind itself.
struct Wipe {
    float2 drag;
    float clear;
};

static Wipe wipeAt(float2 point, float4 mark, float2 heading) {
    Wipe wipe;
    wipe.drag = float2(0.0);
    wipe.clear = 0.0;
    if (mark.w <= 0.0) { return wipe; }
    float age = mark.z;
    float2 away = point - mark.xy;
    float reach = length(away);
    float radius = 165.0 + age * 55.0;
    if (reach > radius) { return wipe; }
    float fall = 1.0 - reach / radius;
    fall = fall * fall * fall;
    float2 curl = float2(-heading.y, heading.x);
    float swirl = reach > 0.001 ? dot(away / reach, curl) : 0.0;
    wipe.drag = (heading * 26.0 + curl * swirl * 14.0) * fall * exp(-age / 0.80) * mark.w;
    wipe.clear = fall * exp(-age / 1.90) * mark.w;
    return wipe;
}

}

using namespace tokenstat;

/// `clock` is (time, lift, dark, unused). Trail marks are (x, y, age,
/// strength), newest first, so each one's heading comes from the sample
/// behind it and no direction has to be passed in. Rings are the same shape.
[[ stitchable ]] half4 chatStartField(
    float2 position, half4 current,
    float2 size, float4 clock,
    half4 accent, half4 secondary, half4 ground,
    float4 trail0, float4 trail1, float4 trail2, float4 trail3, float4 trail4,
    float4 ring0, float4 ring1, float4 ring2)
{
    float mask = keyLight(position, size);
    if (mask <= 0.004) { return half4(0.0); }

    float time = clock.x;
    float lift = clock.y;
    float dark = clock.z;

    float4 trail[5] = { trail0, trail1, trail2, trail3, trail4 };
    float2 drag = float2(0.0);
    float cleared = 0.0;
    // Carried across the loop, so the oldest sample, which has no older
    // neighbour to subtract from, still drags along the heading the stroke
    // had when it passed. Resetting it each time left the tail of a sweep
    // clearing mist without moving anything under it.
    float2 heading = float2(0.0);
    for (int index = 0; index < 5; ++index) {
        if (index + 1 < 5 && trail[index + 1].w > 0.0) {
            float2 travel = trail[index].xy - trail[index + 1].xy;
            float travelled = length(travel);
            if (travelled > 0.001) { heading = travel / travelled; }
        }
        Wipe wipe = wipeAt(position, trail[index], heading);
        drag += wipe.drag;
        cleared = max(cleared, wipe.clear);
    }
    cleared = saturate(cleared);

    // The surface is read where the pointer dragged it from, which is what
    // makes the water move with the mouse and flow back when it stops.
    float2 warped = position - drag;
    Surface here = surfaceAt(warped, time);

    // The slope that matters for the prism is the slope of the disturbance,
    // not of the folds: the folds are a hundred points across and tilted
    // everywhere, so keying dispersion to them would tint the whole pane. The
    // rings are cheap to differentiate (no noise), the wipe's rim is where
    // its falloff is halfway, and the crease supplies a permanent trace of
    // colour along the specular lines. Nothing else bends light.
    const float epsilon = 2.0;
    float rings = ringsAt(warped, ring0, ring1, ring2);
    float2 bend = float2(ringsAt(warped + float2(epsilon, 0.0), ring0, ring1, ring2) - rings,
                         ringsAt(warped + float2(0.0, epsilon), ring0, ring1, ring2) - rings) / epsilon;
    float bendAmount = length(bend);
    float dragAmount = length(drag);
    float rim = cleared * (1.0 - cleared) * 4.0;
    float2 facing = bendAmount > 1e-5 ? bend / bendAmount
        : (dragAmount > 0.001 ? drag / dragAmount : float2(0.0));

    float height = here.depth + rings * 0.9;
    float creaseG = here.crease;
    float creaseR = creaseG;
    float creaseB = creaseG;
    float spread = min(30.0, bendAmount * 900.0 + rim * 9.0 + creaseG * 3.0);
    if (spread > 0.35) {
        creaseR = surfaceAt(warped - facing * spread * 0.45, time).crease;
        creaseB = surfaceAt(warped + facing * spread * 0.45, time).crease;
    }

    // Condensation on the inside of the glass: it lifts the floor and
    // flattens whatever is behind it, until something wipes it away.
    float haze = fbm(position * 0.0055 + float2(time * 0.011, time * 0.008));
    float mist = (0.42 + 0.58 * haze) * (1.0 - cleared * 0.92);
    float clarity = 1.0 - mist * 0.55;

    float3 tint = float3(accent.rgb) * mix(0.62, 0.78, dark)
        + float3(ground.rgb) * mix(0.38, 0.22, dark);
    float3 highlight = float3(secondary.rgb) * mix(0.30, 0.62, dark)
        + float3(ground.rgb) * mix(0.70, 0.38, dark);
    float3 sheen = float3(mix(1.0, 0.78, dark));

    float tintMix = here.tide * 0.24 + creaseG * 0.18;
    float3 colour = mix(tint, highlight, tintMix) * (1.0 - creaseG * 0.48) + sheen * creaseG * 0.48;
    colour += float3(creaseR - creaseG, 0.0, creaseB - creaseG) * (0.70 + 0.90 * cleared) * mix(0.60, 1.0, dark);

    // A crest catches the light and a trough loses it, which is the whole
    // difference between a ring that reads as water and one that reads as a
    // drawn circle.
    float crest = saturate(rings * 2.4);
    float trough = saturate(-rings * 2.4);
    colour += sheen * crest * 0.30 - float3(0.12) * trough;

    float base = mix(0.022, 0.030, dark);
    float depthGain = mix(0.120, 0.145, dark);
    float catchGain = mix(0.055, 0.095, dark);
    float alpha = base * (0.75 + 0.50 * mist)
        + saturate(height) * depthGain * clarity
        + creaseG * catchGain * (0.55 + 1.10 * cleared)
        + crest * 0.055 + trough * 0.020;
    alpha *= mask * (1.0 + lift * 0.18);

    colour += (hash21(position + time) - 0.5) / 255.0;
    colour = clamp(colour, 0.0, 1.0);
    alpha = clamp(alpha, 0.0, 0.30);
    return half4(half3(colour * alpha), half(alpha));
}
