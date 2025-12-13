#include <metal_stdlib>
using namespace metal;

// MARK: - Data Structures

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct GlassUniforms {
    float2 viewSize;
    float2 glassOrigin;
    float2 glassSize;
    float  cornerRadius;
    float  refractionStrength;
    float  specularIntensity;
    float  refractionZonePercent;  // default 0.40, switches use 0.25
    float2 scrollVelocity;  // normalized velocity (-1 to 1) for slime deformation
    float  time;            // CACurrentMediaTime() for wobble animation
    float  edgeIntensity;   // 0 = no edge, 1 = full edge effects
    float  verticalEdgeRefractionScale;  // 1.0 = full, 0.5 = half refraction on vertical edges
    float  _padding;  // Alignment padding to 64 bytes
};

struct SdfUniforms {
    float2 position;
    float2 size;      // half-width, half-height (for pill shape)
    float  intensity;
    float  _padding;  // alignment
};

struct TabUniforms {
    float2 positions[8];   // Up to 8 tab center positions
    float2 sizes[8];       // Individual pill sizes (half-width, half-height)
    float  deformX[8];     // Squash/stretch deformation per tab (-1 to 1)
    float  fillAlpha[8];   // Individual alpha for animation (0 to 1)
    int    count;
    int    selectedIndex;
    float  fillRadius;
    float  fillOpacity;
};

// MARK: - Glass Effect Constants

namespace GlassEffects {
    // Refraction (Snell's Law)
    constant float airRefractiveIndex = 1.0;
    constant float glassRefractiveIndex = 1.5;
    constant float proximityEasing = 0.6;
    constant float incidentAngleMultiplier = 1.4;
    constant float refractionZonePercent = 0.35;
    constant float refractionMultiplier = 12.0;
    constant float paddingPercent = 0.08;

    // Chromatic Aberration & Smear (% of blob height)
    constant float smearPercent = 0.025;
    constant float chromaticPercent = 0.02;
    constant float smearSpacing = 0.5;

    // Edge Effects
    constant float fresnelExponent = 2.5;
    constant float fresnelIntensity = 0.11;
    constant float edgeMaskWidth = 6.0;
    constant float edgeMaskIntensity = 0.11;
    constant float borderOuter = 2.0;
    constant float borderInner = 1.0;
    constant float borderIntensity = 0.38;

    // SDF Fill
    constant float fillTransitionOuter = 10.0;
    constant float fillTransitionInner = -5.0;
    constant float3 fillTint = float3(0.2, 0.2, 0.3);
    constant float fillOpacity = 0.5;

    // SDF Specular
    constant float specularExp1 = 1.5;
    constant float specularWeight1 = 0.7;
    constant float specularExp2 = 3.0;
    constant float specularWeight2 = 1.0;
    constant float baseGlowExp = 2.0;
    constant float baseGlowIntensity = 0.8;
    constant float rimIntensity = 0.6;
    constant float specularMultiplier = 0.6;

    // Alpha & Blending
    constant float glassAlphaSharpness = 32.0;
    constant float sdfAlphaSharpness = 8.0;
    constant float sdfBlendMinK = 20.0;
    constant float sdfBlendFactor = 0.8;

    // Squircle (unselected tabs)
    constant float unselectedFillOuter = 5.0;
    constant float unselectedFillInner = -10.0;
    constant float3 unselectedTint = float3(0.1);

    // Squash/Stretch Deformation
    constant float deformWidthMin = 0.94;
    constant float deformWidthMax = 1.06;
    constant float deformHeightMin = 0.94;
    constant float deformHeightMax = 1.06;
}

// MARK: - SDF Functions

/**
 Calculates signed distance to a rounded rectangle.
 @param pos Position relative to rectangle center
 @param halfSize Half-width and half-height of rectangle
 @param radius Corner radius
 @return Signed distance (negative inside, positive outside)
 @note Uses standard box SDF with corner rounding.
 @see https://iquilezles.org/articles/distfunctions2d/
 */
float sdRoundedRect(float2 pos, float2 halfSize, float radius) {
    radius = min(radius, min(halfSize.x, halfSize.y));
    float2 q = abs(pos) - halfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

/**
 Squash and stretch based on velocity with volume preservation.
 @param pos Position relative to shape center (pixels)
 @param halfSize Half of shape size (pixels)
 @param cornerRadius Corner radius (pixels)
 @param velocityX Normalized X velocity (-1 to 1)
 @param deformAmount Deformation strength (e.g., 0.35)
 @return Signed distance with squash/stretch applied
 @note Width expands/shrinks while height does the opposite (volume preservation).
 */
float sdSquashStretch(
    float2 pos,
    float2 halfSize,
    float cornerRadius,
    float velocityX,
    float deformAmount
) {
    float widthMult  = 1.0 + velocityX * deformAmount;
    float heightMult = 1.0 - velocityX * deformAmount * 0.75;  // Volume preservation

    // Safety limits (5-10% max deformation)
    widthMult  = clamp(widthMult, GlassEffects::deformWidthMin, GlassEffects::deformWidthMax);
    heightMult = clamp(heightMult, GlassEffects::deformHeightMin, GlassEffects::deformHeightMax);

    float2 deformedHalfSize = float2(
        halfSize.x * widthMult,
        halfSize.y * heightMult
    );

    // Offset in movement direction (leading edge moves more)
    float offset = halfSize.x * (widthMult - 1.0) * 0.1;
    float2 adjustedPos = pos - float2(offset, 0.0);

    float radius = min(deformedHalfSize.x, deformedHalfSize.y);  // True pill shape
    float2 q = abs(adjustedPos) - deformedHalfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

/**
 Polynomial smooth minimum for blending shapes.
 @param a First distance value
 @param b Second distance value
 @param k Blend radius (larger = smoother transition)
 @return Smoothly blended minimum
 @note Creates organic transitions instead of hard intersections.
 @see https://iquilezles.org/articles/smin/
 */
float smin(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0 - h);
}

/**
 Calculates signed distance to a superellipse (squircle).
 @param pos Position relative to squircle center
 @param size Half-width and half-height of squircle
 @param n Superellipse exponent (4-5 for iOS-style squircle)
 @return Signed distance (negative inside, positive outside)
 @note Formula: |x/a|^n + |y/b|^n = 1
       n=2 is ellipse, n=4-5 is squircle, n->infinity is rectangle
 */
float sdSquircle(float2 pos, float2 size, float n) {
    float2 d = abs(pos) / size;
    float dist = pow(pow(d.x, n) + pow(d.y, n), 1.0 / n);
    // Convert to signed distance (approximate)
    float interior = dist - 1.0;
    // Scale by minimum axis for proper distance metric
    return interior * min(size.x, size.y);
}

/**
 Calculates signed distance to an SDF shape (pill/rounded rect).
 @param pixelPos Current pixel position
 @param sdf SDF uniforms containing position, size, intensity
 @return Signed distance to shape edge
 @note Uses rounded rect with cornerRadius = height/2 for pill shape
 */
float calculateSdf(float2 pixelPos, constant SdfUniforms &sdf) {
    if (sdf.size.y <= 0.0) return 10000.0;
    float2 pos = pixelPos - sdf.position;
    // Pill shape: corner radius = half-height
    float cornerRadius = sdf.size.y;
    return sdRoundedRect(pos, sdf.size, cornerRadius);
}

// MARK: - Refraction

/**
 Applies Snell's Law to calculate refracted angle.
 @param sinTheta1 Sine of incident angle
 @param n1 Refractive index of first medium (air ≈ 1.0)
 @param n2 Refractive index of second medium (glass ≈ 1.5)
 @return Sine of refracted angle
 @note Snell's Law: n1 × sin(θ1) = n2 × sin(θ2)
 */
float snellRefract(float sinTheta1, float n1, float n2) {
    float ratio = n1 / n2;
    float sinTheta2 = ratio * sinTheta1;
    return clamp(sinTheta2, -1.0, 1.0);
}

/**
 Calculates refracted UV coordinates using Snell's Law.
 @param uv Original texture coordinates
 @param towardEdgeDir Normalized direction toward nearest edge
 @param viewSize Viewport dimensions in pixels
 @param proximity Edge proximity (0 = center, 1 = edge)
 @param refractionStrength Base refraction strength from uniforms
 @param refractionMultiplier Multiplier for refraction effect
 @param paddingAmount How much to push content inward at edges
 @return Refracted UV coordinates
 @note Simulates how light bends when entering glass.
       Refractive indices: air ≈ 1.0, glass ≈ 1.5, water ≈ 1.33, diamond ≈ 2.4
 */
float2 calculateRefractedUV(
    float2 uv,
    float2 towardEdgeDir,
    float2 viewSize,
    float proximity,
    float refractionStrength,
    float refractionMultiplier,
    float paddingAmount
) {
    float easedProximity = pow(proximity, GlassEffects::proximityEasing);
    float incidentAngle = proximity * GlassEffects::incidentAngleMultiplier;
    float sinTheta1 = sin(incidentAngle);
    float sinTheta2 = snellRefract(sinTheta1, GlassEffects::airRefractiveIndex, GlassEffects::glassRefractiveIndex);
    float theta2 = asin(sinTheta2);
    float bendAmount = incidentAngle - theta2;

    float strength = bendAmount * refractionStrength * refractionMultiplier * easedProximity;
    float2 refractedUV = uv - (towardEdgeDir / viewSize) * strength;
    refractedUV -= (towardEdgeDir / viewSize) * paddingAmount * easedProximity;

    return refractedUV;
}

// MARK: - Chromatic Aberration & Smear

/**
 Samples texture with chromatic aberration and directional blur.
 @param tex Source texture
 @param s Texture sampler
 @param baseUV Base UV coordinates after refraction
 @param towardEdgeDir Direction toward edge for chromatic offset
 @param tangentDir Direction along edge for smear blur
 @param viewSize Viewport dimensions
 @param chromaticAmount Chromatic aberration strength in pixels
 @param smearAmount Directional blur strength in pixels
 @return Sampled color with effects applied
 @note Chromatic aberration (dispersion) occurs because different
       wavelengths refract at different angles.
       Cauchy's equation: n(λ) = A + B/λ²
       Red light bends less, blue light bends more.
 */
float3 sampleWithChromaticAberration(
    texture2d<float> tex,
    sampler s,
    float2 baseUV,
    float2 towardEdgeDir,
    float2 tangentDir,
    float2 viewSize,
    float chromaticAmount,
    float smearAmount
) {
    float2 chromaticOffset = towardEdgeDir * chromaticAmount / viewSize;
    float2 redUV = baseUV + chromaticOffset;
    float2 greenUV = baseUV;
    float2 blueUV = baseUV - chromaticOffset;

    // Gaussian weights: e^(-x²/2σ²) with σ=2.0, sum = 1.0
    const int kSamples = 9;
    float weights[9] = { 0.028, 0.066, 0.121, 0.176, 0.199, 0.176, 0.121, 0.066, 0.028 };
    float3 color = float3(0.0);

    for (int i = 0; i < kSamples; i++) {
        float offset = (float(i) - 4.0) * smearAmount * GlassEffects::smearSpacing;
        float2 smearOffset = tangentDir * offset / viewSize;

        float2 rUV = clamp(redUV + smearOffset, 0.001, 0.999);
        float2 gUV = clamp(greenUV + smearOffset, 0.001, 0.999);
        float2 bUV = clamp(blueUV + smearOffset, 0.001, 0.999);

        float r = tex.sample(s, rUV).r;
        float g = tex.sample(s, gUV).g;
        float b = tex.sample(s, bUV).b;

        color += float3(r, g, b) * weights[i];
    }

    return color;
}

// MARK: - SDF Effects

/**
 Calculates specular highlights for an SDF shape using Phong-like model.
 @param pixelPos Current pixel position
 @param sdfShape SDF uniforms
 @param specular Output: accumulated specular intensity
 @return RGB color contribution from this shape
 @note Uses layered specular with different exponents for varied shine.
       Phong model: I = ks × (R·V)^n. Higher n = tighter highlights.
       Enhanced for pill shape with bolder visibility.
 */
float3 calculateSdfSpecular(float2 pixelPos, constant SdfUniforms &sdfShape, thread float &specular) {
    if (sdfShape.size.y <= 0.0) return float3(0.0);

    // Use rounded rect SDF for pill shape
    float2 pos = pixelPos - sdfShape.position;
    float cornerRadius = sdfShape.size.y;
    float sdf = sdRoundedRect(pos, sdfShape.size, cornerRadius);
    float normalizedDist = sdf / min(sdfShape.size.x, sdfShape.size.y);
    float glow = saturate(1.0 - normalizedDist - 1.0);

    // Enhanced specular layers for bolder appearance
    specular += pow(glow, GlassEffects::specularExp1) * sdfShape.intensity * GlassEffects::specularWeight1;
    specular += pow(glow, GlassEffects::specularExp2) * sdfShape.intensity * GlassEffects::specularWeight2;

    float3 color = float3(1.0) * pow(glow, GlassEffects::baseGlowExp) * GlassEffects::baseGlowIntensity;

    // Sharper rim highlight for pill edges
    float rim = smoothstep(0.6, 0.9, glow) * smoothstep(1.0, 0.8, glow);
    color += float3(1.0) * rim * GlassEffects::rimIntensity;

    return color;
}

/**
 Applies SDF fill tint to color for bold visibility.
 @param color Input color
 @param sdfDist Distance to SDF shape
 @return Tinted color
 @note Uses smoothstep for Hermite interpolation: 3t² - 2t³
       Enhanced for bolder appearance with sharper transition.
 */
float3 applySdfFill(float3 color, float sdfDist) {
    // Sharper transition for more defined edge
    float fill = smoothstep(GlassEffects::fillTransitionOuter, GlassEffects::fillTransitionInner, sdfDist);
    // Stronger tint for bold visibility
    return mix(color, color + GlassEffects::fillTint, fill * GlassEffects::fillOpacity);
}

/**
 Applies solid fill for tabs using pill shape with deformation.
 @param color Input color
 @param pixelPos Current pixel position
 @param tabs Tab uniforms with positions, sizes, deformation and fill settings
 @return Color with tab fills applied
 @note Now renders ALL tabs (including selected) with individual alpha control.
       Selected tab fill animates in when blob fades out (handoff effect).
 */
float3 applyUnselectedFills(float3 color, float2 pixelPos, constant TabUniforms &tabs) {
    for (int i = 0; i < tabs.count && i < 8; i++) {
        float alpha = tabs.fillAlpha[i];

        // Skip tabs with zero alpha (invisible)
        if (alpha <= 0.0) continue;

        float2 pos = pixelPos - tabs.positions[i];
        float2 halfSize = tabs.sizes[i];

        // Skip if size not set
        if (halfSize.y <= 0.0) {
            // Fallback to fillRadius if size not set
            halfSize = float2(tabs.fillRadius, tabs.fillRadius * 0.7);
        }

        // Apply squash/stretch deformation (same formula as blob)
        float deform = tabs.deformX[i];
        float widthMult = 1.0 + deform * 0.35;
        float heightMult = 1.0 - deform * 0.35 * 0.75;
        halfSize.x *= widthMult;
        halfSize.y *= heightMult;

        // Use pill shape (rounded rect with cornerRadius = height)
        float cornerRadius = halfSize.y;
        float sdf = sdRoundedRect(pos, halfSize, cornerRadius);

        // Soft fill with per-tab alpha
        float fill = smoothstep(GlassEffects::unselectedFillOuter, GlassEffects::unselectedFillInner, sdf);
        color = mix(color, color + GlassEffects::unselectedTint, fill * tabs.fillOpacity * alpha);
    }
    return color;
}

// MARK: - Edge Effects

/**
 Calculates Fresnel highlights and edge effects with directional masking.
 @param glassSdf Signed distance to glass edge
 @param easedProximity Eased edge proximity value
 @param intensity Dynamic intensity multiplier (0 = no edges, 1 = full)
 @param relativePos Position relative to glass center (for directional masking)
 @return RGB color contribution from edge effects
 @note Fresnel effect causes increased reflectivity at grazing angles.
       When intensity > 0, applies directional mask: visible at bottom/bottom-right,
       fades to invisible at top-left with smooth transition.
 */
float3 calculateEdgeEffects(float glassSdf, float easedProximity, float intensity, float2 relativePos) {
    if (intensity <= 0.0) return float3(0.0);

    // Directional mask: visible at bottom/bottom-right, fades toward top-left
    // In texture coords: +Y is down, so bottom = +Y, right = +X
    float2 normDir = normalize(relativePos + 0.001);
    // Dot with bottom-right direction (1, 1) normalized
    float diagonal = dot(normDir, normalize(float2(1.0, 1.0)));
    // Smooth transition: -1 (top-left) -> 0, +1 (bottom-right) -> 1
    float highlightMask = smoothstep(-0.3, 0.7, diagonal);
    // Inverse mask for dark shadow on top-left
    float shadowMask = smoothstep(0.3, -0.7, diagonal);

    float3 effects = float3(0.0);

    // Fresnel highlight (bottom-right)
    float fresnel = pow(easedProximity, GlassEffects::fresnelExponent) * GlassEffects::fresnelIntensity;
    effects += float3(1.0) * fresnel * highlightMask;

    // Edge highlight (bottom-right)
    float edgeMask = smoothstep(GlassEffects::edgeMaskWidth, 0.0, abs(glassSdf));
    effects += float3(1.0) * edgeMask * GlassEffects::edgeMaskIntensity * highlightMask;

    // Border highlight (bottom-right)
    float border = smoothstep(GlassEffects::borderOuter, 0.0, abs(glassSdf)) - smoothstep(GlassEffects::borderInner, 0.0, abs(glassSdf));
    effects += float3(1.0) * border * GlassEffects::borderIntensity * highlightMask;

    // Dark shadow on top-left edges
    float shadowEdge = smoothstep(GlassEffects::edgeMaskWidth, 0.0, abs(glassSdf));
    effects -= float3(0.15) * shadowEdge * shadowMask;  // Subtract to darken

    return effects * intensity;
}

// MARK: - Vertex Shader

vertex VertexOut liquidGlassVertex(uint vertexID [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1.0, -1.0), float2(1.0, -1.0),
        float2(-1.0,  1.0), float2(1.0,  1.0)
    };
    float2 texCoords[4] = {
        float2(0.0, 1.0), float2(1.0, 1.0),
        float2(0.0, 0.0), float2(1.0, 0.0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// MARK: - Fragment Shader

fragment float4 liquidGlassTabBarFragment(
    VertexOut in [[stage_in]],
    texture2d<float> backdropTexture [[texture(0)]],
    sampler linearSampler [[sampler(0)]],
    constant GlassUniforms &glass [[buffer(0)]],
    constant SdfUniforms &sdf1 [[buffer(1)]],
    constant SdfUniforms &sdf2 [[buffer(2)]],
    constant TabUniforms &tabs [[buffer(3)]]
) {
    // Calculate effect strengths from percentages (relative to blob height)
    const float kSmearStrength = GlassEffects::smearPercent * glass.glassSize.y;
    const float kChromaticStrength = GlassEffects::chromaticPercent * glass.glassSize.y;
    const float kRefractionMultiplier = GlassEffects::refractionMultiplier;
    const float kPaddingAmount = GlassEffects::paddingPercent;

    float2 pixelPos = in.texCoord * glass.viewSize;
    float2 uv = in.texCoord;

    // Glass shape
    float2 glassCenter = glass.glassOrigin + glass.glassSize * 0.5;
    float2 relativePos = pixelPos - glassCenter;
    float2 halfSize = glass.glassSize * 0.5;
    float glassSdf = sdSquashStretch(relativePos, halfSize, glass.cornerRadius, glass.scrollVelocity.x, 0.35);

    // Check if SDF effects are enabled (non-zero size)
    bool sdfEnabled = sdf1.size.y > 0.0 || sdf2.size.y > 0.0;

    float sdfDist = 10000.0;  // Far away by default (disabled)
    if (sdfEnabled) {
        float sdf1Dist = calculateSdf(pixelPos, sdf1);
        float sdf2Dist = calculateSdf(pixelPos, sdf2);
        float blendK = max(min(sdf1.size.y, sdf2.size.y) * GlassEffects::sdfBlendFactor, GlassEffects::sdfBlendMinK);
        sdfDist = smin(sdf1Dist, sdf2Dist, blendK);
    }

    // Check regions
    bool insideGlass = glassSdf < 1.0;
    bool insideSdf = sdfEnabled && sdfDist < 0.0;

    // Discard if outside glass (and outside SDF if enabled)
    if (!insideGlass && !insideSdf) {
        discard_fragment();
    }

    // Handle SDF overflow region (outside glass, inside SDF)
    if (!insideGlass && insideSdf) {
        float3 color = backdropTexture.sample(linearSampler, uv).rgb;
        color = applySdfFill(color, sdfDist);
        float specular = 0.0;
        color += calculateSdfSpecular(pixelPos, sdf1, specular);
        color += calculateSdfSpecular(pixelPos, sdf2, specular);
        color += specular * glass.specularIntensity * GlassEffects::specularMultiplier;
        float sdfAlpha = saturate(-sdfDist * GlassEffects::sdfAlphaSharpness);
        return float4(color * sdfAlpha, sdfAlpha);  // Premultiplied alpha
    }

    // Normal glass rendering (inside glass bounds)
    float alpha = saturate(-glassSdf * GlassEffects::glassAlphaSharpness);
    if (alpha <= 0.0) discard_fragment();

    // Edge proximity (1 at edge, 0 toward center)
    float distFromEdge = -glassSdf;
    float maxDist = min(halfSize.x, halfSize.y);
    float refractionZoneWidth = maxDist * glass.refractionZonePercent;
    float proximity = 1.0 - saturate(distFromEdge / refractionZoneWidth);
    float easedProximity = pow(proximity, GlassEffects::proximityEasing);

    // Direction vectors
    float2 towardEdgeDir = normalize(relativePos + 0.001);
    float2 tangentDir = float2(-towardEdgeDir.y, towardEdgeDir.x);

    // Attenuate refraction on vertical edges (left/right)
    float verticalEdgeFactor = abs(towardEdgeDir.x);
    float edgeScale = mix(1.0, glass.verticalEdgeRefractionScale, verticalEdgeFactor);
    float adjustedProximity = proximity * edgeScale;

    // Refracted UV
    float2 refractedUV = calculateRefractedUV(
        uv, towardEdgeDir, glass.viewSize,
        adjustedProximity, glass.refractionStrength,
        kRefractionMultiplier, kPaddingAmount
    );

    // Sample with chromatic aberration and smear
    float chromatic = easedProximity * kChromaticStrength;
    float smear = easedProximity * kSmearStrength;
    float3 color = sampleWithChromaticAberration(
        backdropTexture, linearSampler,
        refractedUV, towardEdgeDir, tangentDir,
        glass.viewSize, chromatic, smear
    );

    // Edge effects
    color += calculateEdgeEffects(glassSdf, easedProximity, glass.edgeIntensity, relativePos);

    // Only apply SDF and tab effects if enabled
    if (sdfEnabled) {
        color = applyUnselectedFills(color, pixelPos, tabs);
        color = applySdfFill(color, sdfDist);
        float specular = 0.0;
        color += calculateSdfSpecular(pixelPos, sdf1, specular);
        color += calculateSdfSpecular(pixelPos, sdf2, specular);
        color += specular * glass.specularIntensity * GlassEffects::specularMultiplier;
    }

    return float4(color * alpha, alpha);  // Premultiplied alpha
}

// MARK: - SDF Container Fragment Shader

/**
 Standalone SDF container shader - renders SDF shapes without glass refraction.
 Use this for container components that need SDF highlight effects.
 */
fragment float4 liquidGlassSdfFragment(
    VertexOut in [[stage_in]],
    texture2d<float> backdropTexture [[texture(0)]],
    sampler linearSampler [[sampler(0)]],
    constant GlassUniforms &glass [[buffer(0)]],
    constant SdfUniforms &sdf1 [[buffer(1)]],
    constant SdfUniforms &sdf2 [[buffer(2)]]
) {
    float2 pixelPos = in.texCoord * glass.viewSize;
    float2 uv = in.texCoord;

    // Calculate SDF distances
    float sdf1Dist = calculateSdf(pixelPos, sdf1);
    float sdf2Dist = calculateSdf(pixelPos, sdf2);
    float blendK = max(min(sdf1.size.y, sdf2.size.y) * GlassEffects::sdfBlendFactor, GlassEffects::sdfBlendMinK);
    float sdfDist = smin(sdf1Dist, sdf2Dist, blendK);

    // Discard if outside SDF
    if (sdfDist >= 0.0) {
        discard_fragment();
    }

    // Sample backdrop
    float3 color = backdropTexture.sample(linearSampler, uv).rgb;

    // Apply SDF fill and specular
    color = applySdfFill(color, sdfDist);
    float specular = 0.0;
    color += calculateSdfSpecular(pixelPos, sdf1, specular);
    color += calculateSdfSpecular(pixelPos, sdf2, specular);
    color += specular * glass.specularIntensity * GlassEffects::specularMultiplier;

    // SDF alpha based on distance (soft edge)
    float sdfAlpha = saturate(-sdfDist * GlassEffects::sdfAlphaSharpness);
    return float4(color * sdfAlpha, sdfAlpha);  // Premultiplied alpha
}
