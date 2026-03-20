// for DispatchTime
import Foundation
import TestVisible

/// Stores all of the registries needed for world generation.
final class WorldGenerationRegistries {
    var densityFunctionRegistry = Registry<DensityFunction>()
    var bakedNoiseRegistry = Registry<DoublePerlinNoise>()
    var biomeRegistry = Registry<Biome>()
    var dimensionRegistry = Registry<Dimension>()
}

/// A density function baker that does all baking steps.
final class FullDensityFunctionBaker: DensityFunctionBaker {
    fileprivate let registries: WorldGenerationRegistries
    private let seed: WorldSeed
    private let usesLegacyRandomSource: Bool
    private let randomDeriver: XoroshiroRandomSplitter
    private var initialisedFunctionIds = Set<RegistryKey<DensityFunction>>()
    private var legacyNoiseOverrides: [RegistryKey<NoiseDefinition>: DoublePerlinNoise] = [:]

    init(withSeed seed: WorldSeed, usesLegacyRandomSource: Bool, registries: WorldGenerationRegistries) {
        self.seed = seed
        self.usesLegacyRandomSource = usesLegacyRandomSource
        self.registries = registries
        var random = XoroshiroRandom(seed: seed)
        self.randomDeriver = XoroshiroRandomSplitter(seedLo: random.nextLong(), seedHi: random.nextLong())
    }

    func bake(noise: any DensityFunctionNoise) throws -> BakedNoise {
        if self.usesLegacyRandomSource, let overrideSampler = self.legacySamplerOverride(for: noise.key) {
            return BakedNoise(fromKey: noise.key, withSampler: overrideSampler)
        }
        guard let sampler = self.registries.bakedNoiseRegistry.get(noise.key.convertType()) else {
            throw WorldGenerationErrors.noiseNotPresent(noise.key.name)
        }
        return BakedNoise(fromKey: noise.key, withSampler: sampler)
    }

    func bake(referenceDensityFunction reference: ReferenceDensityFunction) throws -> any DensityFunction {
        guard let referencedFunction = self.registries.densityFunctionRegistry.get(reference.targetKey) else {
            throw WorldGenerationErrors.densityFunctionNotPresent(reference.targetKey.name)
        }

        // The referenced function has already been baked
        if self.hasBeenBaked(atKey: reference.targetKey) { return referencedFunction }

        // Bake the function and insert the baked verson
        let bakedDensityFunction = try referencedFunction.bake(withBaker: self)
        self.registries.densityFunctionRegistry.register(bakedDensityFunction, forKey: reference.targetKey)
        return bakedDensityFunction
    }

    func bake(cacheMarker: CacheMarker) throws -> any DensityFunction {
        let bakedArgument = try cacheMarker.argument.bake(withBaker: self)
        return CacheMarker(type: cacheMarker.type, wrapping: bakedArgument)
    }

    func bake(beardifier: BeardifierMarker) throws -> any DensityFunction {
        // TODO: implementation
        #warning("Unimplemented function FullDensityFunctionBaker.bake(beardifier:)!")
        return beardifier
    }

    func bake(simplexNoise: DensityFunctionSimplexNoise) throws -> DensityFunctionSimplexNoise {
        var random: any Random = CheckedRandom(seed: self.seed)
        random.skip(calls: 17292)
        return DensityFunctionSimplexNoise(withRandom: &random)
    }

    func bake(interpolatedNoise noise: InterpolatedNoise) throws -> InterpolatedNoise {
        if self.usesLegacyRandomSource {
            var random: any Random = self.createLegacyNoiseRandom(seed: 0)
            return noise.copy(withRandom: &random)
        }

        let terrainRandom = self.randomDeriver.split(usingString: LegacyNoiseKeys.terrain)
        var random: any Random = terrainRandom
        return noise.copy(withRandom: &random)
    }

    private func legacySamplerOverride(for key: RegistryKey<NoiseDefinition>) -> DoublePerlinNoise? {
        if let cachedSampler = self.legacyNoiseOverrides[key] {
            return cachedSampler
        }

        let sampler: DoublePerlinNoise?
        switch key.name {
        case LegacyNoiseKeys.temperature:
            var random: any Random = self.createLegacyNoiseRandom(seed: 0)
            sampler = DoublePerlinNoise(
                random: &random,
                firstOctave: -7,
                amplitudes: [1.0, 1.0],
                useModernInitialization: false
            )
        case LegacyNoiseKeys.vegetation:
            var random: any Random = self.createLegacyNoiseRandom(seed: 1)
            sampler = DoublePerlinNoise(
                random: &random,
                firstOctave: -7,
                amplitudes: [1.0, 1.0],
                useModernInitialization: false
            )
        case LegacyNoiseKeys.offset:
            let offsetRandom = self.randomDeriver.split(usingString: LegacyNoiseKeys.offset)
            var random: any Random = offsetRandom
            sampler = DoublePerlinNoise(
                random: &random,
                firstOctave: 0,
                amplitudes: [0.0],
                useModernInitialization: true
            )
        default:
            sampler = nil
        }

        if let sampler {
            self.legacyNoiseOverrides[key] = sampler
        }
        return sampler
    }

    private func createLegacyNoiseRandom(seed: UInt64) -> CheckedRandom {
        return CheckedRandom(seed: seed &+ seed)
    }

    private enum LegacyNoiseKeys {
        static let terrain = "minecraft:terrain"
        static let temperature = "minecraft:temperature"
        static let vegetation = "minecraft:vegetation"
        static let offset = "minecraft:offset"
    }

    /// If this function key has already been baked, return true. Otherwise, mark it as baked and return false.
    /// - Parameter key: The key to test at.
    /// - Returns: Whether the function at the key had been baked prior to the call to this function.
    func hasBeenBaked(atKey key: RegistryKey<DensityFunction>) -> Bool {
        if self.initialisedFunctionIds.contains(key) { return true }
        self.initialisedFunctionIds.insert(key)
        return false
    }
}

final class WorldScaleCache2D: DensityFunction, DensityFunctionWrapperIntrospectable {
    private let argument: any DensityFunction
    private var hasValue = false
    private var lastX: Int32 = 0
    private var lastZ: Int32 = 0
    private var lastValue: Double = 0.0

    init(wrapping argument: any DensityFunction) {
        self.argument = argument
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(String.self, forKey: .type)
        self.argument = try container.decode(DensityFunctionInitializer.self, forKey: .argument).value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:cache_2d", forKey: .type)
        try container.encode(self.argument, forKey: .argument)
    }

    @inline(__always) func sample(at pos: PosInt3D) -> Double {
        if self.hasValue && pos.x == self.lastX && pos.z == self.lastZ {
            return self.lastValue
        }
        let value = self.argument.sample(at: pos)
        self.hasValue = true
        self.lastX = pos.x
        self.lastZ = pos.z
        self.lastValue = value
        return value
    }

    func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return WorldScaleCache2D(wrapping: try self.argument.bake(withBaker: baker))
    }

    var wrappedDensityFunction: any DensityFunction {
        return self.argument
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case argument = "argument"
    }
}

final class WorldScaleFlatCache: DensityFunction, DensityFunctionWrapperIntrospectable {
    private let argument: any DensityFunction
    private var hasValue = false
    private var lastColumnX: Int32 = 0
    private var lastColumnZ: Int32 = 0
    private var lastValue: Double = 0.0

    init(wrapping argument: any DensityFunction) {
        self.argument = argument
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(String.self, forKey: .type)
        self.argument = try container.decode(DensityFunctionInitializer.self, forKey: .argument).value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:flat_cache", forKey: .type)
        try container.encode(self.argument, forKey: .argument)
    }

    @inline(__always) func sample(at pos: PosInt3D) -> Double {
        let columnX = pos.x / 4
        let columnZ = pos.z / 4
        if self.hasValue && columnX == self.lastColumnX && columnZ == self.lastColumnZ {
            return self.lastValue
        }
        let value = self.argument.sample(at: PosInt3D(x: columnX * 4, y: 0, z: columnZ * 4))
        self.hasValue = true
        self.lastColumnX = columnX
        self.lastColumnZ = columnZ
        self.lastValue = value
        return value
    }

    func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return WorldScaleFlatCache(wrapping: try self.argument.bake(withBaker: baker))
    }

    var wrappedDensityFunction: any DensityFunction {
        return self.argument
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case argument = "argument"
    }
}

final class WorldScaleDensityFunctionBaker: DensityFunctionBaker {
    private var cacheMarkerMemo: [ObjectIdentifier: any DensityFunction] = [:]
    private var memo: [ObjectIdentifier: any DensityFunction] = [:]
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
        if let cached = self.cacheMarkerMemo[key] { return cached }

        let bakedArgument = try self.bakeDensityFunction(cacheMarker.argument)
        let baked: any DensityFunction
        switch cacheMarker.type {
        case .flatCache:
            baked = WorldScaleFlatCache(wrapping: bakedArgument)
        case .cache2D:
            baked = WorldScaleCache2D(wrapping: bakedArgument)
        default:
            baked = bakedArgument
        }
        self.cacheMarkerMemo[key] = baked
        return baked
    }

    func bakeDensityFunction(_ function: any DensityFunction) throws -> any DensityFunction {
        if type(of: function) is AnyObject.Type {
            let obj = function as AnyObject
            let key = ObjectIdentifier(obj)
            if let cached = self.memo[key] { return cached }
            let baked = try function.bake(withBaker: self)
            self.memo[key] = baked
            return baked
        }
        return try function.bake(withBaker: self)
    }

    func bake(beardifier: BeardifierMarker) throws -> any DensityFunction {
        // nothing to do here
        return beardifier
    }

    func bake(simplexNoise: DensityFunctionSimplexNoise) throws -> DensityFunctionSimplexNoise {
        // pre-baked
        return simplexNoise
    }

    func bake(interpolatedNoise: InterpolatedNoise) throws -> InterpolatedNoise {
        // pre-baked
        return interpolatedNoise
    }

    private enum BakingErrors: Error {
        case noiseNotAlreadyBaked(String)
        case referenceNotAlreadyBaked(String)
    }
}

@inline(__always) private func floorDiv(_ value: Int32, by divisor: Int32) -> Int32 {
    precondition(divisor > 0, "divisor must be positive")
    let quotient = value / divisor
    let remainder = value % divisor
    return remainder < 0 ? quotient - 1 : quotient
}

@inline(__always) private func biomeCoord(fromBlock block: Int32) -> Int32 {
    return floorDiv(block, by: 4)
}

@inline(__always) private func blockCoord(fromBiome biome: Int32) -> Int32 {
    return biome * 4
}

struct ChunkSamplingBounds {
    let minX: Int32
    let maxXExclusive: Int32
    let minY: Int32
    let maxYExclusive: Int32
    let minZ: Int32
    let maxZExclusive: Int32
    let height: Int32

    init(chunkPos: PosInt2D, minY: Int32, height: Int32) {
        self.minX = chunkPos.x &* Int32(ProtoChunk.sideLength)
        self.maxXExclusive = self.minX &+ Int32(ProtoChunk.sideLength)
        self.minY = minY
        self.maxYExclusive = minY &+ height
        self.minZ = chunkPos.z &* Int32(ProtoChunk.sideLength)
        self.maxZExclusive = self.minZ &+ Int32(ProtoChunk.sideLength)
        self.height = height
    }

    @inline(__always) func contains(_ pos: PosInt3D) -> Bool {
        return self.containsColumn(x: pos.x, z: pos.z)
            && pos.y >= self.minY
            && pos.y < self.maxYExclusive
    }

    @inline(__always) func containsColumn(x: Int32, z: Int32) -> Bool {
        return x >= self.minX && x < self.maxXExclusive
            && z >= self.minZ && z < self.maxZExclusive
    }

    @inline(__always) func localColumnIndex(x: Int32, z: Int32) -> Int {
        let localX = Int(x - self.minX)
        let localZ = Int(z - self.minZ)
        return localZ * ProtoChunk.sideLength + localX
    }

    @inline(__always) func localBlockIndex(for pos: PosInt3D) -> Int {
        let localX = Int(pos.x - self.minX)
        let localY = Int(pos.y - self.minY)
        let localZ = Int(pos.z - self.minZ)
        return ((localY * ProtoChunk.sideLength + localZ) * ProtoChunk.sideLength) + localX
    }

    @inline(__always) var localBlockCount: Int {
        return ProtoChunk.sideLength * ProtoChunk.sideLength * Int(self.height)
    }
}

private struct ChunkBlockKey: Hashable {
    let x: Int32
    let y: Int32
    let z: Int32
}

private func runtimeOnlyDecodeError(_ decoder: any Decoder, forType typeName: String) -> DecodingError {
    return DecodingError.dataCorrupted(
        DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "\(typeName) is a runtime-only density function wrapper."
        )
    )
}

private func runtimeOnlyEncodeError(_ encoder: any Encoder, forType typeName: String) -> EncodingError {
    return EncodingError.invalidValue(
        typeName,
        EncodingError.Context(
            codingPath: encoder.codingPath,
            debugDescription: "\(typeName) is a runtime-only density function wrapper."
        )
    )
}

final class ChunkCache2D: DensityFunction, DensityFunctionWrapperIntrospectable {
    private let delegate: any DensityFunction
    private let bounds: ChunkSamplingBounds
    private var hasLocalValues = [Bool](repeating: false, count: ProtoChunk.sideLength * ProtoChunk.sideLength)
    private var localValues = [Double](repeating: 0.0, count: ProtoChunk.sideLength * ProtoChunk.sideLength)
    private var hasOutsideValue = false
    private var lastOutsideX: Int32 = 0
    private var lastOutsideZ: Int32 = 0
    private var lastOutsideValue: Double = 0.0

    init(wrapping delegate: any DensityFunction, bounds: ChunkSamplingBounds) {
        self.delegate = delegate
        self.bounds = bounds
    }

    init(from decoder: any Decoder) throws {
        throw runtimeOnlyDecodeError(decoder, forType: "ChunkCache2D")
    }

    func encode(to encoder: any Encoder) throws {
        throw runtimeOnlyEncodeError(encoder, forType: "ChunkCache2D")
    }

    @inline(__always) func sample(at pos: PosInt3D) -> Double {
        if self.bounds.containsColumn(x: pos.x, z: pos.z) {
            let columnIndex = self.bounds.localColumnIndex(x: pos.x, z: pos.z)
            if self.hasLocalValues[columnIndex] {
                return self.localValues[columnIndex]
            }
            let value = self.delegate.sample(at: pos)
            self.hasLocalValues[columnIndex] = true
            self.localValues[columnIndex] = value
            return value
        }

        if self.hasOutsideValue && self.lastOutsideX == pos.x && self.lastOutsideZ == pos.z {
            return self.lastOutsideValue
        }
        let value = self.delegate.sample(at: pos)
        self.hasOutsideValue = true
        self.lastOutsideX = pos.x
        self.lastOutsideZ = pos.z
        self.lastOutsideValue = value
        return value
    }

    func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return self
    }

    var wrappedDensityFunction: any DensityFunction {
        return self.delegate
    }
}

final class ChunkFlatCache: DensityFunction, DensityFunctionWrapperIntrospectable {
    private let delegate: any DensityFunction
    private let startBiomeX: Int32
    private let startBiomeZ: Int32
    private let horizontalCacheSize: Int
    private var cache: [Double]

    init(wrapping delegate: any DensityFunction, bounds: ChunkSamplingBounds) {
        self.delegate = delegate
        self.startBiomeX = biomeCoord(fromBlock: bounds.minX)
        self.startBiomeZ = biomeCoord(fromBlock: bounds.minZ)
        self.horizontalCacheSize = Int(biomeCoord(fromBlock: Int32(ProtoChunk.sideLength))) + 1
        self.cache = [Double](repeating: 0.0, count: self.horizontalCacheSize * self.horizontalCacheSize)

        for localBiomeZ in 0..<self.horizontalCacheSize {
            let biomeZ = self.startBiomeZ + Int32(localBiomeZ)
            let blockZ = blockCoord(fromBiome: biomeZ)
            for localBiomeX in 0..<self.horizontalCacheSize {
                let biomeX = self.startBiomeX + Int32(localBiomeX)
                let blockX = blockCoord(fromBiome: biomeX)
                let index = localBiomeX + localBiomeZ * self.horizontalCacheSize
                self.cache[index] = delegate.sample(at: PosInt3D(x: blockX, y: 0, z: blockZ))
            }
        }
    }

    init(from decoder: any Decoder) throws {
        throw runtimeOnlyDecodeError(decoder, forType: "ChunkFlatCache")
    }

    func encode(to encoder: any Encoder) throws {
        throw runtimeOnlyEncodeError(encoder, forType: "ChunkFlatCache")
    }

    @inline(__always) func sample(at pos: PosInt3D) -> Double {
        let biomeX = biomeCoord(fromBlock: pos.x)
        let biomeZ = biomeCoord(fromBlock: pos.z)
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

final class ChunkPositionCache: DensityFunction, DensityFunctionWrapperIntrospectable {
    private let delegate: any DensityFunction
    private let bounds: ChunkSamplingBounds
    private var hasLocalValues: [Bool]
    private var localValues: [Double]

    init(wrapping delegate: any DensityFunction, bounds: ChunkSamplingBounds) {
        self.delegate = delegate
        self.bounds = bounds
        self.hasLocalValues = [Bool](repeating: false, count: bounds.localBlockCount)
        self.localValues = [Double](repeating: 0.0, count: bounds.localBlockCount)
    }

    init(from decoder: any Decoder) throws {
        throw runtimeOnlyDecodeError(decoder, forType: "ChunkPositionCache")
    }

    func encode(to encoder: any Encoder) throws {
        throw runtimeOnlyEncodeError(encoder, forType: "ChunkPositionCache")
    }

    @inline(__always) func sample(at pos: PosInt3D) -> Double {
        guard self.bounds.contains(pos) else {
            return self.delegate.sample(at: pos)
        }

        let localIndex = self.bounds.localBlockIndex(for: pos)
        if self.hasLocalValues[localIndex] {
            return self.localValues[localIndex]
        }
        let value = self.delegate.sample(at: pos)
        self.hasLocalValues[localIndex] = true
        self.localValues[localIndex] = value
        return value
    }

    func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return self
    }

    var wrappedDensityFunction: any DensityFunction {
        return self.delegate
    }
}

final class ChunkInterpolatedCache: DensityFunction, DensityFunctionWrapperIntrospectable {
    private let delegate: any DensityFunction
    private let bounds: ChunkSamplingBounds
    private let horizontalCellBlockCount: Int32
    private let verticalCellBlockCount: Int32
    private var cornerCache: [ChunkBlockKey: Double] = [:]
    private var hasLocalValues: [Bool]
    private var localValues: [Double]

    init(
        wrapping delegate: any DensityFunction,
        bounds: ChunkSamplingBounds,
        horizontalCellBlockCount: Int32,
        verticalCellBlockCount: Int32
    ) {
        self.delegate = delegate
        self.bounds = bounds
        self.horizontalCellBlockCount = max(1, horizontalCellBlockCount)
        self.verticalCellBlockCount = max(1, verticalCellBlockCount)
        self.hasLocalValues = [Bool](repeating: false, count: bounds.localBlockCount)
        self.localValues = [Double](repeating: 0.0, count: bounds.localBlockCount)
    }

    init(from decoder: any Decoder) throws {
        throw runtimeOnlyDecodeError(decoder, forType: "ChunkInterpolatedCache")
    }

    func encode(to encoder: any Encoder) throws {
        throw runtimeOnlyEncodeError(encoder, forType: "ChunkInterpolatedCache")
    }

    private func sampleCorner(x: Int32, y: Int32, z: Int32) -> Double {
        let key = ChunkBlockKey(x: x, y: y, z: z)
        if let cached = self.cornerCache[key] {
            return cached
        }
        let sampled = self.delegate.sample(at: PosInt3D(x: x, y: y, z: z))
        self.cornerCache[key] = sampled
        return sampled
    }

    @inline(__always) func sample(at pos: PosInt3D) -> Double {
        guard self.bounds.contains(pos) else {
            return self.delegate.sample(at: pos)
        }

        let localIndex = self.bounds.localBlockIndex(for: pos)
        if self.hasLocalValues[localIndex] {
            return self.localValues[localIndex]
        }

        let cellStartX = floorDiv(pos.x, by: self.horizontalCellBlockCount) * self.horizontalCellBlockCount
        let cellStartY = floorDiv(pos.y, by: self.verticalCellBlockCount) * self.verticalCellBlockCount
        let cellStartZ = floorDiv(pos.z, by: self.horizontalCellBlockCount) * self.horizontalCellBlockCount

        let cellEndX = cellStartX + self.horizontalCellBlockCount
        let cellEndY = cellStartY + self.verticalCellBlockCount
        let cellEndZ = cellStartZ + self.horizontalCellBlockCount

        let deltaX = Double(pos.x - cellStartX) / Double(self.horizontalCellBlockCount)
        let deltaY = Double(pos.y - cellStartY) / Double(self.verticalCellBlockCount)
        let deltaZ = Double(pos.z - cellStartZ) / Double(self.horizontalCellBlockCount)

        let interpolated = lerp3(
            deltaX: deltaX,
            deltaY: deltaY,
            deltaZ: deltaZ,
            x0y0z0: self.sampleCorner(x: cellStartX, y: cellStartY, z: cellStartZ),
            x1y0z0: self.sampleCorner(x: cellEndX, y: cellStartY, z: cellStartZ),
            x0y1z0: self.sampleCorner(x: cellStartX, y: cellEndY, z: cellStartZ),
            x1y1z0: self.sampleCorner(x: cellEndX, y: cellEndY, z: cellStartZ),
            x0y0z1: self.sampleCorner(x: cellStartX, y: cellStartY, z: cellEndZ),
            x1y0z1: self.sampleCorner(x: cellEndX, y: cellStartY, z: cellEndZ),
            x0y1z1: self.sampleCorner(x: cellStartX, y: cellEndY, z: cellEndZ),
            x1y1z1: self.sampleCorner(x: cellEndX, y: cellEndY, z: cellEndZ)
        )

        self.hasLocalValues[localIndex] = true
        self.localValues[localIndex] = interpolated
        return interpolated
    }

    func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return self
    }

    var wrappedDensityFunction: any DensityFunction {
        return self.delegate
    }
}

final class ChunkDensityFunctionBaker: DensityFunctionBaker {
    private let bounds: ChunkSamplingBounds
    private let horizontalCellBlockCount: Int32
    private let verticalCellBlockCount: Int32
    private var cacheMarkerMemo: [ObjectIdentifier: any DensityFunction] = [:]
    private var memo: [ObjectIdentifier: any DensityFunction] = [:]

    init(chunkPos: PosInt2D, minY: Int32, height: Int32, sizeHorizontal: Int, sizeVertical: Int) {
        self.bounds = ChunkSamplingBounds(chunkPos: chunkPos, minY: minY, height: height)
        self.horizontalCellBlockCount = Self.cellBlockCount(fromNoiseSize: sizeHorizontal)
        self.verticalCellBlockCount = Self.cellBlockCount(fromNoiseSize: sizeVertical)
    }

    private static func cellBlockCount(fromNoiseSize size: Int) -> Int32 {
        // In vanilla this is derived from GenerationShapeConfig. We mirror it with a simplified direct mapping.
        let shift = max(0, min(30, size + 1))
        return Int32(1 << shift)
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
        case .flatCache:
            baked = ChunkFlatCache(wrapping: bakedArgument, bounds: self.bounds)
        case .cache2D:
            baked = ChunkCache2D(wrapping: bakedArgument, bounds: self.bounds)
        case .cacheOnce, .cacheAllInCell:
            baked = ChunkPositionCache(wrapping: bakedArgument, bounds: self.bounds)
        case .interpolated:
            baked = ChunkInterpolatedCache(
                wrapping: bakedArgument,
                bounds: self.bounds,
                horizontalCellBlockCount: self.horizontalCellBlockCount,
                verticalCellBlockCount: self.verticalCellBlockCount
            )
        }
        self.cacheMarkerMemo[key] = baked
        return baked
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

public final class ProtoChunkSection {
    public static let sideLength = 16
    public static let blockCount = sideLength * sideLength * sideLength
    public static let bitmapWordCount = blockCount / 64
    public static let biomeSideLength = 4
    public static let biomeCount = biomeSideLength * biomeSideLength * biomeSideLength

    private var terrainBitmap = [UInt64](repeating: 0, count: bitmapWordCount)
    private var biomes = [RegistryKey<Biome>?](repeating: nil, count: biomeCount)

    public init() {}

    public var bitmap: [UInt64] {
        return self.terrainBitmap
    }

    public var biomePalette: [RegistryKey<Biome>?] {
        return self.biomes
    }

    func clear() {
        self.terrainBitmap = [UInt64](repeating: 0, count: Self.bitmapWordCount)
        self.biomes = [RegistryKey<Biome>?](repeating: nil, count: Self.biomeCount)
    }

    @inline(__always) func setTerrainUnchecked(_ isSolid: Bool, blockIndex: Int) {
        let wordIndex = blockIndex >> 6
        let bitMask = UInt64(1) << UInt64(blockIndex & 63)
        if isSolid {
            self.terrainBitmap[wordIndex] |= bitMask
        } else {
            self.terrainBitmap[wordIndex] &= ~bitMask
        }
    }

    @inline(__always) func setTerrain(_ isSolid: Bool, at pos: PosInt3D) {
        precondition(pos.x >= 0 && pos.x < Int32(Self.sideLength), "x position out of range")
        precondition(pos.y >= 0 && pos.y < Int32(Self.sideLength), "y position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.sideLength), "z position out of range")

        let blockIndex = (Int(pos.y) << 8) | (Int(pos.z) << 4) | Int(pos.x)
        let wordIndex = blockIndex >> 6
        let bitIndex = blockIndex & 63
        let bitMask = UInt64(1) << UInt64(bitIndex)
        if isSolid {
            self.terrainBitmap[wordIndex] |= bitMask
        } else {
            self.terrainBitmap[wordIndex] &= ~bitMask
        }
    }

    @inline(__always) func isTerrain(at pos: PosInt3D) -> Bool {
        precondition(pos.x >= 0 && pos.x < Int32(Self.sideLength), "x position out of range")
        precondition(pos.y >= 0 && pos.y < Int32(Self.sideLength), "y position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.sideLength), "z position out of range")

        let blockIndex = (Int(pos.y) << 8) | (Int(pos.z) << 4) | Int(pos.x)
        let wordIndex = blockIndex >> 6
        let bitIndex = blockIndex & 63
        let bitMask = UInt64(1) << UInt64(bitIndex)
        return (self.terrainBitmap[wordIndex] & bitMask) != 0
    }

    @inline(__always) func setBiomeUnchecked(_ biome: RegistryKey<Biome>, biomeIndex: Int) {
        self.biomes[biomeIndex] = biome
    }

    @inline(__always) func setBiome(_ biome: RegistryKey<Biome>, atBiome pos: PosInt3D) {
        precondition(pos.x >= 0 && pos.x < Int32(Self.biomeSideLength), "x biome position out of range")
        precondition(pos.y >= 0 && pos.y < Int32(Self.biomeSideLength), "y biome position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.biomeSideLength), "z biome position out of range")

        let biomeIndex = (Int(pos.y) << 4) | (Int(pos.z) << 2) | Int(pos.x)
        self.biomes[biomeIndex] = biome
    }

    @inline(__always) func biome(atBiome pos: PosInt3D) -> RegistryKey<Biome>? {
        precondition(pos.x >= 0 && pos.x < Int32(Self.biomeSideLength), "x biome position out of range")
        precondition(pos.y >= 0 && pos.y < Int32(Self.biomeSideLength), "y biome position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.biomeSideLength), "z biome position out of range")

        let biomeIndex = (Int(pos.y) << 4) | (Int(pos.z) << 2) | Int(pos.x)
        return self.biomes[biomeIndex]
    }
}

/// A chunk implementation for world generation that stores terrain in 16x16x16 sections.
public final class ProtoChunk {
    public static let sideLength = 16
    public static let sectionHeight = 16
    public static let biomeSideLength = 4
    public static let biomeScale = 4

    public private(set) var minY: Int32 = 0
    public private(set) var height: Int32 = 0
    private var sections: [ProtoChunkSection] = []

    public init() {}

    public var sectionCount: Int {
        return self.sections.count
    }

    public func section(at index: Int) -> ProtoChunkSection? {
        guard index >= 0 && index < self.sections.count else { return nil }
        return self.sections[index]
    }

    public func configure(minY: Int32, height: Int32) throws {
        guard height > 0 && height % Int32(Self.sectionHeight) == 0 else {
            throw WorldGenerationErrors.invalidProtoChunkHeight(Int(height))
        }

        self.minY = minY
        self.height = height
        self.sections = (0..<Int(height / Int32(Self.sectionHeight))).map { _ in ProtoChunkSection() }
    }

    public func clearTerrain() {
        for section in self.sections {
            section.clear()
        }
    }

    public var biomeHeight: Int {
        return Int(self.height) / Self.biomeScale
    }

    @inline(__always) public func setTerrain(_ isSolid: Bool, atLocal pos: PosInt3D) {
        precondition(pos.x >= 0 && pos.x < Int32(Self.sideLength), "x position out of range")
        precondition(pos.y >= 0 && pos.y < self.height, "y position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.sideLength), "z position out of range")

        let sectionIndex = Int(pos.y) >> 4
        let localY = pos.y & 15
        self.sections[sectionIndex].setTerrain(isSolid, at: PosInt3D(x: pos.x, y: localY, z: pos.z))
    }

    @inline(__always) func setTerrainUnchecked(_ isSolid: Bool, sectionIndex: Int, blockIndex: Int) {
        self.sections[sectionIndex].setTerrainUnchecked(isSolid, blockIndex: blockIndex)
    }

    @inline(__always) func sectionUnchecked(at index: Int) -> ProtoChunkSection {
        return self.sections[index]
    }

    @inline(__always) func setBiomeUnchecked(_ biome: RegistryKey<Biome>, sectionIndex: Int, biomeIndex: Int) {
        self.sections[sectionIndex].setBiomeUnchecked(biome, biomeIndex: biomeIndex)
    }

    @inline(__always) public func setBiome(_ biome: RegistryKey<Biome>, atBiomeLocal pos: PosInt3D) {
        precondition(pos.x >= 0 && pos.x < Int32(Self.biomeSideLength), "x biome position out of range")
        precondition(pos.y >= 0 && pos.y < Int32(self.biomeHeight), "y biome position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.biomeSideLength), "z biome position out of range")

        let sectionIndex = Int(pos.y) >> 2
        let localY = pos.y & 3
        self.sections[sectionIndex].setBiome(biome, atBiome: PosInt3D(x: pos.x, y: localY, z: pos.z))
    }

    @inline(__always) public func biome(atBiomeLocal pos: PosInt3D) -> RegistryKey<Biome>? {
        precondition(pos.x >= 0 && pos.x < Int32(Self.biomeSideLength), "x biome position out of range")
        precondition(pos.y >= 0 && pos.y < Int32(self.biomeHeight), "y biome position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.biomeSideLength), "z biome position out of range")

        let sectionIndex = Int(pos.y) >> 2
        let localY = pos.y & 3
        return self.sections[sectionIndex].biome(atBiome: PosInt3D(x: pos.x, y: localY, z: pos.z))
    }

    @inline(__always) public func isTerrain(atLocal pos: PosInt3D) -> Bool {
        precondition(pos.x >= 0 && pos.x < Int32(Self.sideLength), "x position out of range")
        precondition(pos.y >= 0 && pos.y < self.height, "y position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.sideLength), "z position out of range")

        let sectionIndex = Int(pos.y) >> 4
        let localY = pos.y & 15
        return self.sections[sectionIndex].isTerrain(at: PosInt3D(x: pos.x, y: localY, z: pos.z))
    }
}

private struct ChunkBiomeDensityFunctions {
    let temperature: any DensityFunction
    let humidity: any DensityFunction
    let continentalness: any DensityFunction
    let erosion: any DensityFunction
    let weirdness: any DensityFunction
    let depth: any DensityFunction
}

private struct BiomeGenerationProfile {
    var loopNanos: UInt64 = 0
    var noiseSamplingNanos: UInt64 = 0
    var treeLookupNanos: UInt64 = 0
    var chunkWriteNanos: UInt64 = 0
    var temperatureNanos: UInt64 = 0
    var humidityNanos: UInt64 = 0
    var continentalnessNanos: UInt64 = 0
    var erosionNanos: UInt64 = 0
    var weirdnessNanos: UInt64 = 0
    var depthNanos: UInt64 = 0
    var sampleCount: Int = 0
    var skipped = false

    var exclusiveLoopNanos: UInt64 {
        let measured = self.noiseSamplingNanos &+ self.treeLookupNanos &+ self.chunkWriteNanos
        return self.loopNanos >= measured ? self.loopNanos &- measured : 0
    }

    var description: String {
        if self.skipped {
            return "biomes skipped"
        }

        return
            "biome loop excl sample/tree/write \(self.exclusiveLoopNanos)ns (\(self.exclusiveLoopNanos / 1_000_000)ms); " +
            "biome noise \(self.noiseSamplingNanos)ns (\(self.noiseSamplingNanos / 1_000_000)ms); " +
            "biome tree \(self.treeLookupNanos)ns (\(self.treeLookupNanos / 1_000_000)ms); " +
            "biome writes \(self.chunkWriteNanos)ns (\(self.chunkWriteNanos / 1_000_000)ms); " +
            "biome total \(self.loopNanos)ns (\(self.loopNanos / 1_000_000)ms); " +
            "samples \(self.sampleCount)"
    }

    var densityDescription: String {
        return
            "biome density functions: temperature \(self.temperatureNanos)ns (\(self.temperatureNanos / 1_000_000)ms); " +
            "humidity \(self.humidityNanos)ns (\(self.humidityNanos / 1_000_000)ms); " +
            "continentalness \(self.continentalnessNanos)ns (\(self.continentalnessNanos / 1_000_000)ms); " +
            "erosion \(self.erosionNanos)ns (\(self.erosionNanos / 1_000_000)ms); " +
            "weirdness \(self.weirdnessNanos)ns (\(self.weirdnessNanos / 1_000_000)ms); " +
            "depth \(self.depthNanos)ns (\(self.depthNanos / 1_000_000)ms)"
    }
}

/// The thing that actually generates worlds.
public final class WorldGenerator {
    private let worldSeed: WorldSeed
    private var config: NoiseSettings?
    private let configuredSettingsKeyName: String?
    private var configuredDimensionKey: RegistryKey<Dimension>?
    private var registries = WorldGenerationRegistries()
    private var searchTrees: [RegistryKey<Dimension>: BiomeSearchTree] = [:]
    // Terrain generation walks a shared baked density-function graph composed of reference types.
    // Serializing `generateInto` prevents concurrent cache mutation inside that shared graph.
    private let terrainGenerationLock = NSLock()

    /// Initialise this world generator.
    /// This function bakes all datapacks supplied to it, which is why it is impossible to add datapacks to an
    /// already-created world generator.
    /// - Parameters:
    ///   - seed: The seed of the world to generate.
    ///   - datapacks: The datapacks to generate. Entries from later elements in this array will override earlier ones.
    ///   - config: A registry key pointing to the noise settings to use for generation. While this can be omitted, it should not be except for debugging purposes.
    /// It is recommended (though not required) to place the vanilla datapack at the end of this array.
    public init(withWorldSeed seed: WorldSeed, usingDataPacks datapacks: [DataPack], usingSettings configKey: RegistryKey<NoiseSettings>? = nil, buildSearchTrees: Bool = true) throws {
        self.worldSeed = seed
        self.configuredSettingsKeyName = configKey?.name
        var random = XoroshiroRandom(seed: seed)
        let low = random.nextLong()
        let high = random.nextLong()

        if configKey != nil {
            var selectedConfig: NoiseSettings? = nil
            // Search backwards-to-forwards so that later datapacks override earlier ones.
            for datapack in datapacks.reversed() {
                guard let config = datapack.noiseSettingsRegistry.get(configKey!) else {
                    continue
                }
                selectedConfig = config
                break
            }
            guard let config = selectedConfig else {
                throw WorldGenerationErrors.noiseSettingsNotPresent("Requested noise settings \(configKey!.name) not found in any datapack!")
            }
            self.config = config
        }

        for datapack in datapacks {
            self.registries.densityFunctionRegistry.mergeDown(with: datapack.densityFunctionRegistry)
            self.registries.biomeRegistry.mergeDown(with: datapack.biomeRegistry)
            self.registries.dimensionRegistry.mergeDown(with: datapack.dimensionsRegistry)
        }

        if let configKey {
            self.registries.dimensionRegistry.forEach { (key: RegistryKey<Dimension>, value: Dimension) in
                guard self.configuredDimensionKey == nil else { return }
                guard let noiseGenerator = value.generator as? NoiseDimensionGenerator else { return }
                if noiseGenerator.settings == configKey.name {
                    self.configuredDimensionKey = key
                }
            }
            if self.configuredDimensionKey == nil, self.registries.dimensionRegistry.get(configKey.convertType()) != nil {
                self.configuredDimensionKey = configKey.convertType()
            }
        }

        if buildSearchTrees {
            self.searchTrees[RegistryKey(referencing: "minecraft:overworld")] = try buildBiomeSearchTree(
                from: self.registries.biomeRegistry,
                entries: getPredefinedBiomeSearchTreeData(for: "overworld")!
            )

            try self.registries.dimensionRegistry.forEach { (key: RegistryKey<Dimension>, value: Dimension) in
                if (value.generator is NoiseDimensionGenerator) && ((value.generator as! NoiseDimensionGenerator).biomeSource is MultiNoiseBiomeSource) {
                    let biomeSource = (value.generator as! NoiseDimensionGenerator).biomeSource as! MultiNoiseBiomeSource
                    if let preset = biomeSource.preset {
                        if preset == "overworld" {
                            self.searchTrees[key] = self.searchTrees[RegistryKey(referencing: "minecraft:overworld")]
                        } else {
                            /// TODO: add the nether
                            throw WorldGenerationErrors.invalidMultiNoiseBiomeSourceParameterList(preset)
                        }
                    } else if let biomes = biomeSource.biomes {
                        // Build search tree from biomes
                        do {
                            let tree = try buildBiomeSearchTree(from: self.registries.biomeRegistry, entries: biomes)
                            self.searchTrees[key] = tree
                        } catch {
                            print("WARNING: Could not build biome search tree for dimension \(key.name): \(error)!")
                        }
                    } else {
                        throw WorldGenerationErrors.noBiomesOrPresetsInMultiNoiseBiomeSource(key.name)
                    }
                }
            }
        }

        for datapack in datapacks {
            // Bake noises.
            datapack.noiseRegistry.forEach() { (key, value) in
                let noise = value.instantiate(seedLo: low, seedHi: high)
                self.registries.bakedNoiseRegistry.register(noise, forKey: key.convertType())
            }
        }

        try self.bakeDensityFunctions()
    }

    /// Convert the density functions to a usable format.
    private func bakeDensityFunctions() throws {
        // The trick here is that, if every density function in the registries is baked in an arbitrary order,
        // some references may be resolved before the function they refer to has been baked, which will result
        // in an unbaked function in the hierarchy.
        // To fix this issue, there are three main options.
        // The first option is to separate the baking process into two stages, such that references are resolved
        // before (or after) all other baking occurs. This will ensure that the full tree is walked, although with
        // a performance overhead since the tree has to be walked multiple times.
        // The second option is to only bake density functions that are required by the world's noise settings.
        // While this has the advantage of performance, it is technically challenging to implement for a number of reasons
        // and so is left unimplemented here.
        // The option used here, which the initial comment here missed, is to include a set of keys to resolved references
        // in the baker object, which can be queried to ensure that each density function only gets baked once.

        // Note: this solution is not concurrency-safe and is not a very good one in general.
        let baker = FullDensityFunctionBaker(
            withSeed: self.worldSeed,
            usesLegacyRandomSource: self.config?.legacyRandomSource ?? false,
            registries: self.registries
        )
        try self.registries.densityFunctionRegistry.forEach { (key: RegistryKey<any DensityFunction>, value: any DensityFunction) in
            if baker.hasBeenBaked(atKey: key) { return }
            baker.registries.densityFunctionRegistry.register(try value.bake(withBaker: baker), forKey: key)
        }

        if self.config != nil {
            self.config = self.config!.with(noiseRouter: try self.config!.noiseRouter.bakeAll(withBaker: baker))
        }
    }

    private func configuredChunkBiomeSearchTree() -> BiomeSearchTree? {
        if let configuredDimensionKey, let tree = self.searchTrees[configuredDimensionKey] {
            return tree
        }
        if let configuredSettingsKeyName, let tree = self.searchTrees[RegistryKey(referencing: configuredSettingsKeyName)] {
            return tree
        }
        if let overworld = self.searchTrees[RegistryKey(referencing: "minecraft:overworld")] {
            return overworld
        }
        return self.searchTrees.first?.value
    }

    private func generateBiomesIntoChunk(
        _ chunk: ProtoChunk,
        at chunkPos: PosInt2D,
        minY: Int32,
        using searchTree: BiomeSearchTree,
        with functions: ChunkBiomeDensityFunctions,
        benchmark timingsEnabled: Bool = false
    ) -> BiomeGenerationProfile {
        let chunkStartX = chunkPos.x &* Int32(ProtoChunk.sideLength)
        let chunkStartZ = chunkPos.z &* Int32(ProtoChunk.sideLength)
        let quartXs = [chunkStartX, chunkStartX + 4, chunkStartX + 8, chunkStartX + 12]
        let quartZs = [chunkStartZ, chunkStartZ + 4, chunkStartZ + 8, chunkStartZ + 12]
        let biomeHeight = chunk.biomeHeight
        let lookupState = searchTree.makeReusableLookupState()
        var profile = BiomeGenerationProfile()

        if timingsEnabled {
            let loopStart = DispatchTime.now().uptimeNanoseconds
            for localBiomeY in 0..<biomeHeight {
                let worldY = minY + Int32(localBiomeY * ProtoChunk.biomeScale)
                let section = chunk.sectionUnchecked(at: localBiomeY >> 2)
                let sectionBiomeYBase = (localBiomeY & 3) << 4

                for localBiomeZ in 0..<ProtoChunk.biomeSideLength {
                    let worldZ = quartZs[localBiomeZ]
                    let sectionBiomeZBase = sectionBiomeYBase | (localBiomeZ << 2)

                    for localBiomeX in 0..<ProtoChunk.biomeSideLength {
                        let pos = PosInt3D(x: quartXs[localBiomeX], y: worldY, z: worldZ)

                        let tTemp0 = DispatchTime.now().uptimeNanoseconds
                        let temperature = functions.temperature.sample(at: pos)
                        let tTemp1 = DispatchTime.now().uptimeNanoseconds
                        let humidity = functions.humidity.sample(at: pos)
                        let tHum1 = DispatchTime.now().uptimeNanoseconds
                        let continentalness = functions.continentalness.sample(at: pos)
                        let tCon1 = DispatchTime.now().uptimeNanoseconds
                        let erosion = functions.erosion.sample(at: pos)
                        let tEro1 = DispatchTime.now().uptimeNanoseconds
                        let weirdness = functions.weirdness.sample(at: pos)
                        let tWei1 = DispatchTime.now().uptimeNanoseconds
                        let depth = functions.depth.sample(at: pos)
                        let tDep1 = DispatchTime.now().uptimeNanoseconds

                        profile.temperatureNanos &+= tTemp1 - tTemp0
                        profile.humidityNanos &+= tHum1 - tTemp1
                        profile.continentalnessNanos &+= tCon1 - tHum1
                        profile.erosionNanos &+= tEro1 - tCon1
                        profile.weirdnessNanos &+= tWei1 - tEro1
                        profile.depthNanos &+= tDep1 - tWei1
                        profile.noiseSamplingNanos &+= tDep1 - tTemp0

                        let treeStart = DispatchTime.now().uptimeNanoseconds
                        let biome = searchTree.getUnchecked(
                            temperature: temperature,
                            humidity: humidity,
                            continentalness: continentalness,
                            erosion: erosion,
                            weirdness: weirdness,
                            depth: depth,
                            using: lookupState
                        )
                        let treeEnd = DispatchTime.now().uptimeNanoseconds
                        profile.treeLookupNanos &+= treeEnd - treeStart

                        let writeStart = DispatchTime.now().uptimeNanoseconds
                        section.setBiomeUnchecked(biome, biomeIndex: sectionBiomeZBase | localBiomeX)
                        profile.chunkWriteNanos &+= DispatchTime.now().uptimeNanoseconds - writeStart
                        profile.sampleCount += 1
                    }
                }
            }
            profile.loopNanos = DispatchTime.now().uptimeNanoseconds - loopStart
            return profile
        }

        for localBiomeY in 0..<biomeHeight {
            let worldY = minY + Int32(localBiomeY * ProtoChunk.biomeScale)
            let section = chunk.sectionUnchecked(at: localBiomeY >> 2)
            let sectionBiomeYBase = (localBiomeY & 3) << 4

            for localBiomeZ in 0..<ProtoChunk.biomeSideLength {
                let worldZ = quartZs[localBiomeZ]
                let sectionBiomeZBase = sectionBiomeYBase | (localBiomeZ << 2)

                for localBiomeX in 0..<ProtoChunk.biomeSideLength {
                    let pos = PosInt3D(x: quartXs[localBiomeX], y: worldY, z: worldZ)
                    let biome = searchTree.getUnchecked(
                        temperature: functions.temperature.sample(at: pos),
                        humidity: functions.humidity.sample(at: pos),
                        continentalness: functions.continentalness.sample(at: pos),
                        erosion: functions.erosion.sample(at: pos),
                        weirdness: functions.weirdness.sample(at: pos),
                        depth: functions.depth.sample(at: pos),
                        using: lookupState
                    )
                    section.setBiomeUnchecked(biome, biomeIndex: sectionBiomeZBase | localBiomeX)
                }
            }
        }

        profile.sampleCount = ProtoChunk.biomeSideLength * ProtoChunk.biomeSideLength * biomeHeight
        return profile
    }

    public func sampleNoisePoint(at pos: PosInt3D) -> NoisePoint {
        if self.config == nil {
            print("WARNING: WorldGenerator.sampleNoisePoint(at:) called with no noise settings!")
            return NoisePoint(temperature: 0, humidity: 0, continentalness: 0, erosion: 0, weirdness: 0, depth: 0)
        }
        return NoisePoint(
            temperature: self.config!.noiseRouter.temperature.sample(at: pos),
            humidity: self.config!.noiseRouter.humidity.sample(at: pos),
            continentalness: self.config!.noiseRouter.continents.sample(at: pos),
            erosion: self.config!.noiseRouter.erosion.sample(at: pos),
            weirdness: self.config!.noiseRouter.weirdness.sample(at: pos),
            depth: self.config!.noiseRouter.depth.sample(at: pos)
        )
    }

    public func sampleBiome(at pos: PosInt3D, in dim: RegistryKey<Dimension>) throws -> RegistryKey<Biome>? {
        let point = self.sampleNoisePoint(at: pos)
        guard let searchTree = self.searchTrees[dim] else {
            print("WARNING: No search tree for requested biome \(dim.name)!")
            return nil
        }
        return try searchTree.get(point)
    }

    /// Generates the biomes in a square.
    /// - Parameters:
    ///   - fromPos: The starting position; inclusive.
    ///   - toPos: The ending position; exclusive.
    ///   - y: The Y coordinate to sample at.
    ///   - dim: The key of the dimension to sample in.
    ///   - scale: Subsampling factor (e.g. stride; 4 means 1:4 scale). Must be > 0.
    ///   - forceNoBaking: Whether to force the function to not bake the caches, irrespective of generation size.
    ///     For debugging only (will usually lead to poorly-optimised results).
    /// - Throws: Any errors thrown by biome sampling or cache generation (if applied), or if `to` is less than `from`.
    /// - Returns: An X-major array of biomes (indexed by [Z*(to.x-from.x)+X]).
    public func generateBiomesInSquare(from fromPos: PosInt2D, to toPos: PosInt2D, atY y: Int32, in dim: RegistryKey<Dimension>, scale: Int32 = 4, forceNoBaking: Bool = false, benchmark timingsEnabled: Bool = false) throws -> [RegistryKey<Biome>]? {
        let startTime = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        var noiseSampleTime: UInt64 = 0
        var treeSampleTime: UInt64 = 0
        var temperatureTime: UInt64 = 0
        var humidityTime: UInt64 = 0
        var continentalnessTime: UInt64 = 0
        var erosionTime: UInt64 = 0
        var weirdnessTime: UInt64 = 0
        var depthTime: UInt64 = 0
        // TODO: make this not optional
        if scale <= 0 {
            throw WorldGenerationErrors.invalidScale
        }
        if fromPos.x >= toPos.x || fromPos.z >= toPos.z {
            throw WorldGenerationErrors.fromPosGreaterThanToPos
        }

        // if the generation area is small, don't bake the functions
        // if it's large, use a custom cache baker to speed up the process
        guard let searchTree = self.searchTrees[dim] else {
            print("WARNING: No search tree for requested biome \(dim.name)!")
            return nil
        }

        let useScale = scale > 1
        let fromX = useScale ? fromPos.x / scale : fromPos.x
        let fromZ = useScale ? fromPos.z / scale : fromPos.z
        let toX = useScale ? toPos.x / scale : toPos.x
        let toZ = useScale ? toPos.z / scale : toPos.z
        let width = Int(toX - fromX)
        let depth = Int(toZ - fromZ)
        let area = width * depth
        let smallAreaThreshold = 64 * 64

        var biomes: [RegistryKey<Biome>] = []
        biomes.reserveCapacity(area)

        let timingNoiseRouter = timingsEnabled ? self.config?.noiseRouter : nil
        let directNoiseRouter = self.config?.noiseRouter
        func samplePointWithTimings(
            at pos: PosInt3D,
            temperature: any DensityFunction,
            humidity: any DensityFunction,
            continentalness: any DensityFunction,
            erosion: any DensityFunction,
            weirdness: any DensityFunction,
            depth: any DensityFunction
        ) -> NoisePoint {
            let tTemp0 = DispatchTime.now().uptimeNanoseconds
            let temperatureValue = temperature.sample(at: pos)
            let tTemp1 = DispatchTime.now().uptimeNanoseconds
            let tHum0 = DispatchTime.now().uptimeNanoseconds
            let humidityValue = humidity.sample(at: pos)
            let tHum1 = DispatchTime.now().uptimeNanoseconds
            let tCon0 = DispatchTime.now().uptimeNanoseconds
            let continentalnessValue = continentalness.sample(at: pos)
            let tCon1 = DispatchTime.now().uptimeNanoseconds
            let tEro0 = DispatchTime.now().uptimeNanoseconds
            let erosionValue = erosion.sample(at: pos)
            let tEro1 = DispatchTime.now().uptimeNanoseconds
            let tWei0 = DispatchTime.now().uptimeNanoseconds
            let weirdnessValue = weirdness.sample(at: pos)
            let tWei1 = DispatchTime.now().uptimeNanoseconds
            let tDep0 = DispatchTime.now().uptimeNanoseconds
            let depthValue = depth.sample(at: pos)
            let tDep1 = DispatchTime.now().uptimeNanoseconds
            temperatureTime += tTemp1 - tTemp0
            humidityTime += tHum1 - tHum0
            continentalnessTime += tCon1 - tCon0
            erosionTime += tEro1 - tEro0
            weirdnessTime += tWei1 - tWei0
            depthTime += tDep1 - tDep0
            return NoisePoint(
                temperature: temperatureValue,
                humidity: humidityValue,
                continentalness: continentalnessValue,
                erosion: erosionValue,
                weirdness: weirdnessValue,
                depth: depthValue
            )
        }

        if area <= smallAreaThreshold || self.config == nil || forceNoBaking {
            if useScale {
                let loopStart = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
                let startWorldX = fromX * scale
                var worldZ = fromZ * scale
                for _ in fromZ..<toZ {
                    var worldX = startWorldX
                    for _ in fromX..<toX {
                        let pos = PosInt3D(x: worldX, y: y, z: worldZ)
                        if timingsEnabled {
                            let t0 = DispatchTime.now().uptimeNanoseconds
                            let point: NoisePoint
                            if let noiseRouter = timingNoiseRouter {
                                point = samplePointWithTimings(
                                    at: pos,
                                    temperature: noiseRouter.temperature,
                                    humidity: noiseRouter.humidity,
                                    continentalness: noiseRouter.continents,
                                    erosion: noiseRouter.erosion,
                                    weirdness: noiseRouter.weirdness,
                                    depth: noiseRouter.depth
                                )
                            } else {
                                point = self.sampleNoisePoint(at: pos)
                            }
                            let t1 = DispatchTime.now().uptimeNanoseconds
                            let biome = searchTree.getUnchecked(point)
                            let t2 = DispatchTime.now().uptimeNanoseconds
                            noiseSampleTime += t1 - t0
                            treeSampleTime += t2 - t1
                            biomes.append(biome)
                        } else {
                            let biome: RegistryKey<Biome>
                            if let noiseRouter = directNoiseRouter {
                                biome = searchTree.getUnchecked(
                                    temperature: noiseRouter.temperature.sample(at: pos),
                                    humidity: noiseRouter.humidity.sample(at: pos),
                                    continentalness: noiseRouter.continents.sample(at: pos),
                                    erosion: noiseRouter.erosion.sample(at: pos),
                                    weirdness: noiseRouter.weirdness.sample(at: pos),
                                    depth: noiseRouter.depth.sample(at: pos)
                                )
                            } else {
                                let point = self.sampleNoisePoint(at: pos)
                                biome = searchTree.getUnchecked(point)
                            }
                            biomes.append(biome)
                        }
                        worldX += scale
                    }
                    worldZ += scale
                }
                if timingsEnabled {
                    let loopEnd = DispatchTime.now().uptimeNanoseconds
                    let totalEnd = loopEnd
                    print("generateBiomesInSquare: small(no-bake) fourScale loop \(loopEnd - loopStart)ns; noise \(noiseSampleTime)ns; tree \(treeSampleTime)ns; total \(totalEnd - startTime)ns; samples \(area)")
                    print("  density functions: temperature \(temperatureTime)ns; humidity \(humidityTime)ns; continentalness \(continentalnessTime)ns; erosion \(erosionTime)ns; weirdness \(weirdnessTime)ns; depth \(depthTime)ns")
                }
                return biomes
            } else {
                let loopStart = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
                for z in fromPos.z..<toPos.z {
                    for x in fromPos.x..<toPos.x {
                        if timingsEnabled {
                            let t0 = DispatchTime.now().uptimeNanoseconds
                            let point: NoisePoint
                            if let noiseRouter = timingNoiseRouter {
                                point = samplePointWithTimings(
                                    at: PosInt3D(x: x, y: y, z: z),
                                    temperature: noiseRouter.temperature,
                                    humidity: noiseRouter.humidity,
                                    continentalness: noiseRouter.continents,
                                    erosion: noiseRouter.erosion,
                                    weirdness: noiseRouter.weirdness,
                                    depth: noiseRouter.depth
                                )
                            } else {
                                point = self.sampleNoisePoint(at: PosInt3D(x: x, y: y, z: z))
                            }
                            let t1 = DispatchTime.now().uptimeNanoseconds
                            let biome = searchTree.getUnchecked(point)
                            let t2 = DispatchTime.now().uptimeNanoseconds
                            noiseSampleTime += t1 - t0
                            treeSampleTime += t2 - t1
                            biomes.append(biome)
                        } else {
                            let pos = PosInt3D(x: x, y: y, z: z)
                            let biome: RegistryKey<Biome>
                            if let noiseRouter = directNoiseRouter {
                                biome = searchTree.getUnchecked(
                                    temperature: noiseRouter.temperature.sample(at: pos),
                                    humidity: noiseRouter.humidity.sample(at: pos),
                                    continentalness: noiseRouter.continents.sample(at: pos),
                                    erosion: noiseRouter.erosion.sample(at: pos),
                                    weirdness: noiseRouter.weirdness.sample(at: pos),
                                    depth: noiseRouter.depth.sample(at: pos)
                                )
                            } else {
                                let point = self.sampleNoisePoint(at: pos)
                                biome = searchTree.getUnchecked(point)
                            }
                            biomes.append(biome)
                        }
                    }
                }
                if timingsEnabled {
                    let loopEnd = DispatchTime.now().uptimeNanoseconds
                    let totalEnd = loopEnd
                    print("generateBiomesInSquare: small(no-bake) fullScale loop \(loopEnd - loopStart)ns; noise \(noiseSampleTime)ns; tree \(treeSampleTime)ns; total \(totalEnd - startTime)ns; samples \(area)")
                    print("  density functions: temperature \(temperatureTime)ns; humidity \(humidityTime)ns; continentalness \(continentalnessTime)ns; erosion \(erosionTime)ns; weirdness \(weirdnessTime)ns; depth \(depthTime)ns")
                }
                return biomes
            }
        }

        let bakeStart = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let baker = WorldScaleDensityFunctionBaker()

        let noiseRouter = self.config!.noiseRouter
        let temperature = try baker.bakeDensityFunction(noiseRouter.temperature)
        let humidity = try baker.bakeDensityFunction(noiseRouter.humidity)
        let continentalness = try baker.bakeDensityFunction(noiseRouter.continents)
        let erosion = try baker.bakeDensityFunction(noiseRouter.erosion)
        let weirdness = try baker.bakeDensityFunction(noiseRouter.weirdness)
        let depthFunc = try baker.bakeDensityFunction(noiseRouter.depth)
        let bakeEnd = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0

        if useScale {
            let loopStart = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
            let startWorldX = fromX * scale
            var worldZ = fromZ * scale
            for _ in fromZ..<toZ {
                var worldX = startWorldX
                for _ in fromX..<toX {
                    let pos = PosInt3D(x: worldX, y: y, z: worldZ)
                    if timingsEnabled {
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        let point = samplePointWithTimings(
                            at: pos,
                            temperature: temperature,
                            humidity: humidity,
                            continentalness: continentalness,
                            erosion: erosion,
                            weirdness: weirdness,
                            depth: depthFunc
                        )
                        let t1 = DispatchTime.now().uptimeNanoseconds
                        let biome = searchTree.getUnchecked(point)
                        let t2 = DispatchTime.now().uptimeNanoseconds
                        noiseSampleTime += t1 - t0
                        treeSampleTime += t2 - t1
                        biomes.append(biome)
                    } else {
                        let biome = searchTree.getUnchecked(
                            temperature: temperature.sample(at: pos),
                            humidity: humidity.sample(at: pos),
                            continentalness: continentalness.sample(at: pos),
                            erosion: erosion.sample(at: pos),
                            weirdness: weirdness.sample(at: pos),
                            depth: depthFunc.sample(at: pos)
                        )
                        biomes.append(biome)
                    }
                    worldX += scale
                }
                worldZ += scale
            }
            if timingsEnabled {
                let loopEnd = DispatchTime.now().uptimeNanoseconds
                let totalEnd = loopEnd
                print("generateBiomesInSquare: bake \(bakeEnd - bakeStart)ns (\((bakeEnd - bakeStart) / 1_000_000)ms); fourScale loop \(loopEnd - loopStart)ns (\((loopEnd - loopStart) / 1_000_000)ms); noise \(noiseSampleTime)ns (\(noiseSampleTime / 1_000_000)ms); tree \(treeSampleTime)ns (\(treeSampleTime / 1_000_000)ms); total \(totalEnd - startTime)ns (\((totalEnd - startTime) / 1_000_000)ms); samples \(area)")
                print("  density functions: temperature \(temperatureTime)ns (\(temperatureTime / 1_000_000)ms); humidity \(humidityTime)ns (\(humidityTime / 1_000_000)ms); continentalness \(continentalnessTime)ns (\(continentalnessTime / 1_000_000)ms); erosion \(erosionTime)ns (\(erosionTime / 1_000_000)ms); weirdness \(weirdnessTime)ns (\(weirdnessTime / 1_000_000)ms); depth \(depthTime)ns (\(depthTime / 1_000_000)ms)")
            }
        } else {
            let loopStart = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
            for z in fromPos.z..<toPos.z {
                for x in fromPos.x..<toPos.x {
                    let pos = PosInt3D(x: x, y: y, z: z)
                    if timingsEnabled {
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        let point = samplePointWithTimings(
                            at: pos,
                            temperature: temperature,
                            humidity: humidity,
                            continentalness: continentalness,
                            erosion: erosion,
                            weirdness: weirdness,
                            depth: depthFunc
                        )
                        let t1 = DispatchTime.now().uptimeNanoseconds
                        let biome = searchTree.getUnchecked(point)
                        let t2 = DispatchTime.now().uptimeNanoseconds
                        noiseSampleTime += t1 - t0
                        treeSampleTime += t2 - t1
                        biomes.append(biome)
                    } else {
                        let biome = searchTree.getUnchecked(
                            temperature: temperature.sample(at: pos),
                            humidity: humidity.sample(at: pos),
                            continentalness: continentalness.sample(at: pos),
                            erosion: erosion.sample(at: pos),
                            weirdness: weirdness.sample(at: pos),
                            depth: depthFunc.sample(at: pos)
                        )
                        biomes.append(biome)
                    }
                }
            }
            if timingsEnabled {
                let loopEnd = DispatchTime.now().uptimeNanoseconds
                let totalEnd = loopEnd
                print("generateBiomesInSquare: bake \(bakeEnd - bakeStart)ns (\((bakeEnd - bakeStart) / 1_000_000)ms); fullScale loop \(loopEnd - loopStart)ns (\((loopEnd - loopStart) / 1_000_000)ms); noise \(noiseSampleTime)ns (\(noiseSampleTime / 1_000_000)ms); tree \(treeSampleTime)ns (\(treeSampleTime / 1_000_000)ms); total \(totalEnd - startTime)ns (\((totalEnd - startTime) / 1_000_000)ms); samples \(area)")
                print("  density functions: temperature \(temperatureTime)ns; humidity \(humidityTime)ns; continentalness \(continentalnessTime)ns; erosion \(erosionTime)ns; weirdness \(weirdnessTime)ns; depth \(depthTime)ns")
            }
        }

        return biomes
    }

    /// Generate terrain into a `ProtoChunk` at the requested chunk position.
    /// This is the main entry point for chunk terrain sampling.
    /// - Parameters:
    ///   - chunk: The chunk to generate into.
    ///   - chunkPos: The chunk position in chunk coordinates.
    public func generateInto(_ chunk: ProtoChunk, at chunkPos: PosInt2D, benchmark timingsEnabled: Bool = false) throws {
        let totalStart = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        self.terrainGenerationLock.lock()
        defer { self.terrainGenerationLock.unlock() }

        guard let config = self.config else {
            throw WorldGenerationErrors.noiseSettingsNotPresent("Terrain generation requires a configured noise settings entry.")
        }
        guard config.height > 0 && config.height % ProtoChunk.sectionHeight == 0 else {
            throw WorldGenerationErrors.invalidProtoChunkHeight(config.height)
        }

        let minY = Int32(config.minY)
        let height = Int32(config.height)
        let configureStart = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        try chunk.configure(minY: minY, height: height)
        let configureEnd = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0

        let samplerInitStart = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let chunkSampler = VanillaChunkTerrainSampler(
            chunkPos: chunkPos,
            minY: minY,
            height: height,
            sizeHorizontal: config.sizeHorizontal,
            sizeVertical: config.sizeVertical
        )
        let samplerInitEnd = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0

        let terrainBakeStart = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let terrainDensity = try chunkSampler.bakeDensityFunction(config.noiseRouter.finalDensity)
        let terrainBakeEnd = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let temperatureBakeStart = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let temperature = try chunkSampler.bakeDensityFunction(config.noiseRouter.temperature)
        let temperatureBakeEnd = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let humidityBakeStart = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let humidity = try chunkSampler.bakeDensityFunction(config.noiseRouter.humidity)
        let humidityBakeEnd = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let continentalnessBakeStart = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let continentalness = try chunkSampler.bakeDensityFunction(config.noiseRouter.continents)
        let continentalnessBakeEnd = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let erosionBakeStart = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let erosion = try chunkSampler.bakeDensityFunction(config.noiseRouter.erosion)
        let erosionBakeEnd = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let weirdnessBakeStart = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let weirdness = try chunkSampler.bakeDensityFunction(config.noiseRouter.weirdness)
        let weirdnessBakeEnd = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let depthBakeStart = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let depth = try chunkSampler.bakeDensityFunction(config.noiseRouter.depth)
        let depthBakeEnd = timingsEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        let biomeProfile: BiomeGenerationProfile
        if let searchTree = self.configuredChunkBiomeSearchTree() {
            biomeProfile = self.generateBiomesIntoChunk(
                chunk,
                at: chunkPos,
                minY: minY,
                using: searchTree,
                with: ChunkBiomeDensityFunctions(
                    temperature: temperature,
                    humidity: humidity,
                    continentalness: continentalness,
                    erosion: erosion,
                    weirdness: weirdness,
                    depth: depth
                ),
                benchmark: timingsEnabled
            )
        } else {
            biomeProfile = BiomeGenerationProfile(skipped: true)
        }

        let terrainProfile = chunkSampler.generateTerrain(into: chunk, with: terrainDensity, benchmark: timingsEnabled)

        if timingsEnabled {
            let totalEnd = DispatchTime.now().uptimeNanoseconds
            let bakeTotal =
                (terrainBakeEnd - terrainBakeStart)
                &+ (temperatureBakeEnd - temperatureBakeStart)
                &+ (humidityBakeEnd - humidityBakeStart)
                &+ (continentalnessBakeEnd - continentalnessBakeStart)
                &+ (erosionBakeEnd - erosionBakeStart)
                &+ (weirdnessBakeEnd - weirdnessBakeStart)
                &+ (depthBakeEnd - depthBakeStart)
            print(
                "generateInto: configure \(configureEnd - configureStart)ns (\((configureEnd - configureStart) / 1_000_000)ms); " +
                "sampler init \(samplerInitEnd - samplerInitStart)ns (\((samplerInitEnd - samplerInitStart) / 1_000_000)ms); " +
                "bake total \(bakeTotal)ns (\(bakeTotal / 1_000_000)ms); " +
                "bake final_density \(terrainBakeEnd - terrainBakeStart)ns (\((terrainBakeEnd - terrainBakeStart) / 1_000_000)ms); " +
                "bake temperature \(temperatureBakeEnd - temperatureBakeStart)ns (\((temperatureBakeEnd - temperatureBakeStart) / 1_000_000)ms); " +
                "bake humidity \(humidityBakeEnd - humidityBakeStart)ns (\((humidityBakeEnd - humidityBakeStart) / 1_000_000)ms); " +
                "bake continentalness \(continentalnessBakeEnd - continentalnessBakeStart)ns (\((continentalnessBakeEnd - continentalnessBakeStart) / 1_000_000)ms); " +
                "bake erosion \(erosionBakeEnd - erosionBakeStart)ns (\((erosionBakeEnd - erosionBakeStart) / 1_000_000)ms); " +
                "bake weirdness \(weirdnessBakeEnd - weirdnessBakeStart)ns (\((weirdnessBakeEnd - weirdnessBakeStart) / 1_000_000)ms); " +
                "bake depth \(depthBakeEnd - depthBakeStart)ns (\((depthBakeEnd - depthBakeStart) / 1_000_000)ms); " +
                "\(terrainProfile.description); " +
                "\(biomeProfile.description); " +
                "total \(totalEnd - totalStart)ns (\((totalEnd - totalStart) / 1_000_000)ms)"
            )
            if let terrainClassDescription = terrainProfile.classDescription {
                print("  terrain density classes: \(terrainClassDescription)")
            }
            if !biomeProfile.skipped {
                print("  \(biomeProfile.densityDescription)")
            }
        }
    }

    // Currently visible for testing only.
    func sampleFinalDensity(at pos: PosInt3D) throws -> Double {
        guard let config = self.config else {
            throw WorldGenerationErrors.noiseSettingsNotPresent("Final density sampling requires a configured noise settings entry.")
        }
        guard config.height > 0 && config.height % ProtoChunk.sectionHeight == 0 else {
            throw WorldGenerationErrors.invalidProtoChunkHeight(config.height)
        }

        let minY = Int32(config.minY)
        let height = Int32(config.height)
        let chunkPos = PosInt2D(
            x: floorDiv(pos.x, by: Int32(ProtoChunk.sideLength)),
            z: floorDiv(pos.z, by: Int32(ProtoChunk.sideLength))
        )
        let chunkSampler = VanillaChunkTerrainSampler(
            chunkPos: chunkPos,
            minY: minY,
            height: height,
            sizeHorizontal: config.sizeHorizontal,
            sizeVertical: config.sizeVertical
        )
        let finalDensity = try chunkSampler.bakeDensityFunction(config.noiseRouter.finalDensity)
        return finalDensity.sample(at: pos)
    }

    // Currently visible for testing only.
    func getBakedNoiseOrThrow(at key: RegistryKey<DoublePerlinNoise>) throws -> DoublePerlinNoise {
        guard let ret = self.registries.bakedNoiseRegistry.get(key) else {
            throw WorldGenerationErrors.noiseNotPresent(key.name)
        }
        return ret
    }

    // Currently visible for testing only.
    func getDensityFunctionOrThrow(at key: RegistryKey<DensityFunction>) throws -> DensityFunction {
        guard let ret = self.registries.densityFunctionRegistry.get(key) else {
            throw WorldGenerationErrors.densityFunctionNotPresent(key.name)
        }
        return ret
    }
}

public struct NoisePoint {
    let temperature: Double
    let humidity: Double
    let continentalness: Double
    let erosion: Double
    let weirdness: Double
    let depth: Double
}

enum WorldGenerationErrors: Error {
    case densityFunctionNotPresent(String)
    case noiseNotPresent(String)
    case noiseSettingsNotPresent(String)
    case noBiomesOrPresetsInMultiNoiseBiomeSource(String)
    case invalidMultiNoiseBiomeSourceParameterList(String)
    case fromPosGreaterThanToPos
    case invalidScale
    case invalidProtoChunkHeight(Int)
}
