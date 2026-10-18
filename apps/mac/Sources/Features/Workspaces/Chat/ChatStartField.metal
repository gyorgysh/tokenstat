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
//
// Around that surface sit layers at different depths, each leaning by its
// own amount when the pointer moves, which is what reads as depth rather
// than as a flat picture: a deep bank of mist, shafts of light falling
// through it, dust hanging in the shafts at three distances, near wisps in
// front of the glass, and the spectrum the composer card throws onto the
// floor where the light passes its edge.

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
/// Corner radius of the composer card, for the prism around it.
constant float kCardRadius = 22.0;
/// How far each layer leans, in points, for a pointer at the pane's edge.
/// Negative layers sit behind the glass and lean away like the key light;
/// positive ones sit in front of it and swing the other way.
constant float kLeanDeep = -26.0;
constant float kLeanShafts = -20.0;
constant float kLeanNear = 14.0;

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

static float2 hash22(float2 p) {
    return float2(hash21(p), hash21(p + float2(19.19, 7.31)));
}

static float fbm3(float2 p) {
    float sum = 0.0;
    float amplitude = 0.55;
    for (int octave = 0; octave < 3; ++octave) {
        sum += valueNoise(p) * amplitude;
        p = p * 2.07 + float2(1.7, 9.2);
        amplitude *= 0.5;
    }
    return sum;
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

/// The same light that the pointer disturbed is drawn into the logo. A
/// curved ribbon keeps its source in the page, with energy travelling inward.
static float inwardLight(float2 point, float2 source, float2 inlet, float time, float seed) {
    float2 travel = inlet - source;
    float reach = length(travel);
    if (reach < 12.0) { return 0.0; }
    float2 axis = travel / reach;
    float2 normal = float2(-axis.y, axis.x);
    float2 offset = point - source;
    float along = dot(offset, axis) / reach;
    if (along < 0.0 || along > 1.0) { return 0.0; }
    float curve = sin(along * M_PI_F) * min(70.0, reach * 0.12) * sin(seed * 1.7);
    float across = dot(offset, normal) - curve;
    float width = mix(9.0, 2.5, along);
    float soft = exp(-across * across / (width * width));
    float core = exp(-across * across / 2.5);
    float front = fract(time * 0.62 + seed * 0.19);
    float packet = exp(-pow((along - front) * 7.0, 2.0));
    float ends = smoothstep(0.0, 0.12, along) * (1.0 - smoothstep(0.96, 1.0, along));
    return (soft * 0.36 + core * 0.42) * (0.35 + packet * 0.65) * ends;
}

static float4 gatherMark(float4 mark, float2 focus, float gathering) {
    mark.xy = mix(mark.xy, focus, gathering);
    mark.z *= 1.0 - gathering * 0.82;
    return mark;
}


/// The same mask as `keyLight`, reaching further, for the layers that are
/// allowed out towards the corners: the shafts fall from above the pane and
/// the deep mist fills the room the light is in.
static float roomLight(float2 point, float2 size) {
    if (size.x < 1.0 || size.y < 1.0) { return 0.0; }
    float2 offset = (point / size - kLightCentre) / (kLightRadii * 1.55);
    return 1.0 - smoothstep(0.30, 1.0, length(offset));
}

/// A bank of fog a long way behind the glass. Two slow layers sheared
/// against each other, so it billows rather than scrolls.
static float deepMist(float2 point, float time) {
    float2 p = point * 0.0024;
    float2 shear = float2(fbm3(p * 0.7 + float2(time * 0.006, 3.1)),
                          fbm3(p * 0.6 + float2(7.4, -time * 0.005)));
    float body = fbm3(p + (shear - 0.5) * 1.6 + float2(-time * 0.010, time * 0.004));
    return smoothstep(0.22, 0.82, body);
}

/// Light falling from above the pane through the deep mist. The beams are
/// noise in angle around a source above the top edge, so they come in uneven
/// widths, and they sway rather than rotate. Each one is brightest where it
/// enters and fades on its way down.
static float shafts(float2 point, float2 size, float2 lean, float time) {
    float2 source = float2(size.x * 0.56, -size.y * 0.42) + lean * kLeanShafts;
    float2 ray = point - source;
    float reach = length(ray);
    if (reach < 1.0) { return 0.0; }
    float angle = atan2(ray.x, ray.y);
    float sway = sin(time * 0.045) * 0.05 + sin(time * 0.027 + 1.3) * 0.03;
    float beams = valueNoise(float2((angle + sway) * 11.0, time * 0.03));
    beams = beams * 0.65 + valueNoise(float2((angle - sway * 0.6) * 27.0 + 5.0, time * 0.05)) * 0.35;
    beams = smoothstep(0.48, 0.92, beams);
    float span = size.y * 1.45;
    float fall = saturate(1.0 - (reach - size.y * 0.40) / span);
    // A cone, not a fan across the whole sky.
    float cone = 1.0 - smoothstep(0.30, 0.62, abs(angle));
    return beams * fall * fall * cone;
}

/// Dust hanging in the light at one depth. One mote at most per cell, kept
/// clear of the cell's edges, so a pixel only ever has to ask its own cell.
/// Deeper tiers are smaller, softer and slower; the near one is larger and
/// out of focus, which is most of what sells the distance.
static float motes(float2 point, float cell, float radius, float softness,
                   float density, float rise, float time, float seed) {
    float2 p = (point + float2(0.0, time * rise)) / cell;
    float2 id = floor(p);
    float pick = hash21(id + seed);
    if (pick > density) { return 0.0; }
    float2 centre = 0.22 + hash22(id + seed * 3.1) * 0.56;
    // Each mote wanders a little on its own.
    float wander = time * (0.10 + pick * 0.25) + pick * 37.0;
    centre += float2(sin(wander), cos(wander * 0.8)) * 0.08;
    float distance = length((fract(p) - centre) * cell);
    float disc = 1.0 - smoothstep(radius * (1.0 - softness), radius, distance);
    float twinkle = 0.55 + 0.45 * sin(time * (0.6 + pick * 1.3) + pick * 91.0);
    return disc * twinkle;
}

/// Wisps in front of the glass. Finer and quicker than the deep bank, and
/// stretched along their drift, so they read as moving air close to us.
static float nearMist(float2 point, float time) {
    float2 p = point * float2(0.0042, 0.0068);
    float body = fbm3(p + float2(time * 0.022, -time * 0.004));
    float edge = fbm3(p * 2.3 + float2(-time * 0.017, time * 0.011) + body);
    return smoothstep(0.50, 0.86, body * 0.7 + edge * 0.45);
}

/// Signed distance to a rounded rectangle, negative inside.
static float roundedBox(float2 point, float4 box, float radius) {
    float2 centre = box.xy + box.zw * 0.5;
    float2 q = abs(point - centre) - box.zw * 0.5 + radius;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

/// A smooth spectrum from red through violet, for `t` in 0...1.
static float3 spectrum(float t) {
    float3 colour = 0.5 + 0.5 * cos(6.28318 * (t * 0.85 + float3(0.0, 0.33, 0.67)));
    return colour * colour;
}

/// What the composer card does to the light behind it. Its edge is glass,
/// so a thin spectral fringe hugs it, brightest on the side the light comes
/// from, and a caustic falls on the floor under it: a spectrum spread by the
/// bevel, rippled where the folds pass under.
static float4 prismAt(float2 point, float4 card, float2 lean, float time, float folds) {
    if (card.z < 1.0 || card.w < 1.0) { return float4(0.0); }
    float distance = roundedBox(point, card, kCardRadius);
    if (distance < 0.0 || distance > 140.0) { return float4(0.0); }
    float2 centre = card.xy + card.zw * 0.5;
    float2 outward = normalize(point - centre + float2(0.0001));
    // The light sits above and leans with the pointer; the edge that faces
    // it catches the most.
    float2 toLight = normalize(float2(-lean.x * 0.6, -1.0));
    // Steep, so the far edges carry almost none of it: a fringe all the
    // way round reads as an outline, not as light.
    float facing = pow(saturate(dot(outward, toLight) * 0.5 + 0.5), 4.0);

    float fringeWidth = 8.0;
    float fringe = 0.0;
    float3 fringeColour = float3(0.0);
    if (distance < fringeWidth) {
        float t = distance / fringeWidth;
        fringe = (1.0 - t) * t * 4.0;
        // The band slides along the edge as the light moves, the way a
        // bevelled edge flashes a different colour from every angle.
        float along = point.x * 0.0021 + time * 0.018 + lean.x * 0.12;
        fringeColour = spectrum(t * 0.9 + along) * (0.6 + 0.4 * valueNoise(float2(point.x * 0.02, time * 0.1)));
    }

    // The caustic: under the card only, a band that spreads as it falls.
    float under = point.y - (card.y + card.w);
    float caustic = 0.0;
    float3 causticColour = float3(0.0);
    if (under > 0.0 && under < 130.0) {
        float across = (point.x - card.x) / card.z;
        float sides = smoothstep(0.02, 0.22, across) * (1.0 - smoothstep(0.78, 0.98, across));
        float t = under / 130.0;
        float ripple = 0.55 + 0.45 * sin(point.x * 0.034 + folds * 5.0 + time * 0.35
                                         + valueNoise(float2(point.x * 0.012, time * 0.05)) * 4.0);
        caustic = exp(-t * 3.2) * (1.0 - exp(-under / 10.0)) * sides * ripple;
        causticColour = spectrum(t * 1.15 + across * 0.25 + lean.x * 0.10 + 0.05);
    }
    // Light adds, so the colour runs a little ahead of the coverage.
    float3 colour = fringeColour * fringe * 0.30 * facing + causticColour * caustic * 0.20;
    float alpha = fringe * 0.070 * facing + caustic * 0.085;
    return float4(colour, alpha);
}

}

using namespace tokenstat;

/// `clock` is (time, lift, dark, send elapsed). `scene` is (lean x, lean y,
/// depth, unused): the lean is the pointer's eased offset from the centre in
/// -1...1, depth scales every layer outside the surface itself. `card` is the
/// composer's frame (x, y, width, height), zero when it is not known. Trail
/// marks are (x, y, age, strength), newest first, so each one's heading comes
/// from the sample behind it and no direction has to be passed in. Rings are
/// the same shape.
[[ stitchable ]] half4 chatStartField(
    float2 position, half4 current,
    float2 size, float4 clock, float4 scene, float4 card,
    half4 accent, half4 secondary, half4 ground,
    float4 trail0, float4 trail1, float4 trail2, float4 trail3, float4 trail4,
    float4 ring0, float4 ring1, float4 ring2)
{
    float room = roomLight(position, size);
    if (room <= 0.004) { return half4(0.0); }
    float mask = keyLight(position, size);

    float time = clock.x;
    float lift = clock.y;
    float dark = clock.z;
    float sendTime = max(0.0, clock.w);
    float gathering = 1.0 - exp(-sendTime * 2.6);
    float2 focus = size * kLightCentre;
    float2 inlet = focus - float2(42.0, 0.0);
    float4 originalClick = ring0;

    float4 trail[5] = { trail0, trail1, trail2, trail3, trail4 };
    for (int index = 0; index < 5; ++index) {
        trail[index] = gatherMark(trail[index], inlet, gathering);
    }
    ring0 = gatherMark(ring0, inlet, gathering);
    ring1 = gatherMark(ring1, inlet, gathering);
    ring2 = gatherMark(ring2, inlet, gathering);
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
    float2 surfacePoint = position - drag;
    const float epsilon = 2.0;
    float rings = ringsAt(surfacePoint, ring0, ring1, ring2);
    float2 bend = float2(
        ringsAt(surfacePoint + float2(epsilon, 0.0), ring0, ring1, ring2)
            - ringsAt(surfacePoint - float2(epsilon, 0.0), ring0, ring1, ring2),
        ringsAt(surfacePoint + float2(0.0, epsilon), ring0, ring1, ring2)
            - ringsAt(surfacePoint - float2(0.0, epsilon), ring0, ring1, ring2)) / (2.0 * epsilon);
    // A ripple refracts the folds underneath it as well as catching light.
    // Keep the displacement bounded, so overlapping taps bend the same
    // glass without tearing it or dislodging the controls above it.
    float2 warped = surfacePoint - clamp(bend * 160.0, float2(-14.0), float2(14.0));
    // Sampling farther from the focus pulls the existing folds inward as
    // send time advances; they do not disappear behind a separate animation.
    warped = focus + (warped - focus) * (1.0 + sendTime * 0.95);
    Surface here = surfaceAt(warped, time);

    // The slope that matters for the prism is the slope of the disturbance,
    // not of the folds: the folds are a hundred points across and tilted
    // everywhere, so keying dispersion to them would tint the whole pane. The
    // rings are cheap to differentiate (no noise), the wipe's rim is where
    // its falloff is halfway, and the crease supplies a permanent trace of
    // colour along the specular lines. Nothing else bends light.
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
    float concentration = exp(-length((position - focus) / max(float2(1.0), size * 0.24)));
    alpha *= mix(1.0, 0.18 + concentration * 0.82, gathering);

    colour += (hash21(position + time) - 0.5) / 255.0;
    colour = clamp(colour, 0.0, 1.0);
    alpha = clamp(alpha, 0.0, 0.30);
    float incoming = 0.0;
    if (sendTime > 0.0) {
        incoming = inwardLight(position, float2(-size.x * 0.05, size.y * 0.18), inlet, sendTime, 1.0)
            + inwardLight(position, float2(size.x * 0.08, size.y * 0.88), inlet, sendTime, 2.0)
            + inwardLight(position, float2(size.x * 0.28, -size.y * 0.05), inlet, sendTime, 3.0);
        if (trail0.w > 0.0) { incoming += inwardLight(position, trail0.xy, inlet, sendTime, 4.0) * trail0.w; }
        if (trail2.w > 0.0) { incoming += inwardLight(position, trail2.xy, inlet, sendTime, 5.0) * trail2.w; }
        // Use the original click location for its incoming light, even as
        // the actual ring collapses towards the mark.
        if (originalClick.w > 0.0) {
            incoming += inwardLight(position, originalClick.xy, inlet, sendTime, 6.0) * originalClick.w;
        }
    }
    float lightAlpha = min(0.55, incoming * gathering * mask * 0.75);
    float3 lightColour = mix(float3(accent.rgb), float3(0.84, 0.91, 1.0), 0.52);

    // Premultiplied from here on, so the layers stack with a plain "over".
    // The incoming light runs under the surface, as it always has.
    float4 result = float4(colour * alpha, alpha);
    result += float4(lightColour * lightAlpha, lightAlpha) * (1.0 - alpha);

    // The layers around the surface. They are drawn in the room the light
    // is in, they fall back as a send gathers everything to the logo, and
    // they lean by depth: behind the glass away from the pointer, in front
    // of it towards.
    float depth = scene.z * (1.0 - gathering * 0.85);
    if (depth > 0.001) {
        float2 lean = scene.xy;
        float gain = mix(0.62, 1.0, dark) * depth;
        float2 pulled = focus + (position - focus) * (1.0 + sendTime * 0.95);
        float3 cool = mix(float3(accent.rgb), float3(secondary.rgb), 0.35);
        float3 beamColour = mix(float3(accent.rgb), float3(0.90, 0.94, 1.0), mix(0.30, 0.62, dark));

        // Behind the glass: the deep bank, then light falling through it.
        float fog = deepMist(pulled - lean * kLeanDeep - drag * 0.15, time);
        float beam = shafts(pulled, size, lean, time) * (0.35 + fog * 0.65);
        float fogAlpha = fog * 0.065 * room * gain;
        float beamAlpha = beam * 0.085 * room * gain;
        float4 back = float4(cool * fogAlpha, fogAlpha);
        back = float4(beamColour * beamAlpha, beamAlpha) + back * (1.0 - beamAlpha);

        // Dust in the beams at three depths. The pointer's drag pushes the
        // near tier hardest, because it is nearest the hand.
        float far = motes(pulled - lean * kLeanDeep * 0.55 - drag * 0.2, 46.0, 1.3, 0.55, 0.30, -5.0, time, 1.0);
        float middle = motes(pulled - lean * kLeanDeep * 0.20 - drag * 0.5, 88.0, 2.2, 0.70, 0.22, -8.0, time, 2.0);
        float close = motes(pulled + lean * kLeanNear - drag * 1.1, 170.0, 5.5, 0.95, 0.16, -13.0, time, 3.0);
        float lit = saturate(beam * 1.6 + mask * 0.35) * room;
        float dust = (far * 0.55 + middle * 0.75 + close * 0.70) * lit * gain;
        float dustAlpha = min(0.32, dust * 0.38);
        back = float4(beamColour * dustAlpha * 1.35, dustAlpha) + back * (1.0 - dustAlpha);

        result = result + back * (1.0 - result.a);

        // The card's spectrum sits on the floor under the glass as well.
        float4 prism = prismAt(position, card, lean, time, here.tide) * gain;
        result = prism + result * (1.0 - prism.a);

        // In front: near wisps, which a wipe clears like the condensation.
        float wisps = nearMist(position - lean * kLeanNear - drag * 0.8, time) * (1.0 - cleared * 0.85);
        float wispAlpha = wisps * 0.050 * room * gain;
        float3 wispColour = mix(float3(ground.rgb), mix(cool, float3(1.0), 0.5), mix(0.55, 0.85, dark));
        result = float4(wispColour * wispAlpha, wispAlpha) + result * (1.0 - wispAlpha);
    }

    return half4(clamp(result, 0.0, 1.0));
}
