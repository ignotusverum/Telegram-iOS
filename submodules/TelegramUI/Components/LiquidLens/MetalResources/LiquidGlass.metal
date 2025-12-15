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

namespace GlassEffects {
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
    constant float borderOuter = 2.0;
    constant float borderInner = 1.0;
    constant float borderIntensity = 0.6;

    constant float fillTransitionOuter = 10.0;
    constant float fillTransitionInner = -5.0;
    constant float3 fillTint = float3(0.3, 0.3, 0.4);
    constant float fillOpacity = 0.6;

    constant float specularExp1 = 1.5;
    constant float specularWeight1 = 0.7;
    constant float specularExp2 = 3.0;
    constant float specularWeight2 = 1.0;
    constant float baseGlowExp = 2.0;
    constant float baseGlowIntensity = 1.0;
    constant float rimIntensity = 0.8;
    constant float specularMultiplier = 0.8;

    constant float glassAlphaSharpness = 32.0;
    constant float sdfAlphaSharpness = 8.0;
    constant float sdfBlendMinK = 20.0;
    constant float sdfBlendFactor = 0.8;

    constant float unselectedFillOuter = 5.0;
    constant float unselectedFillInner = -10.0;
    constant float3 unselectedTint = float3(0.1);
}

float sdRoundedRect(float2 pos, float2 halfSize, float radius) {
    radius = min(radius, min(halfSize.x, halfSize.y));
    float2 q = abs(pos) - halfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

float sdSquashStretch(float2 pos, float2 halfSize, float cornerRadius, float velocityX, float deformAmount) {
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

float smin(float a, float b, float k) {
    float h = saturate(0.5 + 0.5 * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0 - h);
}

float sdSquircle(float2 pos, float2 size, float n) {
    float2 d = abs(pos) / size;
    float dist = pow(pow(d.x, n) + pow(d.y, n), 1.0 / n);
    float interior = dist - 1.0;
    return interior * min(size.x, size.y);
}

float calculateSdf(float2 pixelPos, constant SdfUniforms &sdf) {
    if (sdf.size.y <= 0.0) return 10000.0;
    float2 pos = pixelPos - sdf.position;
    float cornerRadius = sdf.size.y;
    return sdRoundedRect(pos, sdf.size, cornerRadius);
}

float snellRefract(float sinTheta1, float n1, float n2) {
    float ratio = n1 / n2;
    float sinTheta2 = ratio * sinTheta1;
    return clamp(sinTheta2, -1.0, 1.0);
}

float2 calculateRefractedUV(float2 uv, float2 towardEdgeDir, float2 viewSize, float proximity, float refractionStrength, float refractionMultiplier, float paddingAmount) {
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

float3 sampleWithChromaticAberration(texture2d<float> tex, sampler s, float2 baseUV, float2 towardEdgeDir, float2 tangentDir, float2 viewSize, float chromaticAmount, float smearAmount) {
    float2 chromaticOffset = towardEdgeDir * chromaticAmount / viewSize;
    float2 redUV = baseUV + chromaticOffset;
    float2 greenUV = baseUV;
    float2 blueUV = baseUV - chromaticOffset;

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

float3 calculateSdfSpecular(float2 pixelPos, constant SdfUniforms &sdfShape, thread float &specular) {
    if (sdfShape.size.y <= 0.0) return float3(0.0);

    float2 pos = pixelPos - sdfShape.position;
    float cornerRadius = sdfShape.size.y;
    float sdf = sdRoundedRect(pos, sdfShape.size, cornerRadius);
    float normalizedDist = sdf / min(sdfShape.size.x, sdfShape.size.y);
    float glow = saturate(1.0 - normalizedDist - 1.0);

    specular += pow(glow, GlassEffects::specularExp1) * sdfShape.intensity * GlassEffects::specularWeight1;
    specular += pow(glow, GlassEffects::specularExp2) * sdfShape.intensity * GlassEffects::specularWeight2;

    float3 color = float3(1.0) * pow(glow, GlassEffects::baseGlowExp) * GlassEffects::baseGlowIntensity;

    float rim = smoothstep(0.6, 0.9, glow) * smoothstep(1.0, 0.8, glow);
    color += float3(1.0) * rim * GlassEffects::rimIntensity;

    return color;
}

float3 applySdfFill(float3 color, float sdfDist) {
    float fill = smoothstep(GlassEffects::fillTransitionOuter, GlassEffects::fillTransitionInner, sdfDist);
    return mix(color, color + GlassEffects::fillTint, fill * GlassEffects::fillOpacity);
}

float3 applyUnselectedFills(float3 color, float2 pixelPos, constant TabUniforms &tabs) {
    for (int i = 0; i < tabs.count && i < 8; i++) {
        float alpha = tabs.fillAlpha[i];

        if (alpha <= 0.0) continue;

        float2 pos = pixelPos - tabs.positions[i];
        float2 halfSize = tabs.sizes[i];

        if (halfSize.y <= 0.0) {
            halfSize = float2(tabs.fillRadius, tabs.fillRadius * 0.7);
        }

        float deform = tabs.deformX[i];
        float widthMult = 1.0 + deform * 0.35;
        float heightMult = 1.0 - deform * 0.35 * 0.75;
        halfSize.x *= widthMult;
        halfSize.y *= heightMult;

        float cornerRadius = halfSize.y;
        float sdf = sdRoundedRect(pos, halfSize, cornerRadius);

        float fill = smoothstep(GlassEffects::unselectedFillOuter, GlassEffects::unselectedFillInner, sdf);
        color = mix(color, color + GlassEffects::unselectedTint, fill * tabs.fillOpacity * alpha);
    }
    return color;
}

float3 calculateEdgeEffects(float glassSdf, float easedProximity, float intensity, float2 relativePos) {
    if (intensity <= 0.0) return float3(0.0);

    float2 normDir = normalize(relativePos + 0.001);
    float diagonal = dot(normDir, normalize(float2(1.0, 1.0)));
    float highlightMask = 0.5 + 0.5 * smoothstep(-0.3, 0.7, diagonal);
    float shadowMask = smoothstep(0.3, -0.7, diagonal);

    float3 effects = float3(0.0);

    float fresnel = pow(easedProximity, GlassEffects::fresnelExponent) * GlassEffects::fresnelIntensity;
    effects += float3(1.0) * fresnel * highlightMask;

    float edgeMask = smoothstep(GlassEffects::edgeMaskWidth, 0.0, abs(glassSdf));
    effects += float3(1.0) * edgeMask * GlassEffects::edgeMaskIntensity * highlightMask;

    float border = smoothstep(GlassEffects::borderOuter, 0.0, abs(glassSdf)) - smoothstep(GlassEffects::borderInner, 0.0, abs(glassSdf));
    effects += float3(1.0) * border * GlassEffects::borderIntensity * highlightMask;

    float shadowEdge = smoothstep(GlassEffects::edgeMaskWidth, 0.0, abs(glassSdf));
    effects -= float3(0.15) * shadowEdge * shadowMask;

    return effects * intensity;
}

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

fragment float4 liquidGlassTabBarFragment(
    VertexOut in [[stage_in]],
    texture2d<float> backdropTexture [[texture(0)]],
    sampler linearSampler [[sampler(0)]],
    constant GlassUniforms &glass [[buffer(0)]],
    constant SdfUniforms &sdf1 [[buffer(1)]],
    constant SdfUniforms &sdf2 [[buffer(2)]],
    constant TabUniforms &tabs [[buffer(3)]]
) {
    const float kSmearStrength = GlassEffects::smearPercent * glass.glassSize.y;
    const float kChromaticStrength = GlassEffects::chromaticPercent * glass.glassSize.y;
    const float kRefractionMultiplier = GlassEffects::refractionMultiplier;
    const float kPaddingAmount = GlassEffects::paddingPercent;

    float2 pixelPos = in.texCoord * glass.viewSize;
    float2 uv = in.texCoord;

    float2 glassCenter = glass.glassOrigin + glass.glassSize * 0.5;
    float2 relativePos = pixelPos - glassCenter;
    float2 halfSize = glass.glassSize * 0.5;
    float glassSdf = sdSquashStretch(relativePos, halfSize, glass.cornerRadius, glass.scrollVelocity.x, 0.45);

    bool sdfEnabled = sdf1.size.y > 0.0 || sdf2.size.y > 0.0;

    float sdfDist = 10000.0;
    if (sdfEnabled) {
        float sdf1Dist = calculateSdf(pixelPos, sdf1);
        float sdf2Dist = calculateSdf(pixelPos, sdf2);
        float blendK = max(min(sdf1.size.y, sdf2.size.y) * GlassEffects::sdfBlendFactor, GlassEffects::sdfBlendMinK);
        sdfDist = smin(sdf1Dist, sdf2Dist, blendK);
    }

    bool insideGlass = glassSdf < 1.0;
    bool insideSdf = sdfEnabled && sdfDist < 0.0;

    if (!insideGlass && !insideSdf) {
        discard_fragment();
    }

    if (!insideGlass && insideSdf) {
        float3 color = backdropTexture.sample(linearSampler, uv).rgb;
        color = applySdfFill(color, sdfDist);
        float specular = 0.0;
        color += calculateSdfSpecular(pixelPos, sdf1, specular);
        color += calculateSdfSpecular(pixelPos, sdf2, specular);
        color += specular * glass.specularIntensity * GlassEffects::specularMultiplier;
        float sdfAlpha = saturate(-sdfDist * GlassEffects::sdfAlphaSharpness);
        return float4(color * sdfAlpha, sdfAlpha);
    }

    float alpha = saturate(-glassSdf * GlassEffects::glassAlphaSharpness);
    if (alpha <= 0.0) discard_fragment();

    float distFromEdge = -glassSdf;
    float maxDist = min(halfSize.x, halfSize.y);
    float refractionZoneWidth = maxDist * glass.refractionZonePercent;
    float proximity = 1.0 - saturate(distFromEdge / refractionZoneWidth);
    float easedProximity = pow(proximity, GlassEffects::proximityEasing);

    float2 towardEdgeDir = normalize(relativePos + 0.001);
    float2 tangentDir = float2(-towardEdgeDir.y, towardEdgeDir.x);

    float xEdgeFactor = abs(towardEdgeDir.x);
    float yEdgeFactor = abs(towardEdgeDir.y);
    float xScale = mix(1.0, glass.refractionScaleX, xEdgeFactor);
    float yScale = mix(1.0, glass.refractionScaleY, yEdgeFactor);
    float adjustedProximity = proximity * xScale * yScale;

    float2 refractedUV = calculateRefractedUV(
        uv, towardEdgeDir, glass.viewSize,
        adjustedProximity, glass.refractionStrength,
        kRefractionMultiplier, kPaddingAmount
    );

    float chromaticProximity = smoothstep(0.5, 1.0, proximity);
    float chromatic = chromaticProximity * kChromaticStrength;

    float smear = easedProximity * kSmearStrength;
    float3 color = sampleWithChromaticAberration(
        backdropTexture, linearSampler,
        refractedUV, towardEdgeDir, tangentDir,
        glass.viewSize, chromatic, smear
    );

    color += calculateEdgeEffects(glassSdf, easedProximity, glass.edgeIntensity, relativePos);

    if (sdfEnabled) {
        color = applyUnselectedFills(color, pixelPos, tabs);
        color = applySdfFill(color, sdfDist);
        float specular = 0.0;
        color += calculateSdfSpecular(pixelPos, sdf1, specular);
        color += calculateSdfSpecular(pixelPos, sdf2, specular);
        color += specular * glass.specularIntensity * GlassEffects::specularMultiplier;
    }

    return float4(color * alpha, alpha);
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
    float2 uv = in.texCoord;

    float sdf1Dist = calculateSdf(pixelPos, sdf1);
    float sdf2Dist = calculateSdf(pixelPos, sdf2);
    float blendK = max(min(sdf1.size.y, sdf2.size.y) * GlassEffects::sdfBlendFactor, GlassEffects::sdfBlendMinK);
    float sdfDist = smin(sdf1Dist, sdf2Dist, blendK);

    if (sdfDist >= 0.0) {
        discard_fragment();
    }

    float3 color = backdropTexture.sample(linearSampler, uv).rgb;

    color = applySdfFill(color, sdfDist);
    float specular = 0.0;
    color += calculateSdfSpecular(pixelPos, sdf1, specular);
    color += calculateSdfSpecular(pixelPos, sdf2, specular);
    color += specular * glass.specularIntensity * GlassEffects::specularMultiplier;

    float sdfAlpha = saturate(-sdfDist * GlassEffects::sdfAlphaSharpness);
    return float4(color * sdfAlpha, sdfAlpha);
}
