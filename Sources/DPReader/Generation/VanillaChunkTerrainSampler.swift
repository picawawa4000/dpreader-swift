import Foundation

@inline(__always) private func terrainFloorDiv(_ value: Int32, by divisor: Int32) -> Int32 {
    precondition(divisor > 0, "divisor must be positive")
    let quotient = value / divisor
    let remainder = value % divisor
    return remainder < 0 ? quotient - 1 : quotient
}

@inline(__always) private func terrainBiomeCoord(fromBlock block: Int32) -> Int32 {
    return terrainFloorDiv(block, by: 4)
}

@inline(__always) private func terrainBlockCoord(fromBiome biome: Int32) -> Int32 {
    return biome * 4
}

private func terrainRuntimeOnlyDecodeError(_ decoder: any Decoder, forType typeName: String) -> DecodingError {
    return DecodingError.dataCorrupted(
        DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "\(typeName) is a runtime-only density function wrapper."
        )
    )
}

private func terrainRuntimeOnlyEncodeError(_ encoder: any Encoder, forType typeName: String) -> EncodingError {
    return EncodingError.invalidValue(
        typeName,
        EncodingError.Context(
            codingPath: encoder.codingPath,
            debugDescription: "\(typeName) is a runtime-only density function wrapper."
        )
    )
}

private func sameDensityFunctionInstance(_ lhs: any DensityFunction, _ rhs: any DensityFunction) -> Bool {
    guard type(of: lhs) is AnyObject.Type, type(of: rhs) is AnyObject.Type else { return false }
    return ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
}

private enum RangeChoiceBranchStrategy {
    case unsupported
    case inputChoice
    case constant(Double)
    case unary(UnaryDensityFunction.OperationType)
    case clamp(lower: Double, upper: Double)
    case binary(
        operation: BinaryDensityFunction.OperationType,
        other: any DensityFunction,
        otherLowerBound: Double,
        otherUpperBound: Double
    )
    case binaryConstant(operation: BinaryDensityFunction.OperationType, other: Double)
}

private protocol VanillaChunkFillFunction {
    func fill(into densities: inout [Double], using sampler: VanillaChunkTerrainSampler, mode: VanillaChunkTerrainSampler.FillMode)
}

private final class VanillaChunkCache2D: DensityFunction, VanillaChunkFillFunction, DensityFunctionWrapperIntrospectable {
    private let delegate: any DensityFunction
    private var hasLastSamplingResult = false
    private var lastX: Int32 = 0
    private var lastZ: Int32 = 0
    private var lastSamplingResult: Double = 0.0

    init(wrapping delegate: any DensityFunction) {
        self.delegate = delegate
    }

    init(from decoder: any Decoder) throws {
        throw terrainRuntimeOnlyDecodeError(decoder, forType: "VanillaChunkCache2D")
    }

    func encode(to encoder: any Encoder) throws {
        throw terrainRuntimeOnlyEncodeError(encoder, forType: "VanillaChunkCache2D")
    }

    @inline(__always) func sample(at pos: PosInt3D) -> Double {
        if self.hasLastSamplingResult && self.lastX == pos.x && self.lastZ == pos.z {
            return self.lastSamplingResult
        }
        let sampled = self.delegate.sample(at: pos)
        self.hasLastSamplingResult = true
        self.lastX = pos.x
        self.lastZ = pos.z
        self.lastSamplingResult = sampled
        return sampled
    }

    func fill(into densities: inout [Double], using sampler: VanillaChunkTerrainSampler, mode: VanillaChunkTerrainSampler.FillMode) {
        // Vanilla Cache2D bypasses its cache on fill and forwards directly.
        sampler.fill(into: &densities, using: self.delegate, mode: mode)
    }

    func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return self
    }

    var wrappedDensityFunction: any DensityFunction {
        return self.delegate
    }
}

private final class VanillaChunkBenchmarkProfilingDensityFunction: DensityFunction, DensityFunctionWrapperIntrospectable {
    private let delegate: any DensityFunction
    private let profile: MutableTimedComponentBenchmark

    init(wrapping delegate: any DensityFunction, profile: MutableTimedComponentBenchmark) {
        self.delegate = delegate
        self.profile = profile
    }

    var wrappedDensityFunction: any DensityFunction {
        return self.delegate
    }

    func sample(at pos: PosInt3D) -> Double {
        return self.profile.record {
            self.delegate.sample(at: pos)
        }
    }

    func lowerBoundValue() -> Double {
        return self.delegate.lowerBoundValue()
    }

    func upperBoundValue() -> Double {
        return self.delegate.upperBoundValue()
    }

    func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return self
    }

    init(from decoder: any Decoder) throws {
        throw terrainRuntimeOnlyDecodeError(decoder, forType: "VanillaChunkBenchmarkProfilingDensityFunction")
    }

    func encode(to encoder: any Encoder) throws {
        throw terrainRuntimeOnlyEncodeError(encoder, forType: "VanillaChunkBenchmarkProfilingDensityFunction")
    }
}

private final class VanillaChunkFlatCache: DensityFunction, DensityFunctionWrapperIntrospectable {
    private let delegate: any DensityFunction
    private let startBiomeX: Int32
    private let startBiomeZ: Int32
    private let horizontalCacheSize: Int
    private var cache: [Double]

    init(wrapping delegate: any DensityFunction, using sampler: VanillaChunkTerrainSampler) {
        self.delegate = delegate
        self.startBiomeX = sampler.startBiomeX
        self.startBiomeZ = sampler.startBiomeZ
        self.horizontalCacheSize = sampler.horizontalBiomeEnd + 1
        self.cache = [Double](repeating: 0.0, count: self.horizontalCacheSize * self.horizontalCacheSize)

        for localBiomeX in 0...sampler.horizontalBiomeEnd {
            let biomeX = sampler.startBiomeX + Int32(localBiomeX)
            let blockX = terrainBlockCoord(fromBiome: biomeX)
            for localBiomeZ in 0...sampler.horizontalBiomeEnd {
                let biomeZ = sampler.startBiomeZ + Int32(localBiomeZ)
                let blockZ = terrainBlockCoord(fromBiome: biomeZ)
                let index = localBiomeX + localBiomeZ * self.horizontalCacheSize
                self.cache[index] = delegate.sample(at: PosInt3D(x: blockX, y: 0, z: blockZ))
            }
        }
    }

    init(from decoder: any Decoder) throws {
        throw terrainRuntimeOnlyDecodeError(decoder, forType: "VanillaChunkFlatCache")
    }

    func encode(to encoder: any Encoder) throws {
        throw terrainRuntimeOnlyEncodeError(encoder, forType: "VanillaChunkFlatCache")
    }

    @inline(__always) func sample(at pos: PosInt3D) -> Double {
        let biomeX = terrainBiomeCoord(fromBlock: pos.x)
        let biomeZ = terrainBiomeCoord(fromBlock: pos.z)
        let localBiomeX = biomeX - self.startBiomeX
        let localBiomeZ = biomeZ - self.startBiomeZ
        if localBiomeX >= 0
            && localBiomeZ >= 0
            && localBiomeX < Int32(self.horizontalCacheSize)
            && localBiomeZ < Int32(self.horizontalCacheSize)
        {
            let index = Int(localBiomeX + localBiomeZ * Int32(self.horizontalCacheSize))
            return self.cache[index]
        }
        return self.delegate.sample(at: pos)
    }

    func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return self
    }

    var wrappedDensityFunction: any DensityFunction {
        return self.delegate
    }
}

private final class VanillaChunkCacheOnce: DensityFunction, VanillaChunkFillFunction, DensityFunctionWrapperIntrospectable {
    private let delegate: any DensityFunction
    private let sampler: VanillaChunkTerrainSampler
    private var sampleUniqueIndex: Int64 = 0
    private var cacheOnceUniqueIndex: Int64 = 0
    private var lastSamplingResult: Double = 0.0
    private var cache: [Double]? = nil

    init(wrapping delegate: any DensityFunction, using sampler: VanillaChunkTerrainSampler) {
        self.delegate = delegate
        self.sampler = sampler
    }

    init(from decoder: any Decoder) throws {
        throw terrainRuntimeOnlyDecodeError(decoder, forType: "VanillaChunkCacheOnce")
    }

    func encode(to encoder: any Encoder) throws {
        throw terrainRuntimeOnlyEncodeError(encoder, forType: "VanillaChunkCacheOnce")
    }

    @inline(__always) func sample(at pos: PosInt3D) -> Double {
        guard self.sampler.isCurrentSamplerPos(pos) else {
            return self.delegate.sample(at: pos)
        }

        if let cache = self.cache, self.cacheOnceUniqueIndex == self.sampler.cacheOnceUniqueIndex {
            return cache[self.sampler.index]
        }

        if self.sampleUniqueIndex == self.sampler.sampleUniqueIndex {
            return self.lastSamplingResult
        }

        self.sampleUniqueIndex = self.sampler.sampleUniqueIndex
        let sampled = self.delegate.sample(at: pos)
        self.lastSamplingResult = sampled
        return sampled
    }

    func fill(into densities: inout [Double], using sampler: VanillaChunkTerrainSampler, mode: VanillaChunkTerrainSampler.FillMode) {
        if let cache = self.cache, self.cacheOnceUniqueIndex == sampler.cacheOnceUniqueIndex {
            if cache.count == densities.count {
                densities = cache
                return
            }
        }

        sampler.fill(into: &densities, using: self.delegate, mode: mode)
        self.cache = densities
        self.cacheOnceUniqueIndex = sampler.cacheOnceUniqueIndex
    }

    func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return self
    }

    var wrappedDensityFunction: any DensityFunction {
        return self.delegate
    }
}

private final class VanillaChunkCellCache: DensityFunction, VanillaChunkFillFunction, DensityFunctionWrapperIntrospectable {
    let delegate: any DensityFunction
    private let sampler: VanillaChunkTerrainSampler
    private var cache: [Double]

    init(wrapping delegate: any DensityFunction, using sampler: VanillaChunkTerrainSampler) {
        self.delegate = delegate
        self.sampler = sampler
        let count = Int(sampler.horizontalCellBlockCount * sampler.horizontalCellBlockCount * sampler.verticalCellBlockCount)
        self.cache = [Double](repeating: 0.0, count: count)
        self.sampler.register(cellCache: self)
    }

    init(from decoder: any Decoder) throws {
        throw terrainRuntimeOnlyDecodeError(decoder, forType: "VanillaChunkCellCache")
    }

    func encode(to encoder: any Encoder) throws {
        throw terrainRuntimeOnlyEncodeError(encoder, forType: "VanillaChunkCellCache")
    }

    @inline(__always) func sample(at pos: PosInt3D) -> Double {
        guard self.sampler.isCurrentSamplerPos(pos) else {
            return self.delegate.sample(at: pos)
        }
        precondition(self.sampler.isInInterpolationLoop, "Trying to sample cell cache outside interpolation loop")

        let localX = self.sampler.cellBlockX
        let localY = self.sampler.cellBlockY
        let localZ = self.sampler.cellBlockZ

        if localX >= 0
            && localY >= 0
            && localZ >= 0
            && localX < self.sampler.horizontalCellBlockCount
            && localY < self.sampler.verticalCellBlockCount
            && localZ < self.sampler.horizontalCellBlockCount
        {
            let index = ((self.sampler.verticalCellBlockCount - 1 - localY) * self.sampler.horizontalCellBlockCount + localX)
                * self.sampler.horizontalCellBlockCount + localZ
            return self.cache[Int(index)]
        }

        return self.delegate.sample(at: pos)
    }

    func refreshCache(using sampler: VanillaChunkTerrainSampler) {
        sampler.fill(into: &self.cache, using: self.delegate, mode: .cell)
    }

    func fill(into densities: inout [Double], using sampler: VanillaChunkTerrainSampler, mode: VanillaChunkTerrainSampler.FillMode) {
        sampler.fillDefault(into: &densities, using: self, mode: mode)
    }

    func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return self
    }

    var wrappedDensityFunction: any DensityFunction {
        return self.delegate
    }
}

private final class VanillaChunkInterpolatedCache: DensityFunction, VanillaChunkFillFunction, DensityFunctionWrapperIntrospectable {
    private let delegate: any DensityFunction
    private let sampler: VanillaChunkTerrainSampler
    private var startDensityBuffer: [[Double]]
    private var endDensityBuffer: [[Double]]

    private var x0y0z0: Double = 0.0
    private var x0y0z1: Double = 0.0
    private var x1y0z0: Double = 0.0
    private var x1y0z1: Double = 0.0
    private var x0y1z0: Double = 0.0
    private var x0y1z1: Double = 0.0
    private var x1y1z0: Double = 0.0
    private var x1y1z1: Double = 0.0
    private var x0z0: Double = 0.0
    private var x1z0: Double = 0.0
    private var x0z1: Double = 0.0
    private var x1z1: Double = 0.0
    private var z0: Double = 0.0
    private var z1: Double = 0.0
    private var result: Double = 0.0

    init(wrapping delegate: any DensityFunction, using sampler: VanillaChunkTerrainSampler) {
        self.delegate = delegate
        self.sampler = sampler

        let xSize = sampler.horizontalCellCount + 1
        let ySize = sampler.verticalCellCount + 1
        self.startDensityBuffer = (0..<xSize).map { _ in [Double](repeating: 0.0, count: ySize) }
        self.endDensityBuffer = (0..<xSize).map { _ in [Double](repeating: 0.0, count: ySize) }

        self.sampler.register(interpolator: self)
    }

    init(from decoder: any Decoder) throws {
        throw terrainRuntimeOnlyDecodeError(decoder, forType: "VanillaChunkInterpolatedCache")
    }

    func encode(to encoder: any Encoder) throws {
        throw terrainRuntimeOnlyEncodeError(encoder, forType: "VanillaChunkInterpolatedCache")
    }

    func fillColumnDensities(start: Bool, column: Int, using sampler: VanillaChunkTerrainSampler) {
        var densities = start ? self.startDensityBuffer[column] : self.endDensityBuffer[column]
        sampler.fill(into: &densities, using: self, mode: .interpolationColumn)
        if start {
            self.startDensityBuffer[column] = densities
        } else {
            self.endDensityBuffer[column] = densities
        }
    }

    func onSampledCellCorners(cellY: Int, cellZ: Int) {
        self.x0y0z0 = self.startDensityBuffer[cellZ][cellY]
        self.x0y0z1 = self.startDensityBuffer[cellZ + 1][cellY]
        self.x1y0z0 = self.endDensityBuffer[cellZ][cellY]
        self.x1y0z1 = self.endDensityBuffer[cellZ + 1][cellY]
        self.x0y1z0 = self.startDensityBuffer[cellZ][cellY + 1]
        self.x0y1z1 = self.startDensityBuffer[cellZ + 1][cellY + 1]
        self.x1y1z0 = self.endDensityBuffer[cellZ][cellY + 1]
        self.x1y1z1 = self.endDensityBuffer[cellZ + 1][cellY + 1]
    }

    func interpolateY(_ deltaY: Double) {
        self.x0z0 = lerp(delta: deltaY, start: self.x0y0z0, end: self.x0y1z0)
        self.x1z0 = lerp(delta: deltaY, start: self.x1y0z0, end: self.x1y1z0)
        self.x0z1 = lerp(delta: deltaY, start: self.x0y0z1, end: self.x0y1z1)
        self.x1z1 = lerp(delta: deltaY, start: self.x1y0z1, end: self.x1y1z1)
    }

    func interpolateX(_ deltaX: Double) {
        self.z0 = lerp(delta: deltaX, start: self.x0z0, end: self.x1z0)
        self.z1 = lerp(delta: deltaX, start: self.x0z1, end: self.x1z1)
    }

    func interpolateZ(_ deltaZ: Double) {
        self.result = lerp(delta: deltaZ, start: self.z0, end: self.z1)
    }

    func swapBuffers() {
        let temp = self.startDensityBuffer
        self.startDensityBuffer = self.endDensityBuffer
        self.endDensityBuffer = temp
    }

    @inline(__always) func sample(at pos: PosInt3D) -> Double {
        guard self.sampler.isCurrentSamplerPos(pos) else {
            return self.delegate.sample(at: pos)
        }
        precondition(self.sampler.isInInterpolationLoop, "Trying to sample interpolator outside interpolation loop")

        if self.sampler.isSamplingForCaches {
            return lerp3(
                deltaX: Double(self.sampler.cellBlockX) / Double(self.sampler.horizontalCellBlockCount),
                deltaY: Double(self.sampler.cellBlockY) / Double(self.sampler.verticalCellBlockCount),
                deltaZ: Double(self.sampler.cellBlockZ) / Double(self.sampler.horizontalCellBlockCount),
                x0y0z0: self.x0y0z0,
                x1y0z0: self.x1y0z0,
                x0y1z0: self.x0y1z0,
                x1y1z0: self.x1y1z0,
                x0y0z1: self.x0y0z1,
                x1y0z1: self.x1y0z1,
                x0y1z1: self.x0y1z1,
                x1y1z1: self.x1y1z1
            )
        }

        return self.result
    }

    func fill(into densities: inout [Double], using sampler: VanillaChunkTerrainSampler, mode: VanillaChunkTerrainSampler.FillMode) {
        if sampler.isSamplingForCaches {
            sampler.fillDefault(into: &densities, using: self, mode: mode)
        } else {
            sampler.fill(into: &densities, using: self.delegate, mode: mode)
        }
    }

    func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return self
    }

    var wrappedDensityFunction: any DensityFunction {
        return self.delegate
    }
}

private final class VanillaChunkTerrainInterpolator {
    private let delegate: any DensityFunction
    private let sampler: VanillaChunkTerrainSampler
    private let horizontalCellCount: Int
    private let horizontalCellBlockCount: Int32
    private let columnSampleBlockZs: [Int32]
    private let strideY: Int
    private var startDensityBuffer: [Double]
    private var endDensityBuffer: [Double]
    private var columnScratch: [Double]

    private var x0y0z0: Double = 0.0
    private var x0y0z1: Double = 0.0
    private var x1y0z0: Double = 0.0
    private var x1y0z1: Double = 0.0
    private var x0y1z0: Double = 0.0
    private var x0y1z1: Double = 0.0
    private var x1y1z0: Double = 0.0
    private var x1y1z1: Double = 0.0
    private var x0z0: Double = 0.0
    private var x1z0: Double = 0.0
    private var x0z1: Double = 0.0
    private var x1z1: Double = 0.0
    private var z0: Double = 0.0
    private var z1: Double = 0.0
    private var result: Double = 0.0

    init(delegate: any DensityFunction, using sampler: VanillaChunkTerrainSampler) {
        self.delegate = delegate
        self.sampler = sampler
        self.horizontalCellCount = sampler.horizontalCellCount
        self.horizontalCellBlockCount = sampler.horizontalCellBlockCount
        self.columnSampleBlockZs = sampler.columnSampleBlockZs
        self.strideY = sampler.verticalCellCount + 1

        let size = (sampler.horizontalCellCount + 1) * self.strideY
        self.startDensityBuffer = [Double](repeating: 0.0, count: size)
        self.endDensityBuffer = [Double](repeating: 0.0, count: size)
        self.columnScratch = [Double](repeating: 0.0, count: self.strideY)
    }

    @inline(__always) private func densityIndex(column: Int, cellY: Int) -> Int {
        return column * self.strideY + cellY
    }

    private func fillColumns(into buffer: inout [Double], atCellX cellX: Int32) {
        let blockX = cellX * self.horizontalCellBlockCount
        self.sampler.startBlockX = blockX
        self.sampler.cellBlockX = 0

        buffer.withUnsafeMutableBufferPointer { bufferPointer in
            let bufferBase = bufferPointer.baseAddress!
            for localCellZ in 0...self.horizontalCellCount {
                let blockZ = self.columnSampleBlockZs[localCellZ]
                let baseIndex = localCellZ * self.strideY
                self.sampler.startBlockZ = blockZ
                self.sampler.cellBlockZ = 0
                self.sampler.cacheOnceUniqueIndex += 1

                self.sampler.fill(into: &self.columnScratch, using: self.delegate, mode: .interpolationColumn)

                for index in 0..<self.strideY {
                    bufferBase[baseIndex + index] = self.columnScratch[index]
                }
            }
        }

        self.sampler.cacheOnceUniqueIndex += 1
    }

    @inline(__always) func fillStartColumns(atCellX cellX: Int32) {
        self.fillColumns(into: &self.startDensityBuffer, atCellX: cellX)
    }

    @inline(__always) func fillEndColumns(atCellX cellX: Int32) {
        self.fillColumns(into: &self.endDensityBuffer, atCellX: cellX)
    }

    @inline(__always) func onSampledCellCorners(cellY: Int, cellZ: Int) {
        let lowerIndex = self.densityIndex(column: cellZ, cellY: cellY)
        let lowerNextZIndex = self.densityIndex(column: cellZ + 1, cellY: cellY)
        let upperIndex = lowerIndex + 1
        let upperNextZIndex = lowerNextZIndex + 1

        self.x0y0z0 = self.startDensityBuffer[lowerIndex]
        self.x0y0z1 = self.startDensityBuffer[lowerNextZIndex]
        self.x1y0z0 = self.endDensityBuffer[lowerIndex]
        self.x1y0z1 = self.endDensityBuffer[lowerNextZIndex]
        self.x0y1z0 = self.startDensityBuffer[upperIndex]
        self.x0y1z1 = self.startDensityBuffer[upperNextZIndex]
        self.x1y1z0 = self.endDensityBuffer[upperIndex]
        self.x1y1z1 = self.endDensityBuffer[upperNextZIndex]
    }

    @inline(__always) func interpolateY(_ deltaY: Double) {
        self.x0z0 = lerp(delta: deltaY, start: self.x0y0z0, end: self.x0y1z0)
        self.x1z0 = lerp(delta: deltaY, start: self.x1y0z0, end: self.x1y1z0)
        self.x0z1 = lerp(delta: deltaY, start: self.x0y0z1, end: self.x0y1z1)
        self.x1z1 = lerp(delta: deltaY, start: self.x1y0z1, end: self.x1y1z1)
    }

    @inline(__always) func interpolateX(_ deltaX: Double) {
        self.z0 = lerp(delta: deltaX, start: self.x0z0, end: self.x1z0)
        self.z1 = lerp(delta: deltaX, start: self.x0z1, end: self.x1z1)
    }

    @inline(__always) func interpolateZ(_ deltaZ: Double) {
        self.result = lerp(delta: deltaZ, start: self.z0, end: self.z1)
    }

    @inline(__always) func swapBuffers() {
        swap(&self.startDensityBuffer, &self.endDensityBuffer)
    }

    @inline(__always)
    var currentDensity: Double {
        return self.result
    }
}

final class VanillaChunkTerrainSampler: DensityFunctionBaker {
    enum FillMode {
        case interpolationColumn
        case cell
    }

    let chunkPos: PosInt2D
    let minY: Int32
    let height: Int32

    let horizontalCellBlockCount: Int32
    let verticalCellBlockCount: Int32
    let horizontalCellCount: Int
    let verticalCellCount: Int
    let minimumCellY: Int32
    let startCellX: Int32
    let startCellZ: Int32
    let startBiomeX: Int32
    let startBiomeZ: Int32
    let horizontalBiomeEnd: Int
    let chunkStartX: Int32
    let chunkStartZ: Int32
    fileprivate let columnSampleBlockYs: [Int32]
    fileprivate let columnSampleBlockZs: [Int32]
    private let horizontalCellDeltas: [Double]
    private let verticalCellDeltas: [Double]
    private let horizontalBlockIndexOffsets: [Int]

    var isInInterpolationLoop = false
    var isSamplingForCaches = false

    var startBlockX: Int32 = 0
    var startBlockY: Int32 = 0
    var startBlockZ: Int32 = 0
    var cellBlockX: Int32 = 0
    var cellBlockY: Int32 = 0
    var cellBlockZ: Int32 = 0

    var sampleUniqueIndex: Int64 = 0
    var cacheOnceUniqueIndex: Int64 = 0
    var index = 0

    private var samplerPosDepth = 0
    private var interpolators: [VanillaChunkInterpolatedCache] = []
    private var cellCaches: [VanillaChunkCellCache] = []
    private var cacheMarkerMemo: [ObjectIdentifier: any DensityFunction] = [:]
    private var memo: [ObjectIdentifier: any DensityFunction] = [:]
    private var strippedTerrainSamplingMemo: [ObjectIdentifier: any DensityFunction] = [:]
    private var scratchBuffers: [[Double]] = []
    init(chunkPos: PosInt2D, minY: Int32, height: Int32, sizeHorizontal: Int, sizeVertical: Int) {
        self.chunkPos = chunkPos
        self.minY = minY
        self.height = height

        self.horizontalCellBlockCount = Self.cellBlockCount(fromNoiseSize: sizeHorizontal)
        self.verticalCellBlockCount = Self.cellBlockCount(fromNoiseSize: sizeVertical)
        self.horizontalCellCount = max(1, Int(Int32(ProtoChunk.sideLength) / self.horizontalCellBlockCount))
        self.verticalCellCount = max(1, Int(terrainFloorDiv(height, by: self.verticalCellBlockCount)))
        self.minimumCellY = terrainFloorDiv(minY, by: self.verticalCellBlockCount)

        self.chunkStartX = chunkPos.x &* Int32(ProtoChunk.sideLength)
        self.chunkStartZ = chunkPos.z &* Int32(ProtoChunk.sideLength)
        self.startCellX = terrainFloorDiv(self.chunkStartX, by: self.horizontalCellBlockCount)
        self.startCellZ = terrainFloorDiv(self.chunkStartZ, by: self.horizontalCellBlockCount)

        self.startBiomeX = terrainBiomeCoord(fromBlock: self.chunkStartX)
        self.startBiomeZ = terrainBiomeCoord(fromBlock: self.chunkStartZ)
        self.horizontalBiomeEnd = Int(terrainBiomeCoord(fromBlock: Int32(self.horizontalCellCount) * self.horizontalCellBlockCount))
        let horizontalCellBlockCount = Int(self.horizontalCellBlockCount)
        let verticalCellBlockCount = Int(self.verticalCellBlockCount)
        let verticalCellCount = self.verticalCellCount
        let minimumCellY = self.minimumCellY
        let verticalCellBlockCountInt32 = self.verticalCellBlockCount
        let horizontalCellCount = self.horizontalCellCount
        let startCellZ = self.startCellZ
        let horizontalCellBlockCountInt32 = self.horizontalCellBlockCount
        self.columnSampleBlockYs = (0...verticalCellCount).map { (minimumCellY + Int32($0)) * verticalCellBlockCountInt32 }
        self.columnSampleBlockZs = (0...horizontalCellCount).map { (startCellZ + Int32($0)) * horizontalCellBlockCountInt32 }
        self.horizontalCellDeltas = (0..<horizontalCellBlockCount).map { Double($0) / Double(horizontalCellBlockCount) }
        self.verticalCellDeltas = (0..<verticalCellBlockCount).map { Double($0) / Double(verticalCellBlockCount) }
        self.horizontalBlockIndexOffsets = (0..<horizontalCellBlockCount).map { $0 << 4 }
    }

    private static func cellBlockCount(fromNoiseSize size: Int) -> Int32 {
        let shift = max(0, min(30, size + 1))
        return Int32(1 << shift)
    }

    @inline(__always) private var blockX: Int32 {
        return self.startBlockX + self.cellBlockX
    }

    @inline(__always) private var blockY: Int32 {
        return self.startBlockY + self.cellBlockY
    }

    @inline(__always) private var blockZ: Int32 {
        return self.startBlockZ + self.cellBlockZ
    }

    @inline(__always) private var currentPos: PosInt3D {
        return PosInt3D(x: self.blockX, y: self.blockY, z: self.blockZ)
    }

    fileprivate func register(interpolator: VanillaChunkInterpolatedCache) {
        self.interpolators.append(interpolator)
    }

    fileprivate func register(cellCache: VanillaChunkCellCache) {
        self.cellCaches.append(cellCache)
    }

    @inline(__always) func isCurrentSamplerPos(_ pos: PosInt3D) -> Bool {
        guard self.samplerPosDepth > 0 else { return false }
        return pos.x == self.blockX && pos.y == self.blockY && pos.z == self.blockZ
    }

    @inline(__always) private func sampleAtCurrentPos(_ function: any DensityFunction) -> Double {
        self.samplerPosDepth += 1
        defer { self.samplerPosDepth -= 1 }
        return function.sample(at: self.currentPos)
    }

    private func fillNoiseDensityInterpolationColumn(into densities: inout [Double], using function: NoiseDensityFunction) {
        let blockX = self.blockX
        let blockZ = self.blockZ
        let scaledX = Double(blockX) * function.xzScaleValue
        let scaledZ = Double(blockZ) * function.xzScaleValue
        var scaledY = Double(self.minimumCellY * self.verticalCellBlockCount) * function.yScaleValue
        let scaledYStep = Double(self.verticalCellBlockCount) * function.yScaleValue
        let noise = function.noiseSampler
        for index in densities.indices {
            densities[index] = noise.sample(x: scaledX, y: scaledY, z: scaledZ)
            scaledY += scaledYStep
        }
    }

    @inline(__always) private func validateFillBufferSize(_ count: Int, mode: FillMode) {
        switch mode {
        case .interpolationColumn:
            precondition(count == self.verticalCellCount + 1, "Unexpected interpolation density buffer size")
        case .cell:
            precondition(
                count == Int(self.horizontalCellBlockCount * self.horizontalCellBlockCount * self.verticalCellBlockCount),
                "Unexpected cell density buffer size"
            )
        }
    }

    @inline(__always) private func setSamplerPosForFillIndex(_ fillIndex: Int, mode: FillMode) {
        switch mode {
        case .interpolationColumn:
            self.startBlockY = (Int32(fillIndex) + self.minimumCellY) * self.verticalCellBlockCount
            self.sampleUniqueIndex += 1
            self.cellBlockY = 0
            self.index = fillIndex
        case .cell:
            let horizontal = Int(self.horizontalCellBlockCount)
            let vertical = Int(self.verticalCellBlockCount)
            let zIndex = fillIndex % horizontal
            let horizontalSlice = fillIndex / horizontal
            let xIndex = horizontalSlice % horizontal
            let yIndex = vertical - 1 - (horizontalSlice / horizontal)
            self.cellBlockX = Int32(xIndex)
            self.cellBlockY = Int32(yIndex)
            self.cellBlockZ = Int32(zIndex)
            self.index = fillIndex
        }
    }

    private func withScratchBuffer<R>(count: Int, _ body: (inout [Double]) -> R) -> R {
        let bufferIndex = self.scratchBuffers.lastIndex { $0.count == count }
        var buffer: [Double]
        if let bufferIndex {
            buffer = self.scratchBuffers.remove(at: bufferIndex)
        } else {
            buffer = [Double](repeating: 0.0, count: count)
        }
        let result = body(&buffer)
        self.scratchBuffers.append(buffer)
        return result
    }

    private func fillBranchUsingExistingInputChoice(
        into densities: inout [Double],
        branch: any DensityFunction,
        inputChoice: any DensityFunction,
        mode: FillMode
    ) -> Bool {
        if sameDensityFunctionInstance(branch, inputChoice) {
            return true
        }
        if let constant = branch as? ConstantDensityFunction {
            let value = constant.constantValue
            for index in densities.indices {
                densities[index] = value
            }
            return true
        }
        if let unary = branch as? UnaryDensityFunction, sameDensityFunctionInstance(unary.inputOperand, inputChoice) {
            for index in densities.indices {
                let value = densities[index]
                switch unary.operationType {
                case .ABS:
                    densities[index] = abs(value)
                case .SQUARE:
                    densities[index] = value * value
                case .CUBE:
                    densities[index] = value * value * value
                case .HALF_NEGATIVE:
                    densities[index] = value < 0 ? value / 2.0 : value
                case .QUARTER_NEGATIVE:
                    densities[index] = value < 0 ? value / 4.0 : value
                case .SQUEEZE:
                    let clampedValue = clamp(value: value, lowerBound: -1.0, upperBound: 1.0)
                    densities[index] = clampedValue / 2.0 - clampedValue * clampedValue * clampedValue / 24.0
                case .INVERT:
                    densities[index] = 1.0 / value
                }
            }
            return true
        }
        if let clampFunction = branch as? ClampDensityFunction, sameDensityFunctionInstance(clampFunction.clampedInput, inputChoice) {
            for index in densities.indices {
                densities[index] = clamp(value: densities[index], lowerBound: clampFunction.minimumValue, upperBound: clampFunction.maximumValue)
            }
            return true
        }
        if let binary = branch as? BinaryDensityFunction {
            let leftIsInput = sameDensityFunctionInstance(binary.firstOperand, inputChoice)
            let rightIsInput = sameDensityFunctionInstance(binary.secondOperand, inputChoice)
            if leftIsInput || rightIsInput {
                let otherOperand = leftIsInput ? binary.secondOperand : binary.firstOperand
                switch binary.operationType {
                case .ADD:
                    if let constant = otherOperand as? ConstantDensityFunction {
                        let addend = constant.constantValue
                        for index in densities.indices {
                            densities[index] += addend
                        }
                        return true
                    }
                case .MULTIPLY:
                    if let constant = otherOperand as? ConstantDensityFunction {
                        let multiplier = constant.constantValue
                        for index in densities.indices {
                            densities[index] *= multiplier
                        }
                        return true
                    }
                case .MINIMUM, .MAXIMUM:
                    break
                }

                self.withScratchBuffer(count: densities.count) { other in
                    self.fill(into: &other, using: otherOperand, mode: mode)
                    switch binary.operationType {
                    case .ADD:
                        for index in densities.indices {
                            densities[index] += other[index]
                        }
                    case .MULTIPLY:
                        for index in densities.indices {
                            let first = densities[index]
                            densities[index] = first == 0.0 ? 0.0 : first * other[index]
                        }
                    case .MINIMUM:
                        for index in densities.indices {
                            densities[index] = min(densities[index], other[index])
                        }
                    case .MAXIMUM:
                        for index in densities.indices {
                            densities[index] = max(densities[index], other[index])
                        }
                    }
                }
                return true
            }
        }
        return false
    }

    @inline(__always)
    private func rangeChoiceBranchStrategy(
        for branch: any DensityFunction,
        inputChoice: any DensityFunction
    ) -> RangeChoiceBranchStrategy {
        if sameDensityFunctionInstance(branch, inputChoice) {
            return .inputChoice
        }
        if let constant = branch as? ConstantDensityFunction {
            return .constant(constant.constantValue)
        }
        if let unary = branch as? UnaryDensityFunction, sameDensityFunctionInstance(unary.inputOperand, inputChoice) {
            return .unary(unary.operationType)
        }
        if let clampFunction = branch as? ClampDensityFunction, sameDensityFunctionInstance(clampFunction.clampedInput, inputChoice) {
            return .clamp(lower: clampFunction.minimumValue, upper: clampFunction.maximumValue)
        }
        if let binary = branch as? BinaryDensityFunction {
            let leftIsInput = sameDensityFunctionInstance(binary.firstOperand, inputChoice)
            let rightIsInput = sameDensityFunctionInstance(binary.secondOperand, inputChoice)
            if leftIsInput || rightIsInput {
                let otherOperand = leftIsInput ? binary.secondOperand : binary.firstOperand
                if let constant = otherOperand as? ConstantDensityFunction {
                    return .binaryConstant(operation: binary.operationType, other: constant.constantValue)
                }
                return .binary(
                    operation: binary.operationType,
                    other: otherOperand,
                    otherLowerBound: otherOperand.lowerBoundValue(),
                    otherUpperBound: otherOperand.upperBoundValue()
                )
            }
        }
        return .unsupported
    }

    @inline(__always)
    private func rangeChoiceBranchStrategyNeedsSamplerPos(_ strategy: RangeChoiceBranchStrategy) -> Bool {
        switch strategy {
        case .unsupported, .binary:
            return true
        case .inputChoice, .constant, .unary, .clamp, .binaryConstant:
            return false
        }
    }

    @inline(__always)
    private func sampleRangeChoiceBranch(
        _ strategy: RangeChoiceBranchStrategy,
        inputValue: Double
    ) -> Double? {
        switch strategy {
        case .unsupported:
            return nil
        case .inputChoice:
            return inputValue
        case .constant(let constant):
            return constant
        case .unary(let operation):
            switch operation {
            case .ABS:
                return abs(inputValue)
            case .SQUARE:
                return inputValue * inputValue
            case .CUBE:
                return inputValue * inputValue * inputValue
            case .HALF_NEGATIVE:
                return inputValue < 0.0 ? inputValue / 2.0 : inputValue
            case .QUARTER_NEGATIVE:
                return inputValue < 0.0 ? inputValue / 4.0 : inputValue
            case .SQUEEZE:
                let clampedValue = clamp(value: inputValue, lowerBound: -1.0, upperBound: 1.0)
                return clampedValue / 2.0 - clampedValue * clampedValue * clampedValue / 24.0
            case .INVERT:
                return 1.0 / inputValue
            }
        case .clamp(let lower, let upper):
            return clamp(value: inputValue, lowerBound: lower, upperBound: upper)
        case .binary(let operation, let otherOperand, let otherLowerBound, let otherUpperBound):
            switch operation {
            case .ADD:
                let otherValue = self.sampleAtCurrentPos(otherOperand)
                return inputValue + otherValue
            case .MULTIPLY:
                let otherValue = self.sampleAtCurrentPos(otherOperand)
                return inputValue == 0.0 ? 0.0 : inputValue * otherValue
            case .MINIMUM:
                if inputValue < otherLowerBound {
                    return inputValue
                }
                let otherValue = self.sampleAtCurrentPos(otherOperand)
                return min(inputValue, otherValue)
            case .MAXIMUM:
                if inputValue > otherUpperBound {
                    return inputValue
                }
                let otherValue = self.sampleAtCurrentPos(otherOperand)
                return max(inputValue, otherValue)
            }
        case .binaryConstant(let operation, let otherValue):
            switch operation {
            case .ADD:
                return inputValue + otherValue
            case .MULTIPLY:
                return inputValue * otherValue
            case .MINIMUM:
                return min(inputValue, otherValue)
            case .MAXIMUM:
                return max(inputValue, otherValue)
            }
        }
    }

    private func fillUnary(into densities: inout [Double], using function: UnaryDensityFunction, mode: FillMode) {
        self.fill(into: &densities, using: function.inputOperand, mode: mode)
        for i in densities.indices {
            let value = densities[i]
            switch function.operationType {
            case .ABS:
                densities[i] = abs(value)
            case .SQUARE:
                densities[i] = value * value
            case .CUBE:
                densities[i] = value * value * value
            case .HALF_NEGATIVE:
                densities[i] = value < 0 ? value / 2.0 : value
            case .QUARTER_NEGATIVE:
                densities[i] = value < 0 ? value / 4.0 : value
            case .SQUEEZE:
                let clampedValue = clamp(value: value, lowerBound: -1.0, upperBound: 1.0)
                densities[i] = clampedValue / 2.0 - clampedValue * clampedValue * clampedValue / 24.0
            case .INVERT:
                densities[i] = 1.0 / value
            }
        }
    }

    private func fillBinary(into densities: inout [Double], using function: BinaryDensityFunction, mode: FillMode) {
        if function.operationType == .ADD {
            if let firstConstant = function.firstOperand as? ConstantDensityFunction {
                self.fill(into: &densities, using: function.secondOperand, mode: mode)
                let addend = firstConstant.constantValue
                for i in densities.indices {
                    densities[i] += addend
                }
                return
            }
            if let secondConstant = function.secondOperand as? ConstantDensityFunction {
                self.fill(into: &densities, using: function.firstOperand, mode: mode)
                let addend = secondConstant.constantValue
                for i in densities.indices {
                    densities[i] += addend
                }
                return
            }
        }

        if function.operationType == .MULTIPLY {
            if let firstConstant = function.firstOperand as? ConstantDensityFunction {
                self.fill(into: &densities, using: function.secondOperand, mode: mode)
                let multiplier = firstConstant.constantValue
                for i in densities.indices {
                    densities[i] *= multiplier
                }
                return
            }
            if let secondConstant = function.secondOperand as? ConstantDensityFunction {
                self.fill(into: &densities, using: function.firstOperand, mode: mode)
                let multiplier = secondConstant.constantValue
                for i in densities.indices {
                    densities[i] *= multiplier
                }
                return
            }
        }

        self.fill(into: &densities, using: function.firstOperand, mode: mode)
        switch function.operationType {
        case .ADD:
            self.withScratchBuffer(count: densities.count) { second in
                self.fill(into: &second, using: function.secondOperand, mode: mode)
                for i in densities.indices {
                    densities[i] += second[i]
                }
            }
        case .MULTIPLY:
            if mode == .interpolationColumn {
                self.withScratchBuffer(count: densities.count) { second in
                    self.fill(into: &second, using: function.secondOperand, mode: mode)
                    for i in densities.indices {
                        let first = densities[i]
                        densities[i] = first == 0.0 ? 0.0 : first * second[i]
                    }
                }
                return
            }
            for i in densities.indices {
                let first = densities[i]
                if first == 0.0 {
                    densities[i] = 0.0
                    continue
                }
                self.setSamplerPosForFillIndex(i, mode: mode)
                densities[i] = first * self.sampleAtCurrentPos(function.secondOperand)
            }
        case .MINIMUM:
            let secondLowerBound = function.secondOperand.lowerBoundValue()
            for i in densities.indices {
                if densities[i] < secondLowerBound {
                    continue
                }
                self.setSamplerPosForFillIndex(i, mode: mode)
                densities[i] = min(densities[i], self.sampleAtCurrentPos(function.secondOperand))
            }
        case .MAXIMUM:
            let secondUpperBound = function.secondOperand.upperBoundValue()
            for i in densities.indices {
                if densities[i] > secondUpperBound {
                    continue
                }
                self.setSamplerPosForFillIndex(i, mode: mode)
                densities[i] = max(densities[i], self.sampleAtCurrentPos(function.secondOperand))
            }
        }
    }

    private func fillClamp(into densities: inout [Double], using function: ClampDensityFunction, mode: FillMode) {
        self.fill(into: &densities, using: function.clampedInput, mode: mode)
        for i in densities.indices {
            densities[i] = clamp(value: densities[i], lowerBound: function.minimumValue, upperBound: function.maximumValue)
        }
    }

    private func fillRangeChoice(into densities: inout [Double], using function: RangeChoice, mode: FillMode) {
        if sameDensityFunctionInstance(function.whenInRangeOutput, function.whenOutOfRangeOutput) {
            self.fill(into: &densities, using: function.whenInRangeOutput, mode: mode)
            return
        }

        let inputLowerBound = function.inputLowerBoundValue
        let inputUpperBound = function.inputUpperBoundValue
        if inputLowerBound >= function.minimumInclusive && inputUpperBound < function.maximumExclusive {
            self.fill(into: &densities, using: function.whenInRangeOutput, mode: mode)
            return
        }
        if inputUpperBound < function.minimumInclusive || inputLowerBound >= function.maximumExclusive {
            self.fill(into: &densities, using: function.whenOutOfRangeOutput, mode: mode)
            return
        }

        self.fill(into: &densities, using: function.inputChoiceFunction, mode: mode)
        if mode == .interpolationColumn {
            var allInRange = true
            var allOutOfRange = true
            for input in densities {
                if input >= function.minimumInclusive && input < function.maximumExclusive {
                    allOutOfRange = false
                } else {
                    allInRange = false
                }
                if !allInRange && !allOutOfRange { break }
            }

            if allInRange {
                if !self.fillBranchUsingExistingInputChoice(
                    into: &densities,
                    branch: function.whenInRangeOutput,
                    inputChoice: function.inputChoiceFunction,
                    mode: mode
                ) {
                    self.fill(into: &densities, using: function.whenInRangeOutput, mode: mode)
                }
                return
            }
            if allOutOfRange {
                if !self.fillBranchUsingExistingInputChoice(
                    into: &densities,
                    branch: function.whenOutOfRangeOutput,
                    inputChoice: function.inputChoiceFunction,
                    mode: mode
                ) {
                    self.fill(into: &densities, using: function.whenOutOfRangeOutput, mode: mode)
                }
                return
            }
        }
        let inRangeStrategy = self.rangeChoiceBranchStrategy(for: function.whenInRangeOutput, inputChoice: function.inputChoiceFunction)
        let outOfRangeStrategy = self.rangeChoiceBranchStrategy(for: function.whenOutOfRangeOutput, inputChoice: function.inputChoiceFunction)
        let inRangeNeedsSamplerPos = self.rangeChoiceBranchStrategyNeedsSamplerPos(inRangeStrategy)
        let outOfRangeNeedsSamplerPos = self.rangeChoiceBranchStrategyNeedsSamplerPos(outOfRangeStrategy)

        if inRangeNeedsSamplerPos {
            if outOfRangeNeedsSamplerPos {
                for i in densities.indices {
                    let input = densities[i]
                    if input >= function.minimumInclusive && input < function.maximumExclusive {
                        self.setSamplerPosForFillIndex(i, mode: mode)
                        if let sampled = self.sampleRangeChoiceBranch(inRangeStrategy, inputValue: input) {
                            densities[i] = sampled
                        } else {
                            densities[i] = self.sampleAtCurrentPos(function.whenInRangeOutput)
                        }
                    } else {
                        self.setSamplerPosForFillIndex(i, mode: mode)
                        if let sampled = self.sampleRangeChoiceBranch(outOfRangeStrategy, inputValue: input) {
                            densities[i] = sampled
                        } else {
                            densities[i] = self.sampleAtCurrentPos(function.whenOutOfRangeOutput)
                        }
                    }
                }
                return
            }

            for i in densities.indices {
                let input = densities[i]
                if input >= function.minimumInclusive && input < function.maximumExclusive {
                    self.setSamplerPosForFillIndex(i, mode: mode)
                    if let sampled = self.sampleRangeChoiceBranch(inRangeStrategy, inputValue: input) {
                        densities[i] = sampled
                    } else {
                        densities[i] = self.sampleAtCurrentPos(function.whenInRangeOutput)
                    }
                } else {
                    if let sampled = self.sampleRangeChoiceBranch(outOfRangeStrategy, inputValue: input) {
                        densities[i] = sampled
                    } else {
                        densities[i] = self.sampleAtCurrentPos(function.whenOutOfRangeOutput)
                    }
                }
            }
            return
        }

        if outOfRangeNeedsSamplerPos {
            for i in densities.indices {
                let input = densities[i]
                if input >= function.minimumInclusive && input < function.maximumExclusive {
                    if let sampled = self.sampleRangeChoiceBranch(inRangeStrategy, inputValue: input) {
                        densities[i] = sampled
                    } else {
                        densities[i] = self.sampleAtCurrentPos(function.whenInRangeOutput)
                    }
                } else {
                    self.setSamplerPosForFillIndex(i, mode: mode)
                    if let sampled = self.sampleRangeChoiceBranch(outOfRangeStrategy, inputValue: input) {
                        densities[i] = sampled
                    } else {
                        densities[i] = self.sampleAtCurrentPos(function.whenOutOfRangeOutput)
                    }
                }
            }
            return
        }

        for i in densities.indices {
            let input = densities[i]
            if input >= function.minimumInclusive && input < function.maximumExclusive {
                if let sampled = self.sampleRangeChoiceBranch(inRangeStrategy, inputValue: input) {
                    densities[i] = sampled
                } else {
                    densities[i] = self.sampleAtCurrentPos(function.whenInRangeOutput)
                }
            } else {
                if let sampled = self.sampleRangeChoiceBranch(outOfRangeStrategy, inputValue: input) {
                    densities[i] = sampled
                } else {
                    densities[i] = self.sampleAtCurrentPos(function.whenOutOfRangeOutput)
                }
            }
        }
    }

    private func fillBlendDensity(into densities: inout [Double], using function: BlendDensity, mode: FillMode) {
        self.fill(into: &densities, using: function.argument, mode: mode)
        // BlendDensity is identity in our no-blending path, but vanilla still advances
        // applier position per element via Positional.fill(applier.at(i)).
        for i in densities.indices {
            self.setSamplerPosForFillIndex(i, mode: mode)
        }
    }

    private func fillWeirdScaledSampler(into densities: inout [Double], using function: WeirdScaledSampler, mode: FillMode) {
        self.fill(into: &densities, using: function.inputFunction, mode: mode)
        for i in densities.indices {
            self.setSamplerPosForFillIndex(i, mode: mode)
            let scaledValue = function.scaleValue(densities[i])
            densities[i] = scaledValue * abs(
                function.noiseSampler.sample(
                    x: Double(self.blockX) / scaledValue,
                    y: Double(self.blockY) / scaledValue,
                    z: Double(self.blockZ) / scaledValue
                )
            )
        }
    }

    func fillDefault(into densities: inout [Double], using function: any DensityFunction, mode: FillMode) {
        self.validateFillBufferSize(densities.count, mode: mode)
        for i in densities.indices {
            self.setSamplerPosForFillIndex(i, mode: mode)
            densities[i] = self.sampleAtCurrentPos(function)
        }
    }

    func fill(into densities: inout [Double], using function: any DensityFunction, mode: FillMode) {
        self.validateFillBufferSize(densities.count, mode: mode)
        if let fillable = function as? VanillaChunkFillFunction {
            fillable.fill(into: &densities, using: self, mode: mode)
            return
        }

        if let constant = function as? ConstantDensityFunction {
            let value = constant.constantValue
            for i in densities.indices {
                densities[i] = value
            }
            return
        }
        if function is BlendAlpha {
            for i in densities.indices {
                densities[i] = 1.0
            }
            return
        }
        if function is BlendOffset {
            for i in densities.indices {
                densities[i] = 0.0
            }
            return
        }
        if mode == .interpolationColumn, let noiseDensity = function as? NoiseDensityFunction {
            self.fillNoiseDensityInterpolationColumn(into: &densities, using: noiseDensity)
            return
        }
        if mode == .interpolationColumn, let interpolatedNoise = function as? InterpolatedNoise {
            interpolatedNoise.fillInterpolationColumn(
                into: &densities,
                blockX: self.blockX,
                startBlockY: self.minimumCellY * self.verticalCellBlockCount,
                blockZ: self.blockZ,
                blockYStep: self.verticalCellBlockCount
            )
            return
        }
        if let unary = function as? UnaryDensityFunction {
            self.fillUnary(into: &densities, using: unary, mode: mode)
            return
        }
        if let binary = function as? BinaryDensityFunction {
            self.fillBinary(into: &densities, using: binary, mode: mode)
            return
        }
        if let clampFunction = function as? ClampDensityFunction {
            self.fillClamp(into: &densities, using: clampFunction, mode: mode)
            return
        }
        if let rangeChoice = function as? RangeChoice {
            self.fillRangeChoice(into: &densities, using: rangeChoice, mode: mode)
            return
        }
        if let blendDensity = function as? BlendDensity {
            self.fillBlendDensity(into: &densities, using: blendDensity, mode: mode)
            return
        }
        if let weirdScaledSampler = function as? WeirdScaledSampler {
            self.fillWeirdScaledSampler(into: &densities, using: weirdScaledSampler, mode: mode)
            return
        }
        self.fillDefault(into: &densities, using: function, mode: mode)
    }

    private func sampleDensity(start: Bool, atCellX cellX: Int32) {
        self.startBlockX = cellX * self.horizontalCellBlockCount
        self.cellBlockX = 0

        for localCellZ in 0...self.horizontalCellCount {
            let cellZ = self.startCellZ + Int32(localCellZ)
            self.startBlockZ = cellZ * self.horizontalCellBlockCount
            self.cellBlockZ = 0
            self.cacheOnceUniqueIndex += 1

            for interpolator in self.interpolators {
                interpolator.fillColumnDensities(start: start, column: localCellZ, using: self)
            }
        }

        self.cacheOnceUniqueIndex += 1
    }

    func sampleStartDensity() {
        precondition(!self.isInInterpolationLoop, "Starting interpolation twice")
        self.isInInterpolationLoop = true
        self.sampleUniqueIndex = 0
        self.sampleDensity(start: true, atCellX: self.startCellX)
    }

    func sampleEndDensity(cellX: Int) {
        self.sampleDensity(start: false, atCellX: self.startCellX + Int32(cellX) + 1)
        self.startBlockX = (self.startCellX + Int32(cellX)) * self.horizontalCellBlockCount
    }

    func onSampledCellCorners(cellY: Int, cellZ: Int) {
        for interpolator in self.interpolators {
            interpolator.onSampledCellCorners(cellY: cellY, cellZ: cellZ)
        }

        self.isSamplingForCaches = true
        self.startBlockY = (Int32(cellY) + self.minimumCellY) * self.verticalCellBlockCount
        self.startBlockZ = (self.startCellZ + Int32(cellZ)) * self.horizontalCellBlockCount
        self.cacheOnceUniqueIndex += 1

        for cellCache in self.cellCaches {
            cellCache.refreshCache(using: self)
        }

        self.cacheOnceUniqueIndex += 1
        self.isSamplingForCaches = false
    }

    func interpolateY(blockY: Int32, deltaY: Double) {
        self.cellBlockY = blockY - self.startBlockY
        for interpolator in self.interpolators {
            interpolator.interpolateY(deltaY)
        }
    }

    func interpolateX(blockX: Int32, deltaX: Double) {
        self.cellBlockX = blockX - self.startBlockX
        for interpolator in self.interpolators {
            interpolator.interpolateX(deltaX)
        }
    }

    func interpolateZ(blockZ: Int32, deltaZ: Double) {
        self.cellBlockZ = blockZ - self.startBlockZ
        self.sampleUniqueIndex += 1
        for interpolator in self.interpolators {
            interpolator.interpolateZ(deltaZ)
        }
    }

    func swapBuffers() {
        for interpolator in self.interpolators {
            interpolator.swapBuffers()
        }
    }

    func stopInterpolation() {
        precondition(self.isInInterpolationLoop, "Stopping interpolation without starting")
        self.isInInterpolationLoop = false
    }

    private func generateAlignedTerrain(into chunk: ProtoChunk, using terrainInterpolator: VanillaChunkTerrainInterpolator) {
        let horizontalBlockCount = Int(self.horizontalCellBlockCount)
        let verticalBlockCount = Int(self.verticalCellBlockCount)

        for cellX in 0..<self.horizontalCellCount {
            let currentCellX = self.startCellX + Int32(cellX)
            terrainInterpolator.fillEndColumns(atCellX: currentCellX + 1)
            let baseLocalX = Int(currentCellX * self.horizontalCellBlockCount - self.chunkStartX)

            for cellZ in 0..<self.horizontalCellCount {
                let baseLocalZShift = Int((self.startCellZ + Int32(cellZ)) * self.horizontalCellBlockCount - self.chunkStartZ) << 4
                for cellY in stride(from: self.verticalCellCount - 1, through: 0, by: -1) {
                    terrainInterpolator.onSampledCellCorners(cellY: cellY, cellZ: cellZ)

                    let baseY = (Int32(cellY) + self.minimumCellY) * self.verticalCellBlockCount
                    for localCellY in stride(from: verticalBlockCount - 1, through: 0, by: -1) {
                        let localY = baseY + Int32(localCellY) - self.minY
                        terrainInterpolator.interpolateY(self.verticalCellDeltas[localCellY])
                        let section = chunk.sectionUnchecked(at: Int(localY) >> 4)
                        let sectionBlockYBase = Int(localY & 15) << 8

                        for localCellX in 0..<horizontalBlockCount {
                            terrainInterpolator.interpolateX(self.horizontalCellDeltas[localCellX])
                            let blockIndexBase = sectionBlockYBase | baseLocalZShift | (baseLocalX + localCellX)
                            for localCellZ in 0..<horizontalBlockCount {
                                terrainInterpolator.interpolateZ(self.horizontalCellDeltas[localCellZ])
                                section.setTerrainUnchecked(
                                    terrainInterpolator.currentDensity > 0.0,
                                    blockIndex: blockIndexBase | self.horizontalBlockIndexOffsets[localCellZ]
                                )
                            }
                        }
                    }
                }
            }

            terrainInterpolator.swapBuffers()
        }
    }

    private func generateClippedTerrain(into chunk: ProtoChunk, using terrainInterpolator: VanillaChunkTerrainInterpolator) {
        let horizontalBlockCount = Int(self.horizontalCellBlockCount)
        let verticalBlockCount = Int(self.verticalCellBlockCount)

        for cellX in 0..<self.horizontalCellCount {
            let currentCellX = self.startCellX + Int32(cellX)
            terrainInterpolator.fillEndColumns(atCellX: currentCellX + 1)
            let baseLocalX = Int(currentCellX * self.horizontalCellBlockCount - self.chunkStartX)

            for cellZ in 0..<self.horizontalCellCount {
                let baseLocalZ = Int((self.startCellZ + Int32(cellZ)) * self.horizontalCellBlockCount - self.chunkStartZ)
                for cellY in stride(from: self.verticalCellCount - 1, through: 0, by: -1) {
                    terrainInterpolator.onSampledCellCorners(cellY: cellY, cellZ: cellZ)

                    let baseY = (Int32(cellY) + self.minimumCellY) * self.verticalCellBlockCount
                    for localCellY in stride(from: verticalBlockCount - 1, through: 0, by: -1) {
                        let localY = baseY + Int32(localCellY) - self.minY
                        terrainInterpolator.interpolateY(self.verticalCellDeltas[localCellY])
                        let section = chunk.sectionUnchecked(at: Int(localY) >> 4)
                        let sectionBlockYBase = Int(localY & 15) << 8

                        for localCellX in 0..<horizontalBlockCount {
                            let localX = baseLocalX + localCellX
                            terrainInterpolator.interpolateX(self.horizontalCellDeltas[localCellX])
                            guard localX >= 0 && localX < ProtoChunk.sideLength else { continue }

                            for localCellZ in 0..<horizontalBlockCount {
                                let localZ = baseLocalZ + localCellZ
                                terrainInterpolator.interpolateZ(self.horizontalCellDeltas[localCellZ])
                                guard localZ >= 0 && localZ < ProtoChunk.sideLength else { continue }

                                section.setTerrainUnchecked(
                                    terrainInterpolator.currentDensity > 0.0,
                                    blockIndex: sectionBlockYBase | (localZ << 4) | localX
                                )
                            }
                        }
                    }
                }
            }

            terrainInterpolator.swapBuffers()
        }
    }

    func generateTerrain(
        into chunk: ProtoChunk,
        with terrainDensity: any DensityFunction,
        profiling terrainDensityProfile: MutableTimedComponentBenchmark? = nil
    ) {
        let directSamplingTerrainDensity = self.strippedTerrainSamplingFunction(from: terrainDensity)
        let terrainInterpolator = VanillaChunkTerrainInterpolator(
            delegate: terrainDensityProfile != nil
                ? VanillaChunkBenchmarkProfilingDensityFunction(
                    wrapping: directSamplingTerrainDensity,
                    profile: terrainDensityProfile!
                )
                : directSamplingTerrainDensity,
            using: self
        )
        let usesFullHorizontalCells =
            Int32(self.horizontalCellCount) * self.horizontalCellBlockCount == Int32(ProtoChunk.sideLength)
            && self.startCellX * self.horizontalCellBlockCount == self.chunkStartX
            && self.startCellZ * self.horizontalCellBlockCount == self.chunkStartZ

        terrainInterpolator.fillStartColumns(atCellX: self.startCellX)
        if usesFullHorizontalCells {
            self.generateAlignedTerrain(into: chunk, using: terrainInterpolator)
        } else {
            self.generateClippedTerrain(into: chunk, using: terrainInterpolator)
        }
    }

    func makeDirectPointSamplingTerrainDensity(
        from terrainDensity: any DensityFunction,
        preserveWorldScaleCaches: Bool = false
    ) -> any DensityFunction {
        return self.makeDirectPointSamplingFunction(
            from: terrainDensity,
            preserveWorldScaleCaches: preserveWorldScaleCaches
        )
    }

    private func strippedTerrainSamplingFunction(from function: any DensityFunction) -> any DensityFunction {
        if type(of: function) is AnyObject.Type {
            let object = function as AnyObject
            let key = ObjectIdentifier(object)
            if let cached = self.strippedTerrainSamplingMemo[key] {
                return cached
            }
            let stripped = self.makeStrippedTerrainSamplingFunction(from: function)
            self.strippedTerrainSamplingMemo[key] = stripped
            return stripped
        }
        return self.makeStrippedTerrainSamplingFunction(from: function)
    }

    func makeDirectPointSamplingFunction(
        from function: any DensityFunction,
        preserveWorldScaleCaches: Bool = false
    ) -> any DensityFunction {
        if preserveWorldScaleCaches, function is WorldScaleFlatCache {
            return WorldScaleFlatCache(
                wrapping: self.makeDirectPointSamplingFunction(
                    from: (function as! any DensityFunctionWrapperIntrospectable).wrappedDensityFunction,
                    preserveWorldScaleCaches: true
                )
            )
        }
        if preserveWorldScaleCaches, function is WorldScaleCache2D {
            return WorldScaleCache2D(
                wrapping: self.makeDirectPointSamplingFunction(
                    from: (function as! any DensityFunctionWrapperIntrospectable).wrappedDensityFunction,
                    preserveWorldScaleCaches: true
                )
            )
        }
        if let cacheMarker = function as? CacheMarker {
            let transformedArgument = self.makeDirectPointSamplingFunction(
                from: cacheMarker.argument,
                preserveWorldScaleCaches: preserveWorldScaleCaches
            )
            if preserveWorldScaleCaches {
                switch cacheMarker.type {
                case .flatCache:
                    return WorldScaleFlatCache(wrapping: transformedArgument)
                case .cache2D:
                    return WorldScaleCache2D(wrapping: transformedArgument)
                case .interpolated, .cacheOnce, .cacheAllInCell:
                    return transformedArgument
                }
            }
            return transformedArgument
        }
        if let wrapper = function as? any DensityFunctionWrapperIntrospectable {
            return self.makeDirectPointSamplingFunction(
                from: wrapper.wrappedDensityFunction,
                preserveWorldScaleCaches: preserveWorldScaleCaches
            )
        }
        if let unary = function as? UnaryDensityFunction {
            return UnaryDensityFunction(
                operand: self.makeDirectPointSamplingFunction(
                    from: unary.inputOperand,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                ),
                type: unary.operationType
            )
        }
        if let binary = function as? BinaryDensityFunction {
            return BinaryDensityFunction(
                firstOperand: self.makeDirectPointSamplingFunction(
                    from: binary.firstOperand,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                ),
                secondOperand: self.makeDirectPointSamplingFunction(
                    from: binary.secondOperand,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                ),
                type: binary.operationType
            )
        }
        if let clampFunction = function as? ClampDensityFunction {
            return ClampDensityFunction(
                input: self.makeDirectPointSamplingFunction(
                    from: clampFunction.clampedInput,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                ),
                lowerBound: clampFunction.minimumValue,
                upperBound: clampFunction.maximumValue
            )
        }
        if let rangeChoice = function as? RangeChoice {
            return RangeChoice(
                inputChoice: self.makeDirectPointSamplingFunction(
                    from: rangeChoice.inputChoiceFunction,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                ),
                minInclusive: rangeChoice.minimumInclusive,
                maxExclusive: rangeChoice.maximumExclusive,
                whenInRange: self.makeDirectPointSamplingFunction(
                    from: rangeChoice.whenInRangeOutput,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                ),
                whenOutOfRange: self.makeDirectPointSamplingFunction(
                    from: rangeChoice.whenOutOfRangeOutput,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                )
            )
        }
        if let shiftedNoise = function as? ShiftedNoise {
            return ShiftedNoise(
                noise: shiftedNoise.noiseSampler,
                shiftX: self.makeDirectPointSamplingFunction(
                    from: shiftedNoise.shiftXFunction,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                ),
                shiftY: self.makeDirectPointSamplingFunction(
                    from: shiftedNoise.shiftYFunction,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                ),
                shiftZ: self.makeDirectPointSamplingFunction(
                    from: shiftedNoise.shiftZFunction,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                ),
                scaleXZ: shiftedNoise.xzScaleValue,
                scaleY: shiftedNoise.yScaleValue
            )
        }
        if let noiseDensity = function as? NoiseDensityFunction,
            noiseDensity.noiseSampler.key.name == "minecraft:jagged",
            noiseDensity.xzScaleValue == 1500.0,
            noiseDensity.yScaleValue == 0.0
        {
            return ConstantDensityFunction(value: 0.0)
        }
        if let blendDensity = function as? BlendDensity {
            return BlendDensity(
                wrapping: self.makeDirectPointSamplingFunction(
                    from: blendDensity.argumentFunction,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                )
            )
        }
        if let weirdScaledSampler = function as? WeirdScaledSampler {
            return WeirdScaledSampler(
                type: weirdScaledSampler.scalingType,
                withInput: self.makeDirectPointSamplingFunction(
                    from: weirdScaledSampler.inputFunction,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                ),
                withNoise: weirdScaledSampler.noiseSampler
            )
        }
        if let splineDensity = function as? SplineDensityFunction {
            return SplineDensityFunction(withSpline: self.strippedTerrainSamplingSegment(from: splineDensity.splineSegment))
        }
        if let topSurface = function as? FindTopSurface {
            return FindTopSurface(
                density: self.makeDirectPointSamplingFunction(
                    from: topSurface.densityFunction,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                ),
                upperBound: self.makeDirectPointSamplingFunction(
                    from: topSurface.upperBoundFunction,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                ),
                lowerBound: topSurface.lowerBoundHeight,
                cellHeight: topSurface.cellHeightValue
            )
        }
        return function
    }

    private func makeStrippedTerrainSamplingFunction(from function: any DensityFunction) -> any DensityFunction {
        if function is VanillaChunkFlatCache || function is VanillaChunkCache2D {
            return function
        }
        if let wrapper = function as? any DensityFunctionWrapperIntrospectable {
            return self.strippedTerrainSamplingFunction(from: wrapper.wrappedDensityFunction)
        }
        if let unary = function as? UnaryDensityFunction {
            return UnaryDensityFunction(operand: self.strippedTerrainSamplingFunction(from: unary.inputOperand), type: unary.operationType)
        }
        if let binary = function as? BinaryDensityFunction {
            return BinaryDensityFunction(
                firstOperand: self.strippedTerrainSamplingFunction(from: binary.firstOperand),
                secondOperand: self.strippedTerrainSamplingFunction(from: binary.secondOperand),
                type: binary.operationType
            )
        }
        if let clampFunction = function as? ClampDensityFunction {
            return ClampDensityFunction(
                input: self.strippedTerrainSamplingFunction(from: clampFunction.clampedInput),
                lowerBound: clampFunction.minimumValue,
                upperBound: clampFunction.maximumValue
            )
        }
        if let rangeChoice = function as? RangeChoice {
            return RangeChoice(
                inputChoice: self.strippedTerrainSamplingFunction(from: rangeChoice.inputChoiceFunction),
                minInclusive: rangeChoice.minimumInclusive,
                maxExclusive: rangeChoice.maximumExclusive,
                whenInRange: self.strippedTerrainSamplingFunction(from: rangeChoice.whenInRangeOutput),
                whenOutOfRange: self.strippedTerrainSamplingFunction(from: rangeChoice.whenOutOfRangeOutput)
            )
        }
        if let shiftedNoise = function as? ShiftedNoise {
            return ShiftedNoise(
                noise: shiftedNoise.noiseSampler,
                shiftX: self.strippedTerrainSamplingFunction(from: shiftedNoise.shiftXFunction),
                shiftY: self.strippedTerrainSamplingFunction(from: shiftedNoise.shiftYFunction),
                shiftZ: self.strippedTerrainSamplingFunction(from: shiftedNoise.shiftZFunction),
                scaleXZ: shiftedNoise.xzScaleValue,
                scaleY: shiftedNoise.yScaleValue
            )
        }
        if let noiseDensity = function as? NoiseDensityFunction,
            noiseDensity.noiseSampler.key.name == "minecraft:jagged",
            noiseDensity.xzScaleValue == 1500.0,
            noiseDensity.yScaleValue == 0.0
        {
            // xpple's current 1.21.11 terrain reference effectively omits this
            // high-frequency jagged sampler in terrain-column generation.
            // I might reintroduce it later, but it seems to have been causing issues, so it's out for now.
            return ConstantDensityFunction(value: 0.0)
        }
        if let blendDensity = function as? BlendDensity {
            return BlendDensity(wrapping: self.strippedTerrainSamplingFunction(from: blendDensity.argumentFunction))
        }
        if let weirdScaledSampler = function as? WeirdScaledSampler {
            return WeirdScaledSampler(
                type: weirdScaledSampler.scalingType,
                withInput: self.strippedTerrainSamplingFunction(from: weirdScaledSampler.inputFunction),
                withNoise: weirdScaledSampler.noiseSampler
            )
        }
        if let splineDensity = function as? SplineDensityFunction {
            return SplineDensityFunction(withSpline: self.strippedTerrainSamplingSegment(from: splineDensity.splineSegment))
        }
        if let topSurface = function as? FindTopSurface {
            return FindTopSurface(
                density: self.strippedTerrainSamplingFunction(from: topSurface.densityFunction),
                upperBound: self.strippedTerrainSamplingFunction(from: topSurface.upperBoundFunction),
                lowerBound: topSurface.lowerBoundHeight,
                cellHeight: topSurface.cellHeightValue
            )
        }
        return function
    }

    private func strippedTerrainSamplingSegment(from segment: SplineSegment) -> SplineSegment {
        switch segment {
        case .number:
            return segment
        case .object(let object):
            return .object(
                SplineObject(
                    withInput: self.strippedTerrainSamplingFunction(from: object.inputFunction),
                    locations: object.pointLocations,
                    values: object.pointValues.map { self.strippedTerrainSamplingSegment(from: $0) },
                    derivatives: object.pointDerivatives
                )
            )
        }
    }

    func bakeDensityFunction(_ function: any DensityFunction) throws -> any DensityFunction {
        if type(of: function) is AnyObject.Type {
            let obj = function as AnyObject
            let key = ObjectIdentifier(obj)
            if let cached = self.memo[key] {
                return cached
            }
            let baked = try self.bindDensityFunction(function)
            self.memo[key] = baked
            return baked
        }
        return try self.bindDensityFunction(function)
    }

    func bake(noise: any DensityFunctionNoise) throws -> BakedNoise {
        guard let bakedNoise = noise as? BakedNoise else {
            throw BakingErrors.noiseNotAlreadyBaked(noise.key.name)
        }
        return bakedNoise
    }

    func bake(referenceDensityFunction: ReferenceDensityFunction) throws -> any DensityFunction {
        throw BakingErrors.referenceNotAlreadyBaked(referenceDensityFunction.targetKey.name)
    }

    func bake(cacheMarker: CacheMarker) throws -> any DensityFunction {
        let key = ObjectIdentifier(cacheMarker)
        if let cached = self.cacheMarkerMemo[key] {
            return cached
        }

        let bakedArgument = try self.bakeDensityFunction(cacheMarker.argument)
        let baked: any DensityFunction
        switch cacheMarker.type {
        case .interpolated:
            baked = VanillaChunkInterpolatedCache(wrapping: bakedArgument, using: self)
        case .flatCache:
            baked = VanillaChunkFlatCache(wrapping: bakedArgument, using: self)
        case .cache2D:
            baked = VanillaChunkCache2D(wrapping: bakedArgument)
        case .cacheOnce:
            baked = VanillaChunkCacheOnce(wrapping: bakedArgument, using: self)
        case .cacheAllInCell:
            baked = VanillaChunkCellCache(wrapping: bakedArgument, using: self)
        }

        self.cacheMarkerMemo[key] = baked
        return baked
    }

    func bake(beardifier: BeardifierMarker) throws -> any DensityFunction {
        return beardifier
    }

    func bake(simplexNoise: DensityFunctionSimplexNoise) throws -> DensityFunctionSimplexNoise {
        return simplexNoise
    }

    func bake(interpolatedNoise: InterpolatedNoise) throws -> InterpolatedNoise {
        return interpolatedNoise
    }

    private func bindDensityFunction(_ function: any DensityFunction) throws -> any DensityFunction {
        if function is ConstantDensityFunction
            || function is YClampedGradient
            || function is BlendAlpha
            || function is BlendOffset
            || function is BeardifierMarker
            || function is EndIslandsDensityFunction
            || function is InterpolatedNoise
            || function is ShiftDensityFunction
            || function is NoiseDensityFunction
        {
            return function
        }
        if function is VanillaChunkInterpolatedCache
            || function is VanillaChunkFlatCache
            || function is VanillaChunkCache2D
            || function is VanillaChunkCacheOnce
            || function is VanillaChunkCellCache
        {
            return function
        }
        if let cacheMarker = function as? CacheMarker {
            return try self.bake(cacheMarker: cacheMarker)
        }
        return try function.bake(withBaker: self)
    }

    private enum BakingErrors: Error {
        case noiseNotAlreadyBaked(String)
        case referenceNotAlreadyBaked(String)
    }
}
