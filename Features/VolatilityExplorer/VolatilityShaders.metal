//
//  VolatilityShaders.metal
//  VolatilityExplorer
//
//  GPU-side mesh update for the fitted implied-volatility surface. Mirrors the
//  CPU-side PlaneVertex / VolatilitySurfaceUniforms layout defined in
//  VolatilitySurfaceMesh.swift.
//

#include <metal_stdlib>
using namespace metal;

struct PlaneVertex {
    float3 position;
    float3 normal;
    float3 color;
};

struct VolatilitySurfaceUniforms {
    uint32_t columns;
    uint32_t rows;
    float heightScale;
    /// This chain's mean Fitted IV. Must match VolatilitySurfaceMesh's
    /// Swift-side struct field-for-field, including this order.
    float heightReference;
};

/// Reads a per-vertex scalar field (IV or richness) at (col, row), clamped to
/// the grid edges.
inline float sampleField(constant float *field,
                          constant VolatilitySurfaceUniforms &uniforms,
                          int col, int row)
{
    int clampedCol = clamp(col, 0, int(uniforms.columns) - 1);
    int clampedRow = clamp(row, 0, int(uniforms.rows) - 1);
    return field[clampedRow * uniforms.columns + clampedCol];
}

/// Diverging red (cheap) -> neutral -> green (rich) color, the same mapping
/// used for both the surface and the floating contract dots. Absolute rule:
/// green exactly when richness (Actual IV minus Fitted IV, at the mesh's
/// current height) is positive — no mode-based flip.
inline float3 richnessColor(float richness)
{
    const float3 cheap = float3(0.85, 0.16, 0.16);
    const float3 neutral = float3(0.55, 0.56, 0.6);
    const float3 rich = float3(0.15, 0.85, 0.35);

    const float normalizer = 0.06;
    float magnitude = clamp(abs(richness) / normalizer, 0.0, 1.0);
    float3 target = richness >= 0.0 ? rich : cheap;
    return mix(neutral, target, magnitude);
}

/// Rewrites every vertex's position, normal, and richness color from the
/// current fitted-IV and richness fields. X and Z are fixed by the grid
/// layout; only height, its derivatives, and color ever change.
[[kernel]]
void update_volatility_vertex(device PlaneVertex *vertices [[buffer(0)]],
                               constant float *ivData [[buffer(1)]],
                               constant float *richnessData [[buffer(2)]],
                               constant VolatilitySurfaceUniforms &uniforms [[buffer(3)]],
                               uint2 gridCoords [[thread_position_in_grid]])
{
    if (gridCoords.x >= uniforms.columns || gridCoords.y >= uniforms.rows) {
        return;
    }

    // Must match VolatilitySurfaceMesh.widthSpan/depthSpan exactly, or the
    // dots (which share the same span via a separate Swift-side formula)
    // will drift out of registration with the mesh.
    const float width = 5.0;
    const float depth = 5.0;
    // Purely cosmetic exaggeration of rendered height so the CSV's real,
    // fairly narrow IV range stays perceptible once the whole graph is
    // scaled down by its parent entity. Must match
    // VolatilitySurfaceMesh.heightAmplification exactly.
    const float heightAmplification = 10.0;

    const float segmentWidth = width / float(uniforms.columns - 1);
    const float segmentDepth = depth / float(uniforms.rows - 1);

    const int col = int(gridCoords.x);
    const int row = int(gridCoords.y);

    const float centerValue = sampleField(ivData, uniforms, col, row);
    const float leftValue = sampleField(ivData, uniforms, col - 1, row);
    const float rightValue = sampleField(ivData, uniforms, col + 1, row);
    const float downValue = sampleField(ivData, uniforms, col, row - 1);
    const float upValue = sampleField(ivData, uniforms, col, row + 1);

    // Fitted IV is always positive, so without recentering the whole surface
    // would balloon upward from the entity's origin instead of forming
    // valleys and peaks around it. Shifting by this chain's own mean Fitted
    // IV before scaling makes low IV dip below y=0 and high IV rise above
    // it. Read from the uniforms buffer (computed per-chain on the Swift
    // side) rather than hardcoded, since different tickers' IV levels differ
    // enormously (AAPL under 40%, TSLA over 70%).
    const float heightReference = uniforms.heightReference;

    const float x = float(col) * segmentWidth - width * 0.5;
    const float z = float(row) * segmentDepth - depth * 0.5;
    const float y = (centerValue - heightReference) * uniforms.heightScale * heightAmplification;

    // Central-difference heightmap normal from the four grid neighbors.
    const float left = (leftValue - heightReference) * uniforms.heightScale * heightAmplification;
    const float right = (rightValue - heightReference) * uniforms.heightScale * heightAmplification;
    const float down = (downValue - heightReference) * uniforms.heightScale * heightAmplification;
    const float up = (upValue - heightReference) * uniforms.heightScale * heightAmplification;

    const float3 tangentX = float3(2.0 * segmentWidth, right - left, 0.0);
    const float3 tangentZ = float3(0.0, up - down, 2.0 * segmentDepth);
    const float3 normal = normalize(cross(tangentZ, tangentX));

    const float richness = sampleField(richnessData, uniforms, col, row);

    const uint vertexIndex = uint(row) * uniforms.columns + uint(col);
    vertices[vertexIndex].position = float3(x, y, z);
    vertices[vertexIndex].normal = normal;
    vertices[vertexIndex].color = richnessColor(richness);
}

/// Generates the (fixed) wireframe-grid index buffer once: a horizontal line
/// segment and a vertical line segment per grid cell. Rendered with `.line`
/// topology for the holographic wireframe look — each thread's writes land in
/// disjoint regions of the index buffer, so a single dispatch over the full
/// (columns, rows) grid is race-free.
[[kernel]]
void update_volatility_line_indices(device uint *indices [[buffer(0)]],
                                     constant VolatilitySurfaceUniforms &uniforms [[buffer(1)]],
                                     uint2 gridCoords [[thread_position_in_grid]])
{
    const uint columns = uniforms.columns;
    const uint rows = uniforms.rows;
    const uint horizontalSegmentsPerRow = columns - 1;
    const uint horizontalCount = horizontalSegmentsPerRow * rows;

    const uint col = gridCoords.x;
    const uint row = gridCoords.y;
    const uint vertexIndex = row * columns + col;

    // Horizontal segment: (col, row) -> (col + 1, row).
    if (col < horizontalSegmentsPerRow && row < rows) {
        const uint segmentIndex = row * horizontalSegmentsPerRow + col;
        const uint base = segmentIndex * 2;
        indices[base + 0] = vertexIndex;
        indices[base + 1] = vertexIndex + 1;
    }

    // Vertical segment: (col, row) -> (col, row + 1).
    if (col < columns && row < rows - 1) {
        const uint segmentIndex = row * columns + col;
        const uint base = horizontalCount * 2 + segmentIndex * 2;
        indices[base + 0] = vertexIndex;
        indices[base + 1] = vertexIndex + columns;
    }
}
