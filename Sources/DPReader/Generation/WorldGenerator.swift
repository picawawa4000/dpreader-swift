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

@inline(__always) private func densityFunctionIsConstantZero(_ function: any DensityFunction) -> Bool {
    if let wrapper = function as? any DensityFunctionWrapperIntrospectable {
        return densityFunctionIsConstantZero(wrapper.wrappedDensityFunction)
    }
    if let cacheMarker = function as? CacheMarker {
        return densityFunctionIsConstantZero(cacheMarker.argument)
    }
    guard let constant = function as? ConstantDensityFunction else {
        return false
    }
    return constant.constantValue == 0.0
}

@inline(__always) private func densityFunctionHasFlatCache(_ function: any DensityFunction) -> Bool {
    if function is WorldScaleFlatCache || function is ChunkFlatCache {
        return true
    }
    if let cacheMarker = function as? CacheMarker, cacheMarker.type == .flatCache {
        return true
    }
    return false
}

private func densityFunctionIsQuartColumnFlat(_ function: any DensityFunction) -> Bool {
    if densityFunctionHasFlatCache(function) {
        return true
    }
    if function is ConstantDensityFunction {
        return true
    }
    if let wrapper = function as? any DensityFunctionWrapperIntrospectable {
        return densityFunctionIsQuartColumnFlat(wrapper.wrappedDensityFunction)
    }
    if let cacheMarker = function as? CacheMarker {
        return densityFunctionIsQuartColumnFlat(cacheMarker.argument)
    }
    guard let shiftedNoise = function as? ShiftedNoise else {
        return false
    }
    return shiftedNoise.yScaleValue == 0.0
        && densityFunctionIsConstantZero(shiftedNoise.shiftYFunction)
        && densityFunctionHasFlatCache(shiftedNoise.shiftXFunction)
        && densityFunctionHasFlatCache(shiftedNoise.shiftZFunction)
}

@inline(__always) private func withAutoAppliedFlatCache(
    _ function: any DensityFunction,
    bounds: ChunkSamplingBounds?
) -> any DensityFunction {
    guard densityFunctionIsQuartColumnFlat(function), !densityFunctionHasFlatCache(function) else {
        return function
    }
    if let bounds {
        return ChunkFlatCache(wrapping: function, bounds: bounds)
    }
    return WorldScaleFlatCache(wrapping: function)
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
            let baked = withAutoAppliedFlatCache(try function.bake(withBaker: self), bounds: nil)
            self.memo[key] = baked
            return baked
        }
        return withAutoAppliedFlatCache(try function.bake(withBaker: self), bounds: nil)
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

private struct VoronoiBiomeSubsampler {
    private static let roundConstants: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
        0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
        0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
        0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
        0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
        0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
        0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
        0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
    private static let initialState: [UInt32] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    private static let stepMultiplier: UInt64 = 6_364_136_223_846_793_005
    private static let stepIncrement: UInt64 = 1_442_695_040_888_963_407

    let seedHash: UInt64

    init(worldSeed: WorldSeed) {
        self.seedHash = Self.makeSeedHash(worldSeed)
    }

    @inline(__always)
    func biomePosition(forBlock pos: PosInt3D) -> PosInt3D {
        let x = pos.x &- 2
        let y = pos.y &- 2
        let z = pos.z &- 2
        let pX = x >> 2
        let pY = y >> 2
        let pZ = z >> 2
        let dx = (x & 3) * 10_240
        let dy = (y & 3) * 10_240
        let dz = (z & 3) * 10_240
        var bestX: Int32 = 0
        var bestY: Int32 = 0
        var bestZ: Int32 = 0
        var bestDistance = UInt64.max

        for index in 0..<8 {
            let bx: Int32 = (index & 4) == 0 ? 0 : 1
            let by: Int32 = (index & 2) == 0 ? 0 : 1
            let bz: Int32 = (index & 1) == 0 ? 0 : 1
            let cellX = pX &+ bx
            let cellY = pY &+ by
            let cellZ = pZ &+ bz
            let cellOffset = self.cellOffset(at: PosInt3D(x: cellX, y: cellY, z: cellZ))
            let rx = Int64(cellOffset.x &+ dx &- 40_960 &* bx)
            let ry = Int64(cellOffset.y &+ dy &- 40_960 &* by)
            let rz = Int64(cellOffset.z &+ dz &- 40_960 &* bz)
            let distance = UInt64(rx &* rx) &+ UInt64(ry &* ry) &+ UInt64(rz &* rz)
            if distance < bestDistance {
                bestDistance = distance
                bestX = cellX
                bestY = cellY
                bestZ = cellZ
            }
        }

        return PosInt3D(x: bestX, y: bestY, z: bestZ)
    }

    @inline(__always)
    private func cellOffset(at pos: PosInt3D) -> PosInt3D {
        var seed = self.seedHash
        seed = Self.stepSeed(seed, salt: Self.salt(pos.x))
        seed = Self.stepSeed(seed, salt: Self.salt(pos.y))
        seed = Self.stepSeed(seed, salt: Self.salt(pos.z))
        seed = Self.stepSeed(seed, salt: Self.salt(pos.x))
        seed = Self.stepSeed(seed, salt: Self.salt(pos.y))
        seed = Self.stepSeed(seed, salt: Self.salt(pos.z))

        let x = (Int32((seed >> 24) & 1023) &- 512) &* 36
        seed = Self.stepSeed(seed, salt: self.seedHash)
        let y = (Int32((seed >> 24) & 1023) &- 512) &* 36
        seed = Self.stepSeed(seed, salt: self.seedHash)
        let z = (Int32((seed >> 24) & 1023) &- 512) &* 36
        return PosInt3D(x: x, y: y, z: z)
    }

    @inline(__always)
    private static func salt(_ value: Int32) -> UInt64 {
        return UInt64(bitPattern: Int64(value))
    }

    @inline(__always)
    private static func stepSeed(_ seed: UInt64, salt: UInt64) -> UInt64 {
        return seed &* (seed &* Self.stepMultiplier &+ Self.stepIncrement) &+ salt
    }

    private static func makeSeedHash(_ seed: WorldSeed) -> UInt64 {
        var message = [UInt32](repeating: 0, count: 64)
        message[0] = UInt32(truncatingIfNeeded: seed).byteSwapped
        message[1] = UInt32(truncatingIfNeeded: seed >> 32).byteSwapped
        message[2] = 0x80000000
        message[15] = 0x00000040

        for index in 16..<64 {
            let s0 = Self.rotateRight(message[index - 15], by: 7)
                ^ Self.rotateRight(message[index - 15], by: 18)
                ^ (message[index - 15] >> 3)
            let s1 = Self.rotateRight(message[index - 2], by: 17)
                ^ Self.rotateRight(message[index - 2], by: 19)
                ^ (message[index - 2] >> 10)
            message[index] = message[index - 7] &+ message[index - 16] &+ s0 &+ s1
        }

        var a0 = Self.initialState[0]
        var a1 = Self.initialState[1]
        var a2 = Self.initialState[2]
        var a3 = Self.initialState[3]
        var a4 = Self.initialState[4]
        var a5 = Self.initialState[5]
        var a6 = Self.initialState[6]
        var a7 = Self.initialState[7]

        for index in 0..<64 {
            var temp1 = a7 &+ Self.roundConstants[index] &+ message[index]
            temp1 &+= Self.rotateRight(a4, by: 6) ^ Self.rotateRight(a4, by: 11) ^ Self.rotateRight(a4, by: 25)
            temp1 &+= (a4 & a5) ^ (~a4 & a6)

            var temp2 = Self.rotateRight(a0, by: 2) ^ Self.rotateRight(a0, by: 13) ^ Self.rotateRight(a0, by: 22)
            temp2 &+= (a0 & a1) ^ (a0 & a2) ^ (a1 & a2)

            a7 = a6
            a6 = a5
            a5 = a4
            a4 = a3 &+ temp1
            a3 = a2
            a2 = a1
            a1 = a0
            a0 = temp1 &+ temp2
        }

        a0 &+= Self.initialState[0]
        a1 &+= Self.initialState[1]
        return UInt64(a0.byteSwapped) | (UInt64(a1.byteSwapped) << 32)
    }

    @inline(__always)
    private static func rotateRight(_ value: UInt32, by bits: UInt32) -> UInt32 {
        return (value >> bits) | (value << (32 &- bits))
    }
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
            let baked = withAutoAppliedFlatCache(try function.bake(withBaker: self), bounds: self.bounds)
            self.memo[key] = baked
            return baked
        }
        return withAutoAppliedFlatCache(try function.bake(withBaker: self), bounds: self.bounds)
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

/// Stores one 16x16x16 chunk section of terrain, exact block-biome data, and quart-biome data.
/// Not concurrency-safe; callers must synchronize concurrent reads and writes.
public final class ProtoChunkSection {
    public static let sideLength = 16
    public static let blockCount = sideLength * sideLength * sideLength
    public static let bitmapWordCount = blockCount / 64
    public static let biomeSideLength = 4
    public static let biomeCount = biomeSideLength * biomeSideLength * biomeSideLength

    private var terrainBitmap = [UInt64](repeating: 0, count: bitmapWordCount)
    private var blockBiomes = [RegistryKey<Biome>?](repeating: nil, count: blockCount)
    private var quartBiomes = [RegistryKey<Biome>?](repeating: nil, count: biomeCount)

    /// Creates an empty section with no terrain bits and no assigned biomes.
    /// Not concurrency-safe.
    public init() {}

    /// Returns the section terrain bitmap in local block order.
    /// Not concurrency-safe.
    public var bitmap: [UInt64] {
        return self.terrainBitmap
    }

    /// Returns the quart-biome palette for this section.
    /// Not concurrency-safe.
    public var biomePalette: [RegistryKey<Biome>?] {
        return self.quartBiomes
    }

    func clear() {
        self.terrainBitmap = [UInt64](repeating: 0, count: Self.bitmapWordCount)
        self.blockBiomes = [RegistryKey<Biome>?](repeating: nil, count: Self.blockCount)
        self.quartBiomes = [RegistryKey<Biome>?](repeating: nil, count: Self.biomeCount)
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
        self.quartBiomes[biomeIndex] = biome
    }

    @inline(__always) func setBiomeUnchecked(_ biome: RegistryKey<Biome>, blockIndex: Int) {
        self.blockBiomes[blockIndex] = biome
    }

    @inline(__always) func setBiome(_ biome: RegistryKey<Biome>, at pos: PosInt3D) {
        precondition(pos.x >= 0 && pos.x < Int32(Self.sideLength), "x biome position out of range")
        precondition(pos.y >= 0 && pos.y < Int32(Self.sideLength), "y biome position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.sideLength), "z biome position out of range")

        let blockIndex = (Int(pos.y) << 8) | (Int(pos.z) << 4) | Int(pos.x)
        self.blockBiomes[blockIndex] = biome
    }

    @inline(__always) func biome(at pos: PosInt3D) -> RegistryKey<Biome>? {
        precondition(pos.x >= 0 && pos.x < Int32(Self.sideLength), "x biome position out of range")
        precondition(pos.y >= 0 && pos.y < Int32(Self.sideLength), "y biome position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.sideLength), "z biome position out of range")

        let blockIndex = (Int(pos.y) << 8) | (Int(pos.z) << 4) | Int(pos.x)
        return self.blockBiomes[blockIndex]
    }

    @inline(__always) func setBiome(_ biome: RegistryKey<Biome>, atBiome pos: PosInt3D) {
        precondition(pos.x >= 0 && pos.x < Int32(Self.biomeSideLength), "x biome position out of range")
        precondition(pos.y >= 0 && pos.y < Int32(Self.biomeSideLength), "y biome position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.biomeSideLength), "z biome position out of range")

        let biomeIndex = (Int(pos.y) << 4) | (Int(pos.z) << 2) | Int(pos.x)
        self.quartBiomes[biomeIndex] = biome
    }

    @inline(__always) func biome(atBiome pos: PosInt3D) -> RegistryKey<Biome>? {
        precondition(pos.x >= 0 && pos.x < Int32(Self.biomeSideLength), "x biome position out of range")
        precondition(pos.y >= 0 && pos.y < Int32(Self.biomeSideLength), "y biome position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.biomeSideLength), "z biome position out of range")

        let biomeIndex = (Int(pos.y) << 4) | (Int(pos.z) << 2) | Int(pos.x)
        return self.quartBiomes[biomeIndex]
    }
}

/// A chunk implementation for world generation that stores terrain, exact block biomes, and quart biomes in 16x16x16 sections.
/// Not concurrency-safe; callers must synchronize access when mutating or reading the same instance from multiple threads.
public final class ProtoChunk {
    public static let sideLength = 16
    public static let sectionHeight = 16
    public static let biomeSideLength = 4
    public static let biomeScale = 4

    public private(set) var minY: Int32 = 0
    public private(set) var height: Int32 = 0
    private var sections: [ProtoChunkSection] = []

    /// Creates an empty proto-chunk with no configured vertical range.
    /// Not concurrency-safe.
    public init() {}

    /// Returns the number of configured sections in the chunk.
    /// Not concurrency-safe.
    public var sectionCount: Int {
        return self.sections.count
    }

    /// Returns the section at the requested index if it exists.
    /// Not concurrency-safe.
    /// - Parameter index: The zero-based section index.
    /// - Returns: The section at `index`, or `nil` if the index is out of bounds.
    public func section(at index: Int) -> ProtoChunkSection? {
        guard index >= 0 && index < self.sections.count else { return nil }
        return self.sections[index]
    }

    /// Configures the vertical bounds and allocates backing sections for this chunk.
    /// Not concurrency-safe.
    /// - Parameters:
    ///   - minY: The minimum block Y stored by the chunk.
    ///   - height: The total chunk height in blocks. Must be positive and divisible by `sectionHeight`.
    /// - Throws: `WorldGenerationErrors.invalidProtoChunkHeight` if `height` is not section-aligned.
    public func configure(minY: Int32, height: Int32) throws {
        guard height > 0 && height % Int32(Self.sectionHeight) == 0 else {
            throw WorldGenerationErrors.invalidProtoChunkHeight(Int(height))
        }

        self.minY = minY
        self.height = height
        self.sections = (0..<Int(height / Int32(Self.sectionHeight))).map { _ in ProtoChunkSection() }
    }

    /// Clears all terrain and biome data currently stored in the chunk.
    /// Not concurrency-safe.
    public func clearTerrain() {
        for section in self.sections {
            section.clear()
        }
    }

    /// Returns the configured biome height in quart units.
    /// Not concurrency-safe.
    public var biomeHeight: Int {
        return Int(self.height) / Self.biomeScale
    }

    /// Sets one local block position in the chunk terrain bitmap.
    /// Not concurrency-safe.
    /// - Parameters:
    ///   - isSolid: Whether the block should be marked solid.
    ///   - pos: The block position in chunk-local coordinates.
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

    @inline(__always) func setBiomeUnchecked(_ biome: RegistryKey<Biome>, sectionIndex: Int, blockIndex: Int) {
        self.sections[sectionIndex].setBiomeUnchecked(biome, blockIndex: blockIndex)
    }

    /// Sets one local block-biome position in the chunk biome map.
    /// Not concurrency-safe.
    /// - Parameters:
    ///   - biome: The biome key to store.
    ///   - pos: The biome position in chunk-local block coordinates.
    @inline(__always) public func setBiome(_ biome: RegistryKey<Biome>, atLocal pos: PosInt3D) {
        precondition(pos.x >= 0 && pos.x < Int32(Self.sideLength), "x biome position out of range")
        precondition(pos.y >= 0 && pos.y < self.height, "y biome position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.sideLength), "z biome position out of range")

        let sectionIndex = Int(pos.y) >> 4
        let localY = pos.y & 15
        self.sections[sectionIndex].setBiome(biome, at: PosInt3D(x: pos.x, y: localY, z: pos.z))
    }

    /// Sets one local quart-biome position in the chunk biome palette.
    /// Not concurrency-safe.
    /// - Parameters:
    ///   - biome: The biome key to store.
    ///   - pos: The biome position in chunk-local quart coordinates.
    @inline(__always) public func setBiome(_ biome: RegistryKey<Biome>, atBiomeLocal pos: PosInt3D) {
        precondition(pos.x >= 0 && pos.x < Int32(Self.biomeSideLength), "x biome position out of range")
        precondition(pos.y >= 0 && pos.y < Int32(self.biomeHeight), "y biome position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.biomeSideLength), "z biome position out of range")

        let sectionIndex = Int(pos.y) >> 2
        let localY = pos.y & 3
        self.sections[sectionIndex].setBiome(biome, atBiome: PosInt3D(x: pos.x, y: localY, z: pos.z))
    }

    /// Returns the biome stored at one local quart-biome position.
    /// Not concurrency-safe.
    /// - Parameter pos: The biome position in chunk-local quart coordinates.
    /// - Returns: The stored biome key, or `nil` if the position has not been assigned.
    @inline(__always) public func biome(atBiomeLocal pos: PosInt3D) -> RegistryKey<Biome>? {
        precondition(pos.x >= 0 && pos.x < Int32(Self.biomeSideLength), "x biome position out of range")
        precondition(pos.y >= 0 && pos.y < Int32(self.biomeHeight), "y biome position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.biomeSideLength), "z biome position out of range")

        let sectionIndex = Int(pos.y) >> 2
        let localY = pos.y & 3
        return self.sections[sectionIndex].biome(atBiome: PosInt3D(x: pos.x, y: localY, z: pos.z))
    }

    /// Returns the exact biome stored at one local block position.
    /// Not concurrency-safe.
    /// - Parameter pos: The biome position in chunk-local block coordinates.
    /// - Returns: The stored biome key, or `nil` if the position has not been assigned.
    @inline(__always) public func biome(atLocal pos: PosInt3D) -> RegistryKey<Biome>? {
        precondition(pos.x >= 0 && pos.x < Int32(Self.sideLength), "x biome position out of range")
        precondition(pos.y >= 0 && pos.y < self.height, "y biome position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.sideLength), "z biome position out of range")

        let sectionIndex = Int(pos.y) >> 4
        let localY = pos.y & 15
        return self.sections[sectionIndex].biome(at: PosInt3D(x: pos.x, y: localY, z: pos.z))
    }

    /// Returns whether the chunk stores solid terrain at one local block position.
    /// Not concurrency-safe.
    /// - Parameter pos: The block position in chunk-local coordinates.
    /// - Returns: `true` if the block is marked solid.
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

private struct BiomeLatticePosition: Hashable {
    let x: Int32
    let y: Int32
    let z: Int32

    init(_ pos: PosInt3D) {
        self.x = pos.x
        self.y = pos.y
        self.z = pos.z
    }

    @inline(__always) var blockPosition: PosInt3D {
        return PosInt3D(x: blockCoord(fromBiome: self.x), y: blockCoord(fromBiome: self.y), z: blockCoord(fromBiome: self.z))
    }
}

/// The thing that actually generates worlds.
public final class WorldGenerator {
    private let worldSeed: WorldSeed
    private let biomeSubsampler: VoronoiBiomeSubsampler
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
        self.biomeSubsampler = VoronoiBiomeSubsampler(worldSeed: seed)
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
        with functions: ChunkBiomeDensityFunctions
    ) {
        let chunkStartX = chunkPos.x &* Int32(ProtoChunk.sideLength)
        let chunkStartZ = chunkPos.z &* Int32(ProtoChunk.sideLength)
        let quartXs = [chunkStartX, chunkStartX + 4, chunkStartX + 8, chunkStartX + 12]
        let quartZs = [chunkStartZ, chunkStartZ + 4, chunkStartZ + 8, chunkStartZ + 12]
        let biomeHeight = chunk.biomeHeight
        let lookupState = searchTree.makeReusableLookupState()
        var sampledBiomes: [BiomeLatticePosition: RegistryKey<Biome>] = [:]
        sampledBiomes.reserveCapacity((ProtoChunk.biomeSideLength + 2) * (ProtoChunk.biomeSideLength + 2) * (biomeHeight + 2))

        @inline(__always)
        func cachedBiome(at latticePos: BiomeLatticePosition) -> RegistryKey<Biome> {
            if let cached = sampledBiomes[latticePos] {
                return cached
            }

            let pos = latticePos.blockPosition
            let temperature = functions.temperature.sample(at: pos)
            let humidity = functions.humidity.sample(at: pos)
            let continentalness = functions.continentalness.sample(at: pos)
            let erosion = functions.erosion.sample(at: pos)
            let weirdness = functions.weirdness.sample(at: pos)
            let depth = functions.depth.sample(at: pos)
            let biome = searchTree.getUnchecked(
                temperature: temperature,
                humidity: humidity,
                continentalness: continentalness,
                erosion: erosion,
                weirdness: weirdness,
                depth: depth,
                using: lookupState
            )
            sampledBiomes[latticePos] = biome
            return biome
        }

        for localBiomeZ in 0..<ProtoChunk.biomeSideLength {
            let worldZ = quartZs[localBiomeZ]
            for localBiomeX in 0..<ProtoChunk.biomeSideLength {
                let worldX = quartXs[localBiomeX]
                let sectionBiomeXZ = (localBiomeZ << 2) | localBiomeX
                for localBiomeY in 0..<biomeHeight {
                    let worldY = minY + Int32(localBiomeY * ProtoChunk.biomeScale)
                    let section = chunk.sectionUnchecked(at: localBiomeY >> 2)
                    let sectionBiomeIndex = ((localBiomeY & 3) << 4) | sectionBiomeXZ
                    let latticePos = BiomeLatticePosition(
                        PosInt3D(
                            x: biomeCoord(fromBlock: worldX),
                            y: biomeCoord(fromBlock: worldY),
                            z: biomeCoord(fromBlock: worldZ)
                        )
                    )
                    let biome = cachedBiome(at: latticePos)
                    section.setBiomeUnchecked(biome, biomeIndex: sectionBiomeIndex)
                }
            }
        }

        for localY in 0..<Int(chunk.height) {
            let worldY = minY + Int32(localY)
            let section = chunk.sectionUnchecked(at: localY >> 4)
            let blockIndexY = (localY & 15) << 8
            for localZ in 0..<ProtoChunk.sideLength {
                let worldZ = chunkStartZ + Int32(localZ)
                let blockIndexYZ = blockIndexY | (localZ << 4)
                for localX in 0..<ProtoChunk.sideLength {
                    let worldX = chunkStartX + Int32(localX)
                    let latticePos = BiomeLatticePosition(
                        self.biomeSubsampler.biomePosition(forBlock: PosInt3D(x: worldX, y: worldY, z: worldZ))
                    )
                    let biome = cachedBiome(at: latticePos)
                    section.setBiomeUnchecked(biome, blockIndex: blockIndexYZ | localX)
                }
            }
        }
    }

    /// Samples the configured climate noise router at a world position.
    /// Not concurrency-safe; the baked world-scale cache wrappers used here are mutable and require external synchronization.
    /// - Parameter pos: The world position to sample.
    /// - Returns: The sampled climate point, or a zeroed point if no noise settings are configured.
    public func sampleNoisePoint(at pos: PosInt3D) -> NoisePoint {
        if self.config == nil {
            assertionFailure("WorldGenerator.sampleNoisePoint(at:) called without configured noise settings")
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

    /// Samples the biome selected by the configured biome search tree at a world position.
    /// Not concurrency-safe; this method delegates to `sampleNoisePoint(at:)` and shares its cache-mutation behavior.
    /// - Parameters:
    ///   - pos: The world position to sample.
    ///   - dim: The dimension whose biome search tree should be used.
    /// - Throws: Any error thrown by biome search tree lookup.
    /// - Returns: The selected biome key, or `nil` if no search tree is configured for `dim`.
    public func sampleBiome(at pos: PosInt3D, in dim: RegistryKey<Dimension>) throws -> RegistryKey<Biome>? {
        let point = self.sampleNoisePoint(at: pos)
        guard let searchTree = self.searchTrees[dim] else {
            assertionFailure("WorldGenerator.sampleBiome(at:in:) called without a search tree for \(dim.name)")
            return nil
        }
        return try searchTree.get(point)
    }

    /// Samples the final block biome selected after vanilla Voronoi subsampling at a world position.
    /// Not concurrency-safe; this method delegates to `sampleNoisePoint(at:)` and shares its cache-mutation behavior.
    /// - Parameters:
    ///   - pos: The world block position to sample.
    ///   - dim: The dimension whose biome search tree should be used.
    /// - Throws: Any error thrown by biome search tree lookup.
    /// - Returns: The final biome key at `pos`, or `nil` if no search tree is configured for `dim`.
    public func sampleBlockBiome(at pos: PosInt3D, in dim: RegistryKey<Dimension>) throws -> RegistryKey<Biome>? {
        let biomePos = self.biomeSubsampler.biomePosition(forBlock: pos)
        let climatePos = PosInt3D(
            x: blockCoord(fromBiome: biomePos.x),
            y: blockCoord(fromBiome: biomePos.y),
            z: blockCoord(fromBiome: biomePos.z)
        )
        return try self.sampleBiome(at: climatePos, in: dim)
    }

    /// Generates biomes in a rectangular area.
    /// Not concurrency-safe; this method may use mutable cache wrappers during sampling.
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
    public func generateBiomesInSquare(from fromPos: PosInt2D, to toPos: PosInt2D, atY y: Int32, in dim: RegistryKey<Dimension>, scale: Int32 = 4, forceNoBaking: Bool = false) throws -> [RegistryKey<Biome>]? {
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

        let directNoiseRouter = self.config?.noiseRouter

        if area <= smallAreaThreshold || self.config == nil || forceNoBaking {
            if useScale {
                let startWorldX = fromX * scale
                var worldZ = fromZ * scale
                for _ in fromZ..<toZ {
                    var worldX = startWorldX
                    for _ in fromX..<toX {
                        let pos = PosInt3D(x: worldX, y: y, z: worldZ)
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
                        worldX += scale
                    }
                    worldZ += scale
                }
                return biomes
            } else {
                for z in fromPos.z..<toPos.z {
                    for x in fromPos.x..<toPos.x {
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
                return biomes
            }
        }

        let baker = WorldScaleDensityFunctionBaker()

        let noiseRouter = self.config!.noiseRouter
        let temperature = try baker.bakeDensityFunction(noiseRouter.temperature)
        let humidity = try baker.bakeDensityFunction(noiseRouter.humidity)
        let continentalness = try baker.bakeDensityFunction(noiseRouter.continents)
        let erosion = try baker.bakeDensityFunction(noiseRouter.erosion)
        let weirdness = try baker.bakeDensityFunction(noiseRouter.weirdness)
        let depthFunc = try baker.bakeDensityFunction(noiseRouter.depth)

        if useScale {
            let startWorldX = fromX * scale
            var worldZ = fromZ * scale
            for _ in fromZ..<toZ {
                var worldX = startWorldX
                for _ in fromX..<toX {
                    let pos = PosInt3D(x: worldX, y: y, z: worldZ)
                    let biome = searchTree.getUnchecked(
                        temperature: temperature.sample(at: pos),
                        humidity: humidity.sample(at: pos),
                        continentalness: continentalness.sample(at: pos),
                        erosion: erosion.sample(at: pos),
                        weirdness: weirdness.sample(at: pos),
                        depth: depthFunc.sample(at: pos)
                    )
                    biomes.append(biome)
                    worldX += scale
                }
                worldZ += scale
            }
        } else {
            for z in fromPos.z..<toPos.z {
                for x in fromPos.x..<toPos.x {
                    let pos = PosInt3D(x: x, y: y, z: z)
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

        return biomes
    }

    /// Generates terrain, exact block-biome data, and quart-biome data into a `ProtoChunk` at the requested chunk position.
    /// Concurrency-safe for calls on the same `WorldGenerator`; generation is internally synchronized around shared mutable terrain-sampling state.
    /// - Parameters:
    ///   - chunk: The chunk to configure and populate.
    ///   - chunkPos: The chunk position in chunk coordinates.
    /// - Throws: Any error thrown while configuring the chunk, baking density functions, or sampling terrain and biomes.
    public func generateInto(_ chunk: ProtoChunk, at chunkPos: PosInt2D) throws {
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
        try chunk.configure(minY: minY, height: height)

        let chunkSampler = VanillaChunkTerrainSampler(
            chunkPos: chunkPos,
            minY: minY,
            height: height,
            sizeHorizontal: config.sizeHorizontal,
            sizeVertical: config.sizeVertical
        )

        let terrainDensity = try chunkSampler.bakeDensityFunction(config.noiseRouter.finalDensity)
        let temperature = try chunkSampler.bakeDensityFunction(config.noiseRouter.temperature)
        let humidity = try chunkSampler.bakeDensityFunction(config.noiseRouter.humidity)
        let continentalness = try chunkSampler.bakeDensityFunction(config.noiseRouter.continents)
        let erosion = try chunkSampler.bakeDensityFunction(config.noiseRouter.erosion)
        let weirdness = try chunkSampler.bakeDensityFunction(config.noiseRouter.weirdness)
        let depth = try chunkSampler.bakeDensityFunction(config.noiseRouter.depth)
        if let searchTree = self.configuredChunkBiomeSearchTree() {
            self.generateBiomesIntoChunk(
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
                )
            )
        }

        chunkSampler.generateTerrain(into: chunk, with: terrainDensity)
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
    func biomePosition(forBlock pos: PosInt3D) -> PosInt3D {
        return self.biomeSubsampler.biomePosition(forBlock: pos)
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
