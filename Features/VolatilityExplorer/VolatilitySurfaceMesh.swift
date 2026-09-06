//
//  VolatilitySurfaceMesh.swift
//  VolatilityExplorer
//
//  Created by Pushkal Mondal on 31/08/26.
//

import Metal
import RealityKit
import simd

/// Vertex layout written by the GPU compute kernel. `SIMD3<Float>` has the same
/// 16-byte-aligned stride as Metal's unpacked `float3`, so this struct's memory
/// layout matches `PlaneVertex` on the shader side without a bridging header.
struct PlaneVertex {
    var position: SIMD3<Float>
    var normal: SIMD3<Float>
    /// Richness color (red = cheap, green = rich), written by the compute
    /// kernel and read by the ShaderGraphMaterial's Geometry Color node.
    var color: SIMD3<Float>
}

/// Mirrors `VolatilitySurfaceUniforms` in VolatilityShaders.metal field-for-field.
/// All members are 4 bytes wide, so there is no interior padding to keep in sync.
struct VolatilitySurfaceUniforms {
    var columns: UInt32
    var rows: UInt32
    /// Live value of the ornament's "Baseline Scale" slider.
    var heightScale: Float
    /// This chain's mean Fitted IV — different tickers span very different IV
    /// levels (AAPL under 40%, TSLA over 70%), so this travels with the data
    /// instead of being a fixed constant. See OptionsChainModel.heightReference.
    var heightReference: Float
}

/// Procedurally builds and continuously updates the fitted implied-volatility
/// surface using `LowLevelMesh`, rendered as a translucent wireframe grid.
/// Vertex positions, normals, and richness colors are recomputed on the GPU
/// every update from the latest fitted-IV and richness fields.
@MainActor
final class VolatilitySurfaceMesh {
    enum MeshError: Error {
        case deviceUnavailable
        case libraryUnavailable
        case functionUnavailable(String)
        case bufferAllocationFailed
    }

    let columns: Int
    let rows: Int
    let lowLevelMesh: LowLevelMesh

    /// Model-space span of the surface: X = strike, Z = days-to-expiration.
    /// Must match the `width`/`depth` constants in VolatilityShaders.metal
    /// exactly, or the dots (which share this same span via
    /// `localPosition(forStrikeIndex:...)`) will drift out of registration
    /// with the mesh. These are deliberately large pre-scale units — the
    /// whole graph is scaled down to a comfortable physical size by its
    /// parent entity (see VolatilitySurfaceController), not by shrinking
    /// these directly, so the strike/DTE spacing stays easy to reason about.
    let widthSpan: Float = 5.0
    let depthSpan: Float = 5.0
    /// A fixed visual exaggeration applied only to *rendered* height (both
    /// the mesh and the dots, identically) so the real, fairly narrow IV
    /// range is actually perceptible once the graph is scaled down to fit
    /// comfortably in front of the user. Purely cosmetic: it cancels out of
    /// every comparison used for color or the info pane's numbers, since it
    /// multiplies both sides of every "dot vs. mesh" comparison equally.
    static let heightAmplification: Float = 10.0
    /// Upper bound on rendered height, used only to size the mesh's fixed
    /// collision/culling bounds generously enough to contain the surface at
    /// any live height scale and any ticker's IV range.
    let maxHeightScale: Float = 15.0

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let vertexPipeline: MTLComputePipelineState
    private let indexPipeline: MTLComputePipelineState
    private let ivBuffer: MTLBuffer
    private let richnessBuffer: MTLBuffer
    private var indicesGenerated = false

    init(columns: Int, rows: Int) throws {
        precondition(columns > 1 && rows > 1, "Grid needs at least 2x2 vertices")
        self.columns = columns
        self.rows = rows

        guard let device = MTLCreateSystemDefaultDevice() else { throw MeshError.deviceUnavailable }
        guard let commandQueue = device.makeCommandQueue() else { throw MeshError.deviceUnavailable }
        guard let library = device.makeDefaultLibrary() else { throw MeshError.libraryUnavailable }

        guard let vertexFunction = library.makeFunction(name: "update_volatility_vertex") else {
            throw MeshError.functionUnavailable("update_volatility_vertex")
        }
        guard let indexFunction = library.makeFunction(name: "update_volatility_line_indices") else {
            throw MeshError.functionUnavailable("update_volatility_line_indices")
        }

        self.device = device
        self.commandQueue = commandQueue
        self.vertexPipeline = try device.makeComputePipelineState(function: vertexFunction)
        self.indexPipeline = try device.makeComputePipelineState(function: indexFunction)

        let vertexStride = MemoryLayout<PlaneVertex>.stride
        let attributes: [LowLevelMesh.Attribute] = [
            .init(semantic: .position, format: .float3, offset: MemoryLayout<PlaneVertex>.offset(of: \.position)!),
            .init(semantic: .normal, format: .float3, offset: MemoryLayout<PlaneVertex>.offset(of: \.normal)!),
            .init(semantic: .color, format: .float3, offset: MemoryLayout<PlaneVertex>.offset(of: \.color)!)
        ]
        let layouts: [LowLevelMesh.Layout] = [
            .init(bufferIndex: 0, bufferOffset: 0, bufferStride: vertexStride)
        ]

        let vertexCapacity = columns * rows
        // Wireframe grid: one 2-index line segment per horizontal gap and per
        // vertical gap (see update_volatility_line_indices), not two triangles per cell.
        let indexCapacity = 2 * ((columns - 1) * rows + columns * (rows - 1))

        let descriptor = LowLevelMesh.Descriptor(
            vertexCapacity: vertexCapacity,
            vertexAttributes: attributes,
            vertexLayouts: layouts,
            indexCapacity: indexCapacity,
            indexType: .uint32
        )
        self.lowLevelMesh = try LowLevelMesh(descriptor: descriptor)

        guard let ivBuffer = device.makeBuffer(
            length: vertexCapacity * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ), let richnessBuffer = device.makeBuffer(
            length: vertexCapacity * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ) else {
            throw MeshError.bufferAllocationFailed
        }
        self.ivBuffer = ivBuffer
        self.richnessBuffer = richnessBuffer

        update(
            fittedIVGrid: Array(repeating: 0.3, count: vertexCapacity),
            richnessGrid: Array(repeating: 0, count: vertexCapacity),
            heightScale: 1.0,
            heightReference: 0.3
        )
    }

    /// Uploads the latest fitted-IV and richness fields and dispatches the
    /// compute kernel that rewrites every vertex's height, normal, and color
    /// to match. Wireframe topology is generated once (grid dimensions never
    /// change) and thereafter only vertices update.
    func update(fittedIVGrid: [Float], richnessGrid: [Float], heightScale: Float, heightReference: Float) {
        guard fittedIVGrid.count == columns * rows, richnessGrid.count == columns * rows else { return }

        let ivContents = ivBuffer.contents().bindMemory(to: Float.self, capacity: columns * rows)
        fittedIVGrid.withUnsafeBufferPointer { source in
            ivContents.update(from: source.baseAddress!, count: source.count)
        }
        let richnessContents = richnessBuffer.contents().bindMemory(to: Float.self, capacity: columns * rows)
        richnessGrid.withUnsafeBufferPointer { source in
            richnessContents.update(from: source.baseAddress!, count: source.count)
        }

        var uniforms = VolatilitySurfaceUniforms(
            columns: UInt32(columns),
            rows: UInt32(rows),
            heightScale: heightScale,
            heightReference: heightReference
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }

        let threadgroupSize = MTLSize(width: 8, height: 8, depth: 1)
        let requiresUniformDispatch = !device.supportsFamily(.apple4)

        let vertexBuffer = lowLevelMesh.replace(bufferIndex: 0, using: commandBuffer)
        encoder.setComputePipelineState(vertexPipeline)
        encoder.setBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setBuffer(ivBuffer, offset: 0, index: 1)
        encoder.setBuffer(richnessBuffer, offset: 0, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<VolatilitySurfaceUniforms>.stride, index: 3)
        dispatch(encoder, threads: MTLSize(width: columns, height: rows, depth: 1),
                 threadgroupSize: threadgroupSize, uniformDispatch: requiresUniformDispatch)

        if !indicesGenerated {
            let indexBuffer = lowLevelMesh.replaceIndices(using: commandBuffer)
            encoder.setComputePipelineState(indexPipeline)
            encoder.setBuffer(indexBuffer, offset: 0, index: 0)
            encoder.setBytes(&uniforms, length: MemoryLayout<VolatilitySurfaceUniforms>.stride, index: 1)
            // Full (columns, rows) dispatch: each thread may contribute a
            // horizontal segment, a vertical segment, both, or neither — see the
            // kernel's own bounds checks.
            dispatch(encoder, threads: MTLSize(width: columns, height: rows, depth: 1),
                     threadgroupSize: threadgroupSize, uniformDispatch: requiresUniformDispatch)

            let halfWidth = widthSpan * 0.5
            let halfDepth = depthSpan * 0.5
            let bounds = BoundingBox(
                min: SIMD3<Float>(-halfWidth, -maxHeightScale, -halfDepth),
                max: SIMD3<Float>(halfWidth, maxHeightScale, halfDepth)
            )
            lowLevelMesh.parts.replaceAll([
                LowLevelMesh.Part(
                    indexOffset: 0,
                    indexCount: 2 * ((columns - 1) * rows + columns * (rows - 1)),
                    topology: .line,
                    materialIndex: 0,
                    bounds: bounds
                )
            ])
            indicesGenerated = true
        }

        encoder.endEncoding()
        commandBuffer.commit()
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, threads: MTLSize, threadgroupSize: MTLSize, uniformDispatch: Bool) {
        if uniformDispatch {
            let groups = MTLSize(
                width: (threads.width + threadgroupSize.width - 1) / threadgroupSize.width,
                height: (threads.height + threadgroupSize.height - 1) / threadgroupSize.height,
                depth: 1
            )
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadgroupSize)
        } else {
            encoder.dispatchThreads(threads, threadsPerThreadgroup: threadgroupSize)
        }
    }

    /// Mirrors the shader's grid-to-model-space formula, for placing entities
    /// (e.g. the floating contract dots) at the same coordinates the mesh
    /// itself computes. `heightAmplification` is applied here identically to
    /// the shader, so dots and mesh stay in registration.
    func localPosition(forStrikeIndex strikeIndex: Int, expiryIndex: Int, rawValue: Float, heightScale: Float, heightReference: Float) -> SIMD3<Float> {
        let segmentWidth = widthSpan / Float(columns - 1)
        let segmentDepth = depthSpan / Float(rows - 1)
        let x = Float(strikeIndex) * segmentWidth - widthSpan * 0.5
        let z = Float(expiryIndex) * segmentDepth - depthSpan * 0.5
        let y = (rawValue - heightReference) * heightScale * Self.heightAmplification
        return SIMD3<Float>(x, y, z)
    }

    /// Converts a dollar strike price directly into the surface's local X
    /// coordinate, for the Spot Plane (which isn't tied to a specific grid index).
    func localX(forStrike strike: Double, minStrike: Double, maxStrike: Double) -> Float {
        guard maxStrike > minStrike else { return 0 }
        let t = Float((strike - minStrike) / (maxStrike - minStrike))
        return t.clamped01 * widthSpan - widthSpan * 0.5
    }
}

private extension Float {
    var clamped01: Float { min(max(self, 0), 1) }
}
