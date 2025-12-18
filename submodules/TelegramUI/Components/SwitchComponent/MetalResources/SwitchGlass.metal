#include <metal_stdlib>
using namespace metal;

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
    float  refractionZonePercent;
    float2 scrollVelocity;
    float  time;
    float  edgeIntensity;
    float  refractionScaleX;
    float  refractionScaleY;
    float  chromaticScaleX;
    float  chromaticScaleY;
    float  borderOuter;
    float  borderInner;
};

namespace SwitchGlassEffects {
    constant float airRefractiveIndex = 1.0;
    constant float glassRefractiveIndex = 1.5;
    constant float proximityEasing = 0.6;
    constant float incidentAngleMultiplier = 1.4;
    constant float refractionMultiplier = 12.0;
    constant float paddingPercent = 0.08;

    constant float smearPercent = 0.025;
    constant float chromaticPercent = 0.02;
    constant float smearSpacing = 0.5;

    constant float fresnelExponent = 2.5;
    constant float fresnelIntensity = 0.25;
    constant float edgeMaskWidth = 6.0;
    constant float edgeMaskIntensity = 0.25;
    constant float borderIntensity = 0.6;

    constant float glassAlphaSharpness = 32.0;
}

float sdSwitchRoundedRect(float2 pos, float2 halfSize, float radius) {
    radius = min(radius, min(halfSize.x, halfSize.y));
    float2 q = abs(pos) - halfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

float sdSwitchSquashStretch(float2 pos, float2 halfSize, float cornerRadius, float velocityX, float deformAmount) {
    float widthMult  = 1.0 - velocityX * deformAmount;
    float heightMult = 1.0 + velocityX * deformAmount * 0.75;

    widthMult  = clamp(widthMult, 0.82, 1.18);
    heightMult = clamp(heightMult, 0.82, 1.18);

    float2 deformedHalfSize = float2(halfSize.x * widthMult, halfSize.y * heightMult);

    float offset = halfSize.x * (widthMult - 1.0) * 0.15;
    float2 adjustedPos = pos - float2(offset, 0.0);

    float radius = min(deformedHalfSize.x, deformedHalfSize.y);
    float2 q = abs(adjustedPos) - deformedHalfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

float snellRefractSwitch(float sinTheta1, float n1, float n2) {
    float ratio = n1 / n2;
    float sinTheta2 = ratio * sinTheta1;
    return clamp(sinTheta2, -1.0, 1.0);
}

float2 calculateRefractedUVSwitch(float2 uv, float2 towardEdgeDir, float2 viewSize, float proximity, float refractionStrength, float refractionMultiplier, float paddingAmount) {
    float easedProximity = pow(proximity, SwitchGlassEffects::proximityEasing);
    float incidentAngle = proximity * SwitchGlassEffects::incidentAngleMultiplier;
    float sinTheta1 = sin(incidentAngle);
    float sinTheta2 = snellRefractSwitch(sinTheta1, SwitchGlassEffects::airRefractiveIndex, SwitchGlassEffects::glassRefractiveIndex);
    float theta2 = asin(sinTheta2);
    float bendAmount = incidentAngle - theta2;

    float strength = bendAmount * refractionStrength * refractionMultiplier * easedProximity;
    float2 refractedUV = uv - (towardEdgeDir / viewSize) * strength;
    refractedUV -= (towardEdgeDir / viewSize) * paddingAmount * easedProximity;

    return refractedUV;
}

float3 sampleWithChromaticAberrationSwitch(texture2d<float> tex, sampler s, float2 baseUV, float2 towardEdgeDir, float2 tangentDir, float2 viewSize, float chromaticAmount, float smearAmount) {
    float2 chromaticOffset = towardEdgeDir * chromaticAmount / viewSize;
    float2 redUV = baseUV + chromaticOffset;
    float2 greenUV = baseUV;
    float2 blueUV = baseUV - chromaticOffset;

    const int kSamples = 9;
    float weights[9] = { 0.028, 0.066, 0.121, 0.176, 0.199, 0.176, 0.121, 0.066, 0.028 };
    float3 color = float3(0.0);

    for (int i = 0; i < kSamples; i++) {
        float offset = (float(i) - 4.0) * smearAmount * SwitchGlassEffects::smearSpacing;
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

float3 calculateSwitchEdgeEffects(float glassSdf, float easedProximity, float intensity, float2 relativePos, float borderOuter, float borderInner) {
    if (intensity <= 0.0) return float3(0.0);

    float2 normDir = normalize(relativePos + 0.001);
    float diagonal = dot(normDir, normalize(float2(1.0, 1.0)));
    float highlightMask = 0.5 + 0.5 * smoothstep(-0.3, 0.7, diagonal);
    float shadowMask = smoothstep(0.3, -0.7, diagonal);

    float3 effects = float3(0.0);

    float fresnel = pow(easedProximity, SwitchGlassEffects::fresnelExponent) * SwitchGlassEffects::fresnelIntensity;
    effects += float3(1.0) * fresnel * highlightMask;

    float edgeMask = smoothstep(SwitchGlassEffects::edgeMaskWidth, 0.0, abs(glassSdf));
    effects += float3(1.0) * edgeMask * SwitchGlassEffects::edgeMaskIntensity * highlightMask;

    float border = smoothstep(borderOuter, 0.0, abs(glassSdf)) - smoothstep(borderInner, 0.0, abs(glassSdf));
    effects += float3(1.0) * border * SwitchGlassEffects::borderIntensity * highlightMask;

    float shadowEdge = smoothstep(SwitchGlassEffects::edgeMaskWidth, 0.0, abs(glassSdf));
    effects -= float3(0.15) * shadowEdge * shadowMask;

    return effects * intensity;
}

vertex VertexOut switchGlassVertex(uint vertexID [[vertex_id]]) {
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

fragment float4 switchGlassFragment(
    VertexOut in [[stage_in]],
    texture2d<float> backdropTexture [[texture(0)]],
    sampler linearSampler [[sampler(0)]],
    constant GlassUniforms &glass [[buffer(0)]]
) {
    const float kSmearStrength = SwitchGlassEffects::smearPercent * glass.glassSize.y;
    const float kChromaticStrength = SwitchGlassEffects::chromaticPercent * glass.glassSize.y;
    const float kRefractionMultiplier = SwitchGlassEffects::refractionMultiplier;
    const float kPaddingAmount = SwitchGlassEffects::paddingPercent;

    float2 pixelPos = in.texCoord * glass.viewSize;
    float2 uv = in.texCoord;

    float2 glassCenter = glass.glassOrigin + glass.glassSize * 0.5;
    float2 relativePos = pixelPos - glassCenter;
    float2 halfSize = glass.glassSize * 0.5;
    float glassSdf = sdSwitchSquashStretch(relativePos, halfSize, glass.cornerRadius, glass.scrollVelocity.x, 0.45);

    bool insideGlass = glassSdf < 1.0;

    if (!insideGlass) {
        discard_fragment();
    }

    float alpha = saturate(-glassSdf * SwitchGlassEffects::glassAlphaSharpness);
    if (alpha <= 0.0) discard_fragment();

    float distFromEdge = -glassSdf;
    float maxDist = min(halfSize.x, halfSize.y);
    float refractionZoneWidth = maxDist * glass.refractionZonePercent;
    float proximity = 1.0 - saturate(distFromEdge / refractionZoneWidth);
    float easedProximity = pow(proximity, SwitchGlassEffects::proximityEasing);

    float2 towardEdgeDir = normalize(relativePos + 0.001);
    float2 tangentDir = float2(-towardEdgeDir.y, towardEdgeDir.x);

    float xEdgeFactor = abs(towardEdgeDir.x);
    float yEdgeFactor = abs(towardEdgeDir.y);
    float xScale = mix(1.0, glass.refractionScaleX, xEdgeFactor);
    float yScale = mix(1.0, glass.refractionScaleY, yEdgeFactor);
    float adjustedProximity = proximity * xScale * yScale;

    float2 refractedUV = calculateRefractedUVSwitch(
        uv, towardEdgeDir, glass.viewSize,
        adjustedProximity, glass.refractionStrength,
        kRefractionMultiplier, kPaddingAmount
    );

    float chromaticProximity = smoothstep(0.5, 1.0, proximity);
    float chromaticXScale = mix(1.0, glass.chromaticScaleX, xEdgeFactor);
    float chromaticYScale = mix(1.0, glass.chromaticScaleY, yEdgeFactor);
    float chromatic = chromaticProximity * kChromaticStrength * chromaticXScale * chromaticYScale;

    float smear = easedProximity * kSmearStrength;
    float3 color = sampleWithChromaticAberrationSwitch(
        backdropTexture, linearSampler,
        refractedUV, towardEdgeDir, tangentDir,
        glass.viewSize, chromatic, smear
    );

    color += calculateSwitchEdgeEffects(glassSdf, easedProximity, glass.edgeIntensity, relativePos, glass.borderOuter, glass.borderInner);

    return float4(color * alpha, alpha);
}
