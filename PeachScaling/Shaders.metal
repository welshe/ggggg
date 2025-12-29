#include <metal_stdlib>
using namespace metal;

// ============================================================================
// MARK: - Data Structures
// ============================================================================

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct InterpolationConstants {
    float interpolationFactor;
    float motionScale;
    float2 textureSize;
};

struct SharpenConstants {
    float sharpness;
    float radius;
};

struct AAConstants {
    float threshold;
    float subpixelBlend;
};

// ============================================================================
// MARK: - Utility Functions
// ============================================================================

float luminance(float3 color) {
    return dot(color, float3(0.299, 0.587, 0.114));
}

float2 getMotionVector(texture2d<float, access::sample> motionTexture, float2 uv, sampler s) {
    if (is_null_texture(motionTexture)) {
        return float2(0.0, 0.0);
    }
    return motionTexture.sample(s, uv).xy;
}

// ============================================================================
// MARK: - Texture Display Shaders
// ============================================================================

vertex VertexOut texture_vertex(uint vid [[vertex_id]]) {
    const float2 positions[4] = {
        float2(-1.0, -1.0),  // bottom-left
        float2( 1.0, -1.0),  // bottom-right
        float2(-1.0,  1.0),  // top-left
        float2( 1.0,  1.0)   // top-right
    };
    
    const float2 texCoords[4] = {
        float2(0.0, 1.0),  // bottom-left
        float2(1.0, 1.0),  // bottom-right
        float2(0.0, 0.0),  // top-left
        float2(1.0, 0.0)   // top-right
    };
    
    VertexOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.texCoord = texCoords[vid];
    return out;
}

fragment float4 texture_fragment(VertexOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler samp [[sampler(0)]]) {
    return tex.sample(samp, in.texCoord);
}

// ============================================================================
// MARK: - Frame Interpolation
// ============================================================================

kernel void interpolateFrames(
    texture2d<float, access::sample> currentFrame [[texture(0)]],
    texture2d<float, access::sample> previousFrame [[texture(1)]],
    texture2d<float, access::sample> motionVectors [[texture(2)]],
    texture2d<float, access::write> outputFrame [[texture(3)]],
    constant InterpolationConstants &constants [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputFrame.get_width() || gid.y >= outputFrame.get_height()) {
        return;
    }

    float2 texSize = float2(outputFrame.get_width(), outputFrame.get_height());
    float2 uv = (float2(gid) + 0.5) / texSize;
    
    constexpr sampler s(address::clamp_to_edge, filter::linear);

    float2 motion = float2(0.0);
    if (!is_null_texture(motionVectors)) {
        motion = motionVectors.sample(s, uv).xy * constants.motionScale;
    }
    
    float t = constants.interpolationFactor;
    
    float2 forwardUV = uv + (motion * t / texSize);
    float2 backwardUV = uv - (motion * (1.0 - t) / texSize);
    
    float4 colorPrev = previousFrame.sample(s, backwardUV);
    float4 colorCurr = currentFrame.sample(s, forwardUV);
    
    float4 result = mix(colorPrev, colorCurr, t);
    
    outputFrame.write(result, gid);
}

// Simple blend interpolation (no motion vectors)
kernel void interpolateSimple(
    texture2d<float, access::sample> currentFrame [[texture(0)]],
    texture2d<float, access::sample> previousFrame [[texture(1)]],
    texture2d<float, access::write> outputFrame [[texture(2)]],
    constant float &t [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputFrame.get_width() || gid.y >= outputFrame.get_height()) {
        return;
    }

    float2 texSize = float2(outputFrame.get_width(), outputFrame.get_height());
    float2 uv = (float2(gid) + 0.5) / texSize;
    
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    
    float4 colorPrev = previousFrame.sample(s, uv);
    float4 colorCurr = currentFrame.sample(s, uv);
    
    float4 result = mix(colorPrev, colorCurr, t);
    
    outputFrame.write(result, gid);
}

// ============================================================================
// MARK: - Contrast Adaptive Sharpening (CAS)
// ============================================================================

kernel void contrastAdaptiveSharpening(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant SharpenConstants &constants [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    constexpr sampler s(address::clamp_to_edge, filter::nearest);
    
    float2 texSize = float2(inputTexture.get_width(), inputTexture.get_height());
    float2 uv = (float2(gid) + 0.5) / texSize;
    float2 texelSize = 1.0 / texSize;
    
    // Sample 3x3 neighborhood
    float3 a = inputTexture.sample(s, uv + float2(-1, -1) * texelSize).rgb;
    float3 b = inputTexture.sample(s, uv + float2( 0, -1) * texelSize).rgb;
    float3 c = inputTexture.sample(s, uv + float2( 1, -1) * texelSize).rgb;
    float3 d = inputTexture.sample(s, uv + float2(-1,  0) * texelSize).rgb;
    float3 e = inputTexture.sample(s, uv).rgb;
    float3 f = inputTexture.sample(s, uv + float2( 1,  0) * texelSize).rgb;
    float3 g = inputTexture.sample(s, uv + float2(-1,  1) * texelSize).rgb;
    float3 h = inputTexture.sample(s, uv + float2( 0,  1) * texelSize).rgb;
    float3 i = inputTexture.sample(s, uv + float2( 1,  1) * texelSize).rgb;
    
    // Compute min and max
    float3 minRGB = min(min(min(d, e), min(f, b)), h);
    float3 maxRGB = max(max(max(d, e), max(f, b)), h);
    
    // Compute local contrast
    float3 contrast = maxRGB - minRGB;
    
    // Compute directional filtering
    float3 amp = clamp(contrast * constants.sharpness, 0.0, 1.0);
    
    // Apply sharpening
    float3 w = amp * -0.125;
    float3 result = saturate(e + (b + d + f + h) * w);
    
    outputTexture.write(float4(result, 1.0), gid);
}

// ============================================================================
// MARK: - FXAA (Fast Approximate Anti-Aliasing)
// ============================================================================

kernel void applyFXAA(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    constant AAConstants &constants [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    
    float2 texSize = float2(inputTexture.get_width(), inputTexture.get_height());
    float2 uv = (float2(gid) + 0.5) / texSize;
    float2 texelSize = 1.0 / texSize;
    
    // Sample center and 4-neighbors
    float3 rgbM = inputTexture.sample(s, uv).rgb;
    float3 rgbNW = inputTexture.sample(s, uv + float2(-1, -1) * texelSize).rgb;
    float3 rgbNE = inputTexture.sample(s, uv + float2( 1, -1) * texelSize).rgb;
    float3 rgbSW = inputTexture.sample(s, uv + float2(-1,  1) * texelSize).rgb;
    float3 rgbSE = inputTexture.sample(s, uv + float2( 1,  1) * texelSize).rgb;
    
    // Convert to luminance
    float lumM  = luminance(rgbM);
    float lumNW = luminance(rgbNW);
    float lumNE = luminance(rgbNE);
    float lumSW = luminance(rgbSW);
    float lumSE = luminance(rgbSE);
    
    float lumMin = min(lumM, min(min(lumNW, lumNE), min(lumSW, lumSE)));
    float lumMax = max(lumM, max(max(lumNW, lumNE), max(lumSW, lumSE)));
    float lumRange = lumMax - lumMin;
    
    // Early exit if contrast is too low
    if (lumRange < max(constants.threshold, lumMax * 0.125)) {
        outputTexture.write(float4(rgbM, 1.0), gid);
        return;
    }
    
    // Compute edge direction
    float lumL = (lumNW + lumNE + lumSW + lumSE) * 0.25;
    float rangeL = abs(lumL - lumM);
    float blendL = max(0.0, (rangeL / lumRange) - 0.25) * (1.0 / 0.75);
    blendL = min(blendL, constants.subpixelBlend);
    
    // Sample in the direction of the edge
    float3 rgbL = inputTexture.sample(s, uv + float2(0, blendL) * texelSize).rgb;
    
    float3 result = mix(rgbM, rgbL, blendL);
    outputTexture.write(float4(result, 1.0), gid);
}

// ============================================================================
// MARK: - Simple Bilinear Upscale
// ============================================================================

kernel void bilinearUpscale(
    texture2d<float, access::sample> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    
    float2 outputSize = float2(outputTexture.get_width(), outputTexture.get_height());
    float2 uv = (float2(gid) + 0.5) / outputSize;
    
    float4 color = inputTexture.sample(s, uv);
    outputTexture.write(color, gid);
}

// ============================================================================
// MARK: - Copy Texture
// ============================================================================

kernel void copyTexture(
    texture2d<float, access::read> inputTexture [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= outputTexture.get_width() || gid.y >= outputTexture.get_height()) {
        return;
    }
    
    float4 color = inputTexture.read(gid);
    outputTexture.write(color, gid);
}

// ============================================================================
// MARK: - Motion Vector Estimation (Block Matching)
// ============================================================================

kernel void estimateMotion(
    texture2d<float, access::sample> currentFrame [[texture(0)]],
    texture2d<float, access::sample> previousFrame [[texture(1)]],
    texture2d<float, access::write> motionVectors [[texture(2)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= motionVectors.get_width() || gid.y >= motionVectors.get_height()) {
        return;
    }
    
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    
    float2 texSize = float2(currentFrame.get_width(), currentFrame.get_height());
    float2 uv = (float2(gid) + 0.5) / float2(motionVectors.get_width(), motionVectors.get_height());
    
    const int searchRadius = 8;
    const int blockSize = 4;
    
    float3 centerCurr = currentFrame.sample(s, uv).rgb;
    
    float2 bestMotion = float2(0.0);
    float bestError = 1e10;
    
    // Search in previous frame
    for (int dy = -searchRadius; dy <= searchRadius; dy++) {
        for (int dx = -searchRadius; dx <= searchRadius; dx++) {
            float2 offset = float2(dx, dy) / texSize;
            float2 testUV = uv + offset;
            
            // Sample block and compute error
            float error = 0.0;
            for (int by = -blockSize; by <= blockSize; by++) {
                for (int bx = -blockSize; bx <= blockSize; bx++) {
                    float2 blockOffset = float2(bx, by) / texSize;
                    float3 curr = currentFrame.sample(s, uv + blockOffset).rgb;
                    float3 prev = previousFrame.sample(s, testUV + blockOffset).rgb;
                    error += length(curr - prev);
                }
            }
            
            if (error < bestError) {
                bestError = error;
                bestMotion = float2(dx, dy);
            }
        }
    }
    
    motionVectors.write(float4(bestMotion, 0.0, 1.0), gid);
}
