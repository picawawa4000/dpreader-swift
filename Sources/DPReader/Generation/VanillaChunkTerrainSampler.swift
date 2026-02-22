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

private protocol VanillaChunkFillFunction {
    func fill(into densities: inout [Double], using sampler: VanillaChunkTerrainSampler, mode: VanillaChunkTerrainSampler.FillMode)
}

private final class VanillaChunkCache2D: DensityFunction, DensityFunctionWrapperIntrospectable {
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

    func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return self
    }

    var wrappedDensityFunction: any DensityFunction {
        return self.delegate
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
    private var sampleUniqueIndex: Int64 = Int64.min
    private var cacheOnceUniqueIndex: Int64 = Int64.min
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
        self.fill(into: &densities, using: function.firstOperand, mode: mode)
        switch function.operationType {
        case .ADD:
            var second = [Double](repeating: 0.0, count: densities.count)
            self.fill(into: &second, using: function.secondOperand, mode: mode)
            for i in densities.indices {
                densities[i] += second[i]
            }
        case .MULTIPLY:
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
            let secondLowerBound = densityFunctionLowerBound(function.secondOperand)
            for i in densities.indices {
                if densities[i] < secondLowerBound {
                    continue
                }
                self.setSamplerPosForFillIndex(i, mode: mode)
                densities[i] = min(densities[i], self.sampleAtCurrentPos(function.secondOperand))
            }
        case .MAXIMUM:
            let secondUpperBound = densityFunctionUpperBound(function.secondOperand)
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
            densities = [Double](repeating: constant.constantValue, count: densities.count)
            return
        }
        if function is BlendAlpha {
            densities = [Double](repeating: 1.0, count: densities.count)
            return
        }
        if function is BlendOffset {
            densities = [Double](repeating: 0.0, count: densities.count)
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

    func generateTerrain(into chunk: ProtoChunk, with terrainDensity: any DensityFunction) {
        self.sampleStartDensity()
        defer {
            if self.isInInterpolationLoop {
                self.stopInterpolation()
            }
        }

        for cellX in 0..<self.horizontalCellCount {
            self.sampleEndDensity(cellX: cellX)
            for cellZ in 0..<self.horizontalCellCount {
                for cellY in stride(from: self.verticalCellCount - 1, through: 0, by: -1) {
                    self.onSampledCellCorners(cellY: cellY, cellZ: cellZ)

                    let baseY = (Int32(cellY) + self.minimumCellY) * self.verticalCellBlockCount
                    for localCellY in stride(from: Int(self.verticalCellBlockCount) - 1, through: 0, by: -1) {
                        let blockY = baseY + Int32(localCellY)
                        let deltaY = Double(localCellY) / Double(self.verticalCellBlockCount)
                        self.interpolateY(blockY: blockY, deltaY: deltaY)

                        let localY = blockY - self.minY
                        if localY < 0 || localY >= self.height {
                            continue
                        }

                        for localCellX in 0..<Int(self.horizontalCellBlockCount) {
                            let blockX = self.startBlockX + Int32(localCellX)
                            let deltaX = Double(localCellX) / Double(self.horizontalCellBlockCount)
                            self.interpolateX(blockX: blockX, deltaX: deltaX)
                            let localX = blockX - self.chunkStartX
                            if localX < 0 || localX >= Int32(ProtoChunk.sideLength) {
                                continue
                            }

                            for localCellZ in 0..<Int(self.horizontalCellBlockCount) {
                                let blockZ = self.startBlockZ + Int32(localCellZ)
                                let deltaZ = Double(localCellZ) / Double(self.horizontalCellBlockCount)
                                self.interpolateZ(blockZ: blockZ, deltaZ: deltaZ)
                                let localZ = blockZ - self.chunkStartZ
                                if localZ < 0 || localZ >= Int32(ProtoChunk.sideLength) {
                                    continue
                                }

                                let density = self.sampleAtCurrentPos(terrainDensity)
                                chunk.setTerrain(
                                    density > 0.0,
                                    atLocal: PosInt3D(x: localX, y: localY, z: localZ)
                                )
                            }
                        }
                    }
                }
            }
            self.swapBuffers()
        }

        self.stopInterpolation()
    }

    func bakeDensityFunction(_ function: any DensityFunction) throws -> any DensityFunction {
        if type(of: function) is AnyObject.Type {
            let obj = function as AnyObject
            let key = ObjectIdentifier(obj)
            if let cached = self.memo[key] {
                return cached
            }
            let baked = try function.bake(withBaker: self)
            self.memo[key] = baked
            return baked
        }
        return try function.bake(withBaker: self)
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

    private enum BakingErrors: Error {
        case noiseNotAlreadyBaked(String)
        case referenceNotAlreadyBaked(String)
    }
}
