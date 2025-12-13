#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct GlassUniforms {
    float2 viewSize;
    float2 glassOrigin;
    float2 glassSize;
    float cornerRadius;
    float edgeIntensity;
    float time;
    float refractionStrength;
    float chromaticAberration;
    float blurAmount;
    float highlightIntensity;
    float3 tintColor;
    float tintOpacity;
    float _padding;
};

struct SdfUniforms {
    float2 viewSize;
    float2 pill1Center;
    float2 pill1Size;
    float2 pill2Center;
    float2 pill2Size;
    float cornerRadius;
    float blendFactor;
    float time;
    float fillOpacity;
    float edgeWidth;
    float3 fillColor;
    float3 edgeColor;
};

struct TabUniforms {
    float2 viewSize;
    float2 glassOrigin;
    float2 glassSize;
    float cornerRadius;
    float edgeIntensity;
    float time;
    float refractionStrength;
    float chromaticAberration;
    float blurAmount;
    float highlightIntensity;
    float3 tintColor;
    float tintOpacity;
    int tabCount;
    float4 tabCenters[5];
    float4 tabSizes[5];
    float4 tabFillOpacities;
    float tabFillOpacity5;
    float selectedIndex;
    float selectionProgress;
    float velocityX;
};

vertex VertexOut liquidGlassVertex(uint vertexID [[vertex_id]]) {
    float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };

    float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

float sdPill(float2 p, float2 center, float2 size) {
    float2 halfSize = size * 0.5;
    float radius = min(halfSize.x, halfSize.y);
    float2 q = abs(p - center) - halfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

float smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

float2 computeRefraction(float2 uv, float dist, float edgeIntensity, float refractionStrength) {
    float2 gradient = float2(
        dfdx(dist),
        dfdy(dist)
    );

    float gradientMag = length(gradient);
    if (gradientMag > 0.001) {
        gradient /= gradientMag;
    }

    float edgeFactor = 1.0 - smoothstep(0.0, edgeIntensity * 30.0, abs(dist));
    float snellFactor = sin(clamp(gradientMag * 2.0, 0.0, 1.57));

    return uv + gradient * snellFactor * edgeFactor * refractionStrength * 0.02;
}

float3 sampleWithChromaticAberration(
    texture2d<float> backdrop,
    sampler s,
    float2 uv,
    float2 offset,
    float chromaticStrength
) {
    float2 uvR = uv + offset * (1.0 + chromaticStrength);
    float2 uvG = uv + offset;
    float2 uvB = uv + offset * (1.0 - chromaticStrength);

    float r = backdrop.sample(s, uvR).r;
    float g = backdrop.sample(s, uvG).g;
    float b = backdrop.sample(s, uvB).b;

    return float3(r, g, b);
}

float3 directionalBlur(
    texture2d<float> backdrop,
    sampler s,
    float2 uv,
    float2 direction,
    float amount,
    float chromaticAberration
) {
    float3 color = float3(0.0);
    float totalWeight = 0.0;

    const int samples = 9;
    float weights[9] = {0.05, 0.09, 0.12, 0.15, 0.18, 0.15, 0.12, 0.09, 0.05};

    for (int i = 0; i < samples; i++) {
        float offset = float(i - 4) / 4.0;
        float2 sampleOffset = direction * offset * amount;
        float weight = weights[i];

        color += sampleWithChromaticAberration(backdrop, s, uv, sampleOffset, chromaticAberration) * weight;
        totalWeight += weight;
    }

    return color / totalWeight;
}

float computeEdgeHighlight(float dist, float edgeWidth, float intensity, float2 gradient, float2 lightDir) {
    float edge = 1.0 - smoothstep(0.0, edgeWidth, abs(dist));

    float gradientMag = length(gradient);
    float2 normal = gradientMag > 0.001 ? gradient / gradientMag : float2(0.0, 1.0);

    float fresnel = pow(1.0 - abs(dot(normal, float2(0.0, 1.0))), 2.0);
    float directional = max(0.0, dot(normal, lightDir));

    return edge * intensity * (fresnel * 0.5 + directional * 0.5);
}

float computeSpecular(float2 uv, float2 glassCenter, float2 glassSize, float time, float intensity) {
    float2 normalizedPos = (uv - glassCenter) / glassSize;

    float spec1 = exp(-length(normalizedPos - float2(-0.3, 0.4)) * 8.0);
    float spec2 = exp(-length(normalizedPos - float2(0.2, 0.35)) * 12.0) * 0.5;

    float timeOffset = sin(time * 0.5) * 0.05;
    float spec3 = exp(-length(normalizedPos - float2(timeOffset, 0.3)) * 10.0) * 0.3;

    return (spec1 + spec2 + spec3) * intensity;
}

float2 applySquashStretch(float2 pos, float2 center, float velocityX, float maxDeform) {
    float2 local = pos - center;
    float deform = clamp(velocityX * 0.001, -maxDeform, maxDeform);

    float stretchX = 1.0 + deform;
    float squashY = 1.0 - deform * 0.5;

    return float2(local.x / stretchX, local.y / squashY) + center;
}

fragment float4 liquidGlassTabBarFragment(
    VertexOut in [[stage_in]],
    texture2d<float> backdrop [[texture(0)]],
    constant TabUniforms& uniforms [[buffer(0)]]
) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float2 pixelPos = in.uv * uniforms.viewSize;
    float2 glassCenter = uniforms.glassOrigin + uniforms.glassSize * 0.5;

    float2 deformedPos = applySquashStretch(pixelPos, glassCenter, uniforms.velocityX, 0.15);

    float2 deformedGlassSize = uniforms.glassSize;
    deformedGlassSize.x *= (1.0 + clamp(uniforms.velocityX * 0.001, -0.15, 0.15));
    deformedGlassSize.y *= (1.0 - clamp(uniforms.velocityX * 0.001, -0.15, 0.15) * 0.5);

    float glassDist = sdPill(deformedPos, glassCenter, deformedGlassSize);

    float glassAlpha = 1.0 - smoothstep(-1.0, 1.0, glassDist);

    if (glassAlpha < 0.001) {
        return float4(0.0);
    }

    float2 refractedUV = computeRefraction(
        in.uv,
        glassDist,
        uniforms.edgeIntensity,
        uniforms.refractionStrength
    );

    float2 blurDir = normalize(float2(uniforms.velocityX, 0.0) + float2(0.001, 0.0));
    float blurAmount = uniforms.blurAmount * (1.0 + abs(uniforms.velocityX) * 0.0005);

    float3 blurredColor = directionalBlur(
        backdrop,
        textureSampler,
        refractedUV,
        blurDir,
        blurAmount * 0.01,
        uniforms.chromaticAberration
    );

    float3 tintedColor = mix(blurredColor, uniforms.tintColor, uniforms.tintOpacity);

    float2 gradient = float2(dfdx(glassDist), dfdy(glassDist));
    float edgeHighlight = computeEdgeHighlight(
        glassDist,
        uniforms.edgeIntensity * 20.0,
        uniforms.highlightIntensity,
        gradient,
        normalize(float2(0.5, 1.0))
    );

    float specular = computeSpecular(
        pixelPos,
        glassCenter,
        deformedGlassSize,
        uniforms.time,
        uniforms.highlightIntensity * 0.5
    );

    for (int i = 0; i < uniforms.tabCount && i < 5; i++) {
        float fillOpacity;
        if (i == 0) fillOpacity = uniforms.tabFillOpacities.x;
        else if (i == 1) fillOpacity = uniforms.tabFillOpacities.y;
        else if (i == 2) fillOpacity = uniforms.tabFillOpacities.z;
        else if (i == 3) fillOpacity = uniforms.tabFillOpacities.w;
        else fillOpacity = uniforms.tabFillOpacity5;

        if (fillOpacity > 0.001) {
            float2 tabCenter = uniforms.tabCenters[i].xy;
            float2 tabSize = uniforms.tabSizes[i].xy;

            float tabDist = sdPill(pixelPos, tabCenter, tabSize);
            float tabAlpha = (1.0 - smoothstep(-0.5, 0.5, tabDist)) * fillOpacity;

            tintedColor = mix(tintedColor, uniforms.tintColor, tabAlpha * 0.3);
        }
    }

    float3 finalColor = tintedColor + edgeHighlight + specular;

    float finalAlpha = glassAlpha;

    return float4(finalColor * finalAlpha, finalAlpha);
}

fragment float4 liquidGlassSdfFragment(
    VertexOut in [[stage_in]],
    constant SdfUniforms& uniforms [[buffer(0)]]
) {
    float2 pixelPos = in.uv * uniforms.viewSize;

    float dist1 = sdPill(pixelPos, uniforms.pill1Center, uniforms.pill1Size);
    float dist2 = sdPill(pixelPos, uniforms.pill2Center, uniforms.pill2Size);

    float blendedDist = smin(dist1, dist2, uniforms.blendFactor);

    float fillAlpha = (1.0 - smoothstep(-0.5, 0.5, blendedDist)) * uniforms.fillOpacity;

    float edgeAlpha = (1.0 - smoothstep(0.0, uniforms.edgeWidth, abs(blendedDist)));

    float3 color = mix(uniforms.fillColor, uniforms.edgeColor, edgeAlpha);
    float alpha = max(fillAlpha, edgeAlpha * 0.5);

    return float4(color * alpha, alpha);
}
