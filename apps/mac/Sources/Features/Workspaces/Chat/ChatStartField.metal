// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// The new chat page's surface: a fine grid of dots, lit around the composer,
// with slow waves of light travelling inward to it. The waves are tokens on
// their way into the conversation, which is the one thing this product is
// about, said without a word on the page.
//
// It is meant to sit at the edge of notice. Dots are a point and a half
// across, the waves are soft and a few seconds apart, and the pointer only
// swells the dots near it, like a lens held over paper.

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

namespace tokenstat {

/// Points between dots. Wide enough to read as paper, not as texture.
constant float kSpacing = 22.0;
/// Points between two waves, and how fast they travel inward, in waves a
/// second. Together about twenty-five points a second.
constant float kWaveLength = 260.0;
constant float kWaveRate = 0.10;
/// How far the pointer's lens reaches, in points.
constant float kLensReach = 150.0;
/// How far a dot under the pointer is pushed aside. Kept below half the
/// spacing less the largest radius, so a dot never leaves its own cell and a
/// pixel still only has to ask one dot.
constant float kLensPush = 7.0;

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

}

using namespace tokenstat;

/// `clock` is (time, lift, dark, motion): lift is 1 while something is being
/// written, motion is 0 when the waves and the twinkle should hold still.
/// Time is integrated on the Swift side, so a send can run it faster without
/// the waves jumping.
/// `pointer` is (x, y, presence, unused), presence easing between 0 and 1.
/// `focus` is where the light sits and the waves arrive, in fractions of
/// the pane: the composer on the new chat page, the mark on sign-in.
[[ stitchable ]] half4 chatStartField(
    float2 position, half4 current,
    float2 size, float4 clock, float4 pointer, float2 focusUnit, half4 accent)
{
    // A pane can be reported at zero size for a frame during a resize.
    if (size.x < 1.0 || size.y < 1.0) { return half4(0.0); }
    float time = clock.x;
    float lift = clock.y;
    float dark = clock.z;
    float motion = clock.w;

    float2 cell = floor(position / kSpacing);
    float2 centre = (cell + 0.5) * kSpacing;
    float2 focus = size * focusUnit;

    // Everything is a property of the dot, not the pixel, so a dot is lit
    // evenly across its own disc.
    float spread = length((centre - focus) / size * float2(1.0, 1.25));
    float vignette = 1.0 - smoothstep(0.12, 0.78, spread);
    if (vignette <= 0.001) { return half4(0.0); }
    float near = 1.0 - smoothstep(0.0, 0.40, spread);

    // The waves are not perfect circles: their radius wanders slowly with
    // the angle, so they read as something arriving, not as a radar.
    float2 away = centre - focus;
    float reach = length(away);
    float angle = atan2(away.y, away.x);
    float wobble = (valueNoise(float2(angle * 1.6 + 3.0, time * 0.04)) - 0.5) * 90.0;
    float phase = (reach + wobble) / kWaveLength + time * kWaveRate;
    float wave = pow(0.5 + 0.5 * cos(6.28318 * phase), 10.0) * motion;
    // Quiet under the card and the title, where nothing would see it anyway.
    wave *= smoothstep(40.0, 200.0, reach);

    float seed = hash21(cell);
    float twinkle = 1.0 - 0.25 * motion * (0.5 + 0.5 * sin(time * (0.35 + seed * 0.7) + seed * 40.0));

    // The grid is never evenly lit for long: broad patches swell and ebb on
    // their own, and the whole field breathes a little under them.
    float swell = valueNoise(centre * 0.0032 + float2(time * 0.035, -time * 0.022));
    swell = mix(0.45, 1.45, smoothstep(0.15, 0.85, swell));
    float breath = 0.88 + 0.12 * sin(time * 0.21);

    // The pointer parts the dots around it, like filings around a magnet,
    // and lights the ones it moves.
    float lens = 0.0;
    float2 dotCentre = centre;
    if (pointer.z > 0.0) {
        float2 fromPointer = centre - pointer.xy;
        float distance = length(fromPointer);
        lens = pointer.z * pow(saturate(1.0 - distance / kLensReach), 2.0);
        if (distance > 0.001) {
            float push = pointer.z * kLensPush * sin(saturate(1.0 - distance / kLensReach) * M_PI_F);
            dotCentre += fromPointer / distance * push;
        }
    }

    float radius = 0.75 + wave * 0.45 + lens * 0.85;
    float disc = 1.0 - smoothstep(radius - 0.55, radius + 0.55, length(position - dotCentre));
    if (disc <= 0.0) { return half4(0.0); }

    float strength = vignette * (0.10 + near * 0.20) * twinkle * swell * breath
        + wave * vignette * 0.30 * swell
        + lens * vignette * 0.32;
    strength *= 1.0 + lift * 0.25;

    float3 ink = dark > 0.5 ? float3(1.0) : float3(0.0);
    float tint = saturate(near * 0.55 + wave * 0.9 + lens * 0.8);
    float3 colour = mix(ink, float3(accent.rgb), tint);
    float alpha = saturate(disc * strength * mix(0.70, 1.0, dark));
    return half4(half3(colour * alpha), half(alpha));
}
