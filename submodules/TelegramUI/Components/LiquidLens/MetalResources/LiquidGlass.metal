#include <metal_stdlib>
using namespace metal;

typedef half  scalar_t;
typedef half2 vec2_t;
typedef half3 vec3_t;
typedef half4 vec4_t;

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
};

struct SdfUniforms {
    float2 position;
    float2 size;
    float  intensity;
    float  _padding;
};

struct TabUniforms {
    float2 positions[8];
    float2 sizes[8];
    float  deformX[8];
    float  fillAlpha[8];
    int    count;
    int    selectedIndex;
    float  fillRadius;
    float  fillOpacity;
};

namespace Glass {
    constant scalar_t refractiveRatio = scalar_t(1.0 / 1.5);
    constant scalar_t proximityEasing = scalar_t(0.6);
    constant scalar_t incidentAngleMultiplier = scalar_t(1.4);
    constant scalar_t refractionMultiplier = scalar_t(12.0);
    constant scalar_t paddingPercent = scalar_t(0.08);
    constant float smearPercent = 0.025;
    constant float chromaticPercent = 0.1;
    constant scalar_t smearSpacing = scalar_t(0.5);
    constant scalar_t fresnelExponent = scalar_t(2.5);
    constant scalar_t fresnelIntensity = scalar_t(0.25);
    constant scalar_t edgeMaskWidth = scalar_t(6.0);
    constant scalar_t edgeMaskIntensity = scalar_t(0.25);
    constant scalar_t borderOuter = scalar_t(2.0);
    constant scalar_t borderInner = scalar_t(1.0);
    constant scalar_t borderIntensity = scalar_t(0.6);
    constant scalar_t fillTransitionOuter = scalar_t(10.0);
    constant scalar_t fillTransitionInner = scalar_t(-5.0);
    constant scalar_t fillOpacity = scalar_t(0.6);
    constant scalar_t specularExp = scalar_t(2.0);
    constant scalar_t specularWeight = scalar_t(1.0);
    constant scalar_t baseGlowIntensity = scalar_t(1.0);
    constant scalar_t glassAlphaSharpness = scalar_t(32.0);
    constant scalar_t sdfAlphaSharpness = scalar_t(8.0);
    constant float sdfBlendMinK = 20.0;
    constant float sdfBlendFactor = 0.8;
    constant scalar_t unselectedFillOuter = scalar_t(5.0);
    constant scalar_t unselectedFillInner = scalar_t(-10.0);
    constant float2 diagonalDir = float2(0.7071067811865476);
}

inline float sdRoundedRect(float2 pos, float2 halfSize, float radius) {
    radius = min(radius, min(halfSize.x, halfSize.y));
    float2 q = abs(pos) - halfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

inline float sdSquashStretch(float2 pos, float2 halfSize, float velocityX, float deformAmount) {
    float deform = velocityX * deformAmount;
    float widthMult  = clamp(1.0 - deform, 0.82, 1.18);
    float heightMult = clamp(fma(deform, 0.75, 1.0), 0.82, 1.18);
    float2 deformedHalfSize = halfSize * float2(widthMult, heightMult);
    float2 adjustedPos = pos - float2(halfSize.x * (widthMult - 1.0) * 0.15, 0.0);
    float radius = min(deformedHalfSize.x, deformedHalfSize.y);
    float2 q = abs(adjustedPos) - deformedHalfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

inline float smin(float a, float b, float k) {
    float h = saturate(fma(0.5, (b - a) / k, 0.5));
    return fma(-k * h, 1.0 - h, mix(b, a, h));
}

inline float2 calculateRefractedUV(float2 uv, float2 towardEdgeDir, float2 invViewSize, scalar_t proximity, scalar_t refractionStrength) {
    scalar_t easedProximity = pow(proximity, Glass::proximityEasing);
    scalar_t incidentAngle = proximity * Glass::incidentAngleMultiplier;
    scalar_t sinTheta2 = clamp(Glass::refractiveRatio * sin(incidentAngle), scalar_t(-1.0), scalar_t(1.0));
    scalar_t bendAmount = incidentAngle - asin(sinTheta2);
    scalar_t strength = bendAmount * refractionStrength * Glass::refractionMultiplier * easedProximity;
    float totalOffset = float(fma(Glass::paddingPercent, easedProximity, strength));
    return fma(-towardEdgeDir, invViewSize * totalOffset, uv);
}

vec3_t sampleWithChromaticAberration(
    texture2d<float> tex,
    sampler s,
    float2 baseUV,
    float2 chromaticDir,
    float2 smearDir,
    float chromaticAmount,
    float smearAmount
) {
    float2 chromOffset = chromaticDir * chromaticAmount;
    float smearStep = smearAmount * float(Glass::smearSpacing);

    vec3_t color = vec3_t(0.0);
    float2 smear;

    smear = smearDir * (-4.0 * smearStep);
    color += vec3_t(
        tex.sample(s, clamp(baseUV + chromOffset + smear, float2(0.001), float2(0.999))).r,
        tex.sample(s, clamp(baseUV + smear, float2(0.001), float2(0.999))).g,
        tex.sample(s, clamp(baseUV - chromOffset + smear, float2(0.001), float2(0.999))).b
    ) * scalar_t(0.028);

    smear = smearDir * (-3.0 * smearStep);
    color += vec3_t(
        tex.sample(s, clamp(baseUV + chromOffset + smear, float2(0.001), float2(0.999))).r,
        tex.sample(s, clamp(baseUV + smear, float2(0.001), float2(0.999))).g,
        tex.sample(s, clamp(baseUV - chromOffset + smear, float2(0.001), float2(0.999))).b
    ) * scalar_t(0.066);

    smear = smearDir * (-2.0 * smearStep);
    color += vec3_t(
        tex.sample(s, clamp(baseUV + chromOffset + smear, float2(0.001), float2(0.999))).r,
        tex.sample(s, clamp(baseUV + smear, float2(0.001), float2(0.999))).g,
        tex.sample(s, clamp(baseUV - chromOffset + smear, float2(0.001), float2(0.999))).b
    ) * scalar_t(0.121);

    smear = smearDir * (-1.0 * smearStep);
    color += vec3_t(
        tex.sample(s, clamp(baseUV + chromOffset + smear, float2(0.001), float2(0.999))).r,
        tex.sample(s, clamp(baseUV + smear, float2(0.001), float2(0.999))).g,
        tex.sample(s, clamp(baseUV - chromOffset + smear, float2(0.001), float2(0.999))).b
    ) * scalar_t(0.176);

    color += vec3_t(
        tex.sample(s, clamp(baseUV + chromOffset, float2(0.001), float2(0.999))).r,
        tex.sample(s, clamp(baseUV, float2(0.001), float2(0.999))).g,
        tex.sample(s, clamp(baseUV - chromOffset, float2(0.001), float2(0.999))).b
    ) * scalar_t(0.199);

    smear = smearDir * (1.0 * smearStep);
    color += vec3_t(
        tex.sample(s, clamp(baseUV + chromOffset + smear, float2(0.001), float2(0.999))).r,
        tex.sample(s, clamp(baseUV + smear, float2(0.001), float2(0.999))).g,
        tex.sample(s, clamp(baseUV - chromOffset + smear, float2(0.001), float2(0.999))).b
    ) * scalar_t(0.176);

    smear = smearDir * (2.0 * smearStep);
    color += vec3_t(
        tex.sample(s, clamp(baseUV + chromOffset + smear, float2(0.001), float2(0.999))).r,
        tex.sample(s, clamp(baseUV + smear, float2(0.001), float2(0.999))).g,
        tex.sample(s, clamp(baseUV - chromOffset + smear, float2(0.001), float2(0.999))).b
    ) * scalar_t(0.121);

    smear = smearDir * (3.0 * smearStep);
    color += vec3_t(
        tex.sample(s, clamp(baseUV + chromOffset + smear, float2(0.001), float2(0.999))).r,
        tex.sample(s, clamp(baseUV + smear, float2(0.001), float2(0.999))).g,
        tex.sample(s, clamp(baseUV - chromOffset + smear, float2(0.001), float2(0.999))).b
    ) * scalar_t(0.066);

    smear = smearDir * (4.0 * smearStep);
    color += vec3_t(
        tex.sample(s, clamp(baseUV + chromOffset + smear, float2(0.001), float2(0.999))).r,
        tex.sample(s, clamp(baseUV + smear, float2(0.001), float2(0.999))).g,
        tex.sample(s, clamp(baseUV - chromOffset + smear, float2(0.001), float2(0.999))).b
    ) * scalar_t(0.028);

    return color;
}

vec3_t calculateSdfSpecular(float sdf, float minSize, scalar_t intensity, thread scalar_t &specular) {
    scalar_t normalizedDist = scalar_t(sdf / minSize);
    scalar_t glow = saturate(scalar_t(1.0) - normalizedDist - scalar_t(1.0));
    scalar_t glowPow = glow * glow;
    specular = fma(glowPow, intensity * Glass::specularWeight, specular);
    return vec3_t(glowPow * Glass::baseGlowIntensity);
}

vec3_t applySdfFill(vec3_t color, scalar_t sdfDist) {
    scalar_t fill = smoothstep(Glass::fillTransitionOuter, Glass::fillTransitionInner, sdfDist);
    return fma(vec3_t(0.3, 0.3, 0.4), vec3_t(fill * Glass::fillOpacity), color);
}

vec3_t applyUnselectedFills(vec3_t color, float2 pixelPos, constant TabUniforms &tabs) {
    for (int i = 0; i < tabs.count && i < 8; i++) {
        float alpha = tabs.fillAlpha[i];
        if (alpha <= 0.0) continue;

        float2 pos = pixelPos - tabs.positions[i];
        float2 halfSize = tabs.sizes[i];
        if (halfSize.y <= 0.0) halfSize = float2(tabs.fillRadius, tabs.fillRadius * 0.7);

        float deform = tabs.deformX[i];
        halfSize *= float2(fma(deform, 0.35, 1.0), fma(deform, -0.2625, 1.0));

        float sdf = sdRoundedRect(pos, halfSize, halfSize.y);
        scalar_t fill = smoothstep(Glass::unselectedFillOuter, Glass::unselectedFillInner, scalar_t(sdf));
        color = fma(vec3_t(0.1), vec3_t(fill * scalar_t(tabs.fillOpacity * alpha)), color);
    }
    return color;
}

vec3_t calculateEdgeEffects(scalar_t glassSdf, scalar_t easedProximity, scalar_t intensity, float2 normDir) {
    if (intensity <= scalar_t(0.0)) return vec3_t(0.0);

    scalar_t diagonal = scalar_t(dot(normDir, Glass::diagonalDir));
    scalar_t highlightMask = fma(scalar_t(0.5), smoothstep(scalar_t(-0.3), scalar_t(0.7), diagonal), scalar_t(0.5));
    scalar_t shadowMask = smoothstep(scalar_t(0.3), scalar_t(-0.7), diagonal);
    scalar_t absGlassSdf = abs(glassSdf);

    scalar_t fresnel = pow(easedProximity, Glass::fresnelExponent) * Glass::fresnelIntensity * highlightMask;
    scalar_t edgeMask = smoothstep(Glass::edgeMaskWidth, scalar_t(0.0), absGlassSdf) * Glass::edgeMaskIntensity * highlightMask;
    scalar_t border = (smoothstep(Glass::borderOuter, scalar_t(0.0), absGlassSdf) - smoothstep(Glass::borderInner, scalar_t(0.0), absGlassSdf)) * Glass::borderIntensity * highlightMask;
    scalar_t shadow = smoothstep(Glass::edgeMaskWidth, scalar_t(0.0), absGlassSdf) * scalar_t(0.15) * shadowMask;

    return vec3_t(fresnel + edgeMask + border - shadow) * intensity;
}

vertex VertexOut liquidGlassVertex(uint vertexID [[vertex_id]]) {
    const float2 positions[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
    const float2 texCoords[4] = { float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0) };
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

fragment float4 liquidGlassTabBarFragment(
    VertexOut in [[stage_in]],
    texture2d<float> backdropTexture [[texture(0)]],
    sampler linearSampler [[sampler(0)]],
    constant GlassUniforms &glass [[buffer(0)]],
    constant SdfUniforms &sdf1 [[buffer(1)]],
    constant SdfUniforms &sdf2 [[buffer(2)]],
    constant TabUniforms &tabs [[buffer(3)]]
) {
    float2 invViewSize = 1.0 / glass.viewSize;
    float2 pixelPos = in.texCoord * glass.viewSize;
    float2 glassCenter = fma(glass.glassSize, float2(0.5), glass.glassOrigin);
    float2 relativePos = pixelPos - glassCenter;
    float2 halfSize = glass.glassSize * 0.5;

    float glassSdf = sdSquashStretch(relativePos, halfSize, glass.scrollVelocity.x, 0.45);

    bool insideGlass = glassSdf < 1.0;

    float sdf1Dist = 10000.0;
    float sdf2Dist = 10000.0;
    float sdfDist = 10000.0;
    bool sdfEnabled = sdf1.size.y > 0.0 || sdf2.size.y > 0.0;

    if (sdfEnabled) {
        if (sdf1.size.y > 0.0) sdf1Dist = sdRoundedRect(pixelPos - sdf1.position, sdf1.size, sdf1.size.y);
        if (sdf2.size.y > 0.0) sdf2Dist = sdRoundedRect(pixelPos - sdf2.position, sdf2.size, sdf2.size.y);
        float blendK = max(min(sdf1.size.y, sdf2.size.y) * Glass::sdfBlendFactor, Glass::sdfBlendMinK);
        sdfDist = smin(sdf1Dist, sdf2Dist, blendK);
    }

    bool insideSdf = sdfEnabled && sdfDist < 0.0;
    if (!insideGlass && !insideSdf) discard_fragment();

    float2 uv = in.texCoord;

    if (!insideGlass && insideSdf) {
        vec3_t color = vec3_t(backdropTexture.sample(linearSampler, uv).rgb);
        color = applySdfFill(color, scalar_t(sdfDist));

        scalar_t specular = 0.0;
        if (sdf1.size.y > 0.0) color += calculateSdfSpecular(sdf1Dist, min(sdf1.size.x, sdf1.size.y), scalar_t(sdf1.intensity), specular);
        if (sdf2.size.y > 0.0) color += calculateSdfSpecular(sdf2Dist, min(sdf2.size.x, sdf2.size.y), scalar_t(sdf2.intensity), specular);
        color += specular * scalar_t(glass.specularIntensity * 0.8);

        scalar_t sdfAlpha = saturate(scalar_t(-sdfDist) * Glass::sdfAlphaSharpness);
        return float4(float3(color * sdfAlpha), float(sdfAlpha));
    }

    scalar_t alpha = saturate(scalar_t(-glassSdf) * Glass::glassAlphaSharpness);
    if (alpha <= scalar_t(0.0)) discard_fragment();

    float maxDist = min(halfSize.x, halfSize.y);
    scalar_t proximity = scalar_t(1.0) - saturate(scalar_t(-glassSdf / (maxDist * glass.refractionZonePercent)));
    scalar_t easedProximity = pow(proximity, Glass::proximityEasing);

    float2 towardEdgeDir = normalize(relativePos + 0.001);
    float2 tangentDir = float2(-towardEdgeDir.y, towardEdgeDir.x);

    float xEdgeFactor = abs(towardEdgeDir.x);
    float yEdgeFactor = abs(towardEdgeDir.y);
    scalar_t scaleFactorX = scalar_t(mix(1.0, glass.refractionScaleX, xEdgeFactor));
    scalar_t scaleFactorY = scalar_t(mix(1.0, glass.refractionScaleY, yEdgeFactor));
    scalar_t adjustedProximity = proximity * scaleFactorX * scaleFactorY;

    float2 refractedUV = calculateRefractedUV(uv, towardEdgeDir, invViewSize, adjustedProximity, scalar_t(glass.refractionStrength));

    scalar_t chromaticProximity = smoothstep(scalar_t(0.5), scalar_t(1.0), proximity);
    float chromatic = float(chromaticProximity) * Glass::chromaticPercent * glass.glassSize.y
                    * mix(1.0, glass.chromaticScaleX, xEdgeFactor) * mix(1.0, glass.chromaticScaleY, yEdgeFactor);
    float smear = float(easedProximity) * Glass::smearPercent * glass.glassSize.y;

    float2 chromaticDir = towardEdgeDir * invViewSize;
    float2 smearDir = tangentDir * invViewSize;

    vec3_t color = sampleWithChromaticAberration(backdropTexture, linearSampler, refractedUV, chromaticDir, smearDir, chromatic, smear);
    color += calculateEdgeEffects(scalar_t(glassSdf), easedProximity, scalar_t(glass.edgeIntensity), towardEdgeDir);

    if (sdfEnabled) {
        color = applyUnselectedFills(color, pixelPos, tabs);
        color = applySdfFill(color, scalar_t(sdfDist));

        scalar_t specular = 0.0;
        if (sdf1.size.y > 0.0) color += calculateSdfSpecular(sdf1Dist, min(sdf1.size.x, sdf1.size.y), scalar_t(sdf1.intensity), specular);
        if (sdf2.size.y > 0.0) color += calculateSdfSpecular(sdf2Dist, min(sdf2.size.x, sdf2.size.y), scalar_t(sdf2.intensity), specular);
        color += specular * scalar_t(glass.specularIntensity * 0.8);
    }

    return float4(float3(color * alpha), float(alpha));
}

fragment float4 liquidGlassSdfFragment(
    VertexOut in [[stage_in]],
    texture2d<float> backdropTexture [[texture(0)]],
    sampler linearSampler [[sampler(0)]],
    constant GlassUniforms &glass [[buffer(0)]],
    constant SdfUniforms &sdf1 [[buffer(1)]],
    constant SdfUniforms &sdf2 [[buffer(2)]]
) {
    float2 pixelPos = in.texCoord * glass.viewSize;

    float sdf1Dist = sdf1.size.y > 0.0 ? sdRoundedRect(pixelPos - sdf1.position, sdf1.size, sdf1.size.y) : 10000.0;
    float sdf2Dist = sdf2.size.y > 0.0 ? sdRoundedRect(pixelPos - sdf2.position, sdf2.size, sdf2.size.y) : 10000.0;
    float blendK = max(min(sdf1.size.y, sdf2.size.y) * Glass::sdfBlendFactor, Glass::sdfBlendMinK);
    float sdfDist = smin(sdf1Dist, sdf2Dist, blendK);

    if (sdfDist >= 0.0) discard_fragment();

    vec3_t color = vec3_t(backdropTexture.sample(linearSampler, in.texCoord).rgb);
    color = applySdfFill(color, scalar_t(sdfDist));

    scalar_t specular = 0.0;
    if (sdf1.size.y > 0.0) color += calculateSdfSpecular(sdf1Dist, min(sdf1.size.x, sdf1.size.y), scalar_t(sdf1.intensity), specular);
    if (sdf2.size.y > 0.0) color += calculateSdfSpecular(sdf2Dist, min(sdf2.size.x, sdf2.size.y), scalar_t(sdf2.intensity), specular);
    color += specular * scalar_t(glass.specularIntensity * 0.8);

    scalar_t sdfAlpha = saturate(scalar_t(-sdfDist) * Glass::sdfAlphaSharpness);
    return float4(float3(color * sdfAlpha), float(sdfAlpha));
}
