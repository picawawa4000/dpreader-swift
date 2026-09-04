import Foundation

/// Stores all of the registries needed for world generation.
final class WorldGenerationRegistries {
    var densityFunctionRegistry = Registry<DensityFunction>()
    /// Seed-baked compiled density functions, keyed exactly like `densityFunctionRegistry`.
    var compiledDensityFunctionRegistry: Registry<CompiledDensityFunction>?
    var bakedNoiseRegistry = Registry<DoublePerlinNoise>()
    var biomeRegistry = Registry<Biome>()
    var dimensionRegistry = Registry<Dimension>()
    var configuredCarverRegistry = Registry<ConfiguredCarver>()
    var tagRegistry = Registry<TagDefinition>()
}

private enum ConfiguredBiomeSampler {
    case searchTree(BiomeSearchTree, CompiledBiomeSearchTree?)
    case theEnd
}

private enum CompiledBiomeDensityFunctions {
    case scalar(
        temperature: CompiledDensityFunction,
        humidity: CompiledDensityFunction,
        continentalness: CompiledDensityFunction,
        erosion: CompiledDensityFunction,
        weirdness: CompiledDensityFunction,
        depth: CompiledDensityFunction
    )
    case wasm(CompiledWASMClimateFunctions)

    @inline(__always)
    func sample(at pos: PosInt3D) -> NoisePoint {
        switch self {
        case .scalar(let temperature, let humidity, let continentalness, let erosion, let weirdness, let depth):
            return NoisePoint(
                temperature: temperature(pos.x, pos.y, pos.z),
                humidity: humidity(pos.x, pos.y, pos.z),
                continentalness: continentalness(pos.x, pos.y, pos.z),
                erosion: erosion(pos.x, pos.y, pos.z),
                weirdness: weirdness(pos.x, pos.y, pos.z),
                depth: depth(pos.x, pos.y, pos.z)
            )
        case .wasm(let compiled):
            let point = compiled.sample(x: pos.x, y: pos.y, z: pos.z)
            return NoisePoint(
                temperature: point.temperature,
                humidity: point.humidity,
                continentalness: point.continentalness,
                erosion: point.erosion,
                weirdness: point.weirdness,
                depth: point.depth
            )
        }
    }
}

/// A fixed chunk's compiled final-density corner lattice.
///
/// Vanilla terrain interpolates the values at generation-cell corners rather than sampling every
/// block. The compiled program fills that entire lattice in one call, and this adapter preserves
/// the sampler's normal interpolation and block-placement path.
private final class CompiledChunkTerrainDensity: DensityFunction {
    private let fallback: any DensityFunction
    private let basePosition: PosInt3D
    private let context: CompiledDensityFunctionBufferContext
    private let values: [Double]

    init(
        fallback: any DensityFunction,
        sampler: CompiledDensityFunctionBulk,
        basePosition: PosInt3D
    ) {
        self.fallback = fallback
        self.basePosition = basePosition
        self.context = sampler.bufferContext
        self.values = sampler.callAsFunction(at: basePosition)
    }

    @inline(__always)
    func sample(at position: PosInt3D) -> Double {
        let xOffset = position.x - self.basePosition.x
        let yOffset = position.y - self.basePosition.y
        let zOffset = position.z - self.basePosition.z
        guard xOffset >= 0, yOffset >= 0, zOffset >= 0,
              xOffset % self.context.xStep == 0,
              yOffset % self.context.yStep == 0,
              zOffset % self.context.zStep == 0 else {
            return self.fallback.sample(at: position)
        }
        let x = xOffset / self.context.xStep
        let y = yOffset / self.context.yStep
        let z = zOffset / self.context.zStep
        guard x < self.context.xCount, y < self.context.yCount, z < self.context.zCount else {
            return self.fallback.sample(at: position)
        }
        return self.values[Int((z * self.context.xCount + x) * self.context.yCount + y)]
    }

    func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return self
    }

    init(from decoder: any Decoder) throws {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "CompiledChunkTerrainDensity is runtime-only.")
        )
    }

    func encode(to encoder: any Encoder) throws {
        throw EncodingError.invalidValue(
            self,
            EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "CompiledChunkTerrainDensity is runtime-only.")
        )
    }
}

/// A reusable exact height evaluator for several structure checks inside one chunk.
final class StructureStartTerrainChunkSampler {
    private let sampler: VanillaChunkTerrainSampler
    private let density: any DensityFunction

    init(sampler: VanillaChunkTerrainSampler, density: any DensityFunction) {
        self.sampler = sampler
        self.density = density
    }

    func height(atX x: Int32, z: Int32, minimumTerrainY: Int32? = nil) -> Int32? {
        let localX = x &- self.sampler.chunkPos.x &* 16
        let localZ = z &- self.sampler.chunkPos.z &* 16
        return self.sampler.terrainHeight(
            atLocalX: localX,
            localZ: localZ,
            with: self.density,
            minimumTerrainY: minimumTerrainY
        )
    }

    var densityColumnEvaluationCount: Int {
        self.sampler.terrainHeightInterpolationColumnEvaluationCount
    }
}

@inline(__always)
private func canonicalPredefinedBiomePreset(_ preset: String) -> String? {
    switch preset {
    case "overworld", "minecraft:overworld":
        return "minecraft:overworld"
    case "nether", "minecraft:nether":
        return "minecraft:nether"
    default:
        return nil
    }
}

@inline(__always)
private func hardcodedBiomeKey(_ name: String) -> RegistryKey<Biome> {
    return RegistryKey(referencing: name)
}

@inline(__always)
private func performConcurrentIterations(iterations: Int, _ body: @Sendable (Int) -> Void) {
    #if os(WASI) || arch(wasm32)
    for index in 0..<iterations {
        body(index)
    }
    #else
    DispatchQueue.concurrentPerform(iterations: iterations, execute: body)
    #endif
}

/// Stable seed-dependent objects referenced by compiled programs. Reseeding replaces their data,
/// not the object addresses embedded in native callbacks or captured by WASM imports.
fileprivate final class SharedSeededNoiseStorage {
    private var noises: [RegistryKey<NoiseDefinition>: BakedNoise] = [:]

    func noise(for key: RegistryKey<NoiseDefinition>, sampler: DoublePerlinNoise) -> BakedNoise {
        if let existing = self.noises[key] {
            existing.replaceSampler(with: sampler)
            return existing
        }
        let noise = BakedNoise(fromKey: key, withSampler: sampler, usesSharedSeedStorage: true)
        self.noises[key] = noise
        return noise
    }
}

/// A density function baker that does all baking steps.
final class FullDensityFunctionBaker: DensityFunctionBaker {
    fileprivate let registries: WorldGenerationRegistries
    private let seed: WorldSeed
    private let usesLegacyRandomSource: Bool
    private let randomDeriver: XoroshiroRandomSplitter
    private let sharedSeededNoises: SharedSeededNoiseStorage
    private var initialisedFunctionIds = Set<RegistryKey<DensityFunction>>()
    private var legacyNoiseOverrides: [RegistryKey<NoiseDefinition>: DoublePerlinNoise] = [:]

    fileprivate init(
        withSeed seed: WorldSeed,
        usesLegacyRandomSource: Bool,
        registries: WorldGenerationRegistries,
        sharedSeededNoises: SharedSeededNoiseStorage
    ) {
        self.seed = seed
        self.usesLegacyRandomSource = usesLegacyRandomSource
        self.registries = registries
        self.sharedSeededNoises = sharedSeededNoises
        var random = XoroshiroRandom(seed: seed)
        self.randomDeriver = XoroshiroRandomSplitter(seedLo: random.nextLong(), seedHi: random.nextLong())
    }

    func bake(noise: any DensityFunctionNoise) throws -> BakedNoise {
        if self.usesLegacyRandomSource, let overrideSampler = self.legacySamplerOverride(for: noise.key) {
            return self.sharedSeededNoises.noise(for: noise.key, sampler: overrideSampler)
        }
        guard let sampler = self.registries.bakedNoiseRegistry.get(noise.key.convertType()) else {
            throw WorldGenerationErrors.noiseNotPresent(noise.key.name)
        }
        return self.sharedSeededNoises.noise(for: noise.key, sampler: sampler)
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
        var shared = simplexNoise
        shared.replaceSeed(using: &random)
        return shared
    }

    func bake(interpolatedNoise noise: InterpolatedNoise) throws -> InterpolatedNoise {
        if self.usesLegacyRandomSource {
            var random: any Random = self.createLegacyNoiseRandom(seed: 0)
            noise.replaceSeedState(withRandom: &random)
            return noise
        }

        let terrainRandom = self.randomDeriver.split(usingString: LegacyNoiseKeys.terrain)
        var random: any Random = terrainRandom
        noise.replaceSeedState(withRandom: &random)
        return noise
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
        return CheckedRandom(seed: self.seed &+ seed)
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

private func sameDensityFunctionInstance(_ lhs: any DensityFunction, _ rhs: any DensityFunction) -> Bool {
    guard type(of: lhs) is AnyObject.Type, type(of: rhs) is AnyObject.Type else { return false }
    return ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
}

private func sameSplineSegmentIdentity(_ lhs: SplineSegment, _ rhs: SplineSegment) -> Bool {
    switch (lhs, rhs) {
    case (.number(let left), .number(let right)):
        return left == right
    case (.object(let left), .object(let right)):
        return ObjectIdentifier(left) == ObjectIdentifier(right)
    default:
        return false
    }
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

@inline(__always) private func clampToInt32(_ value: Int64) -> Int32 {
    if value < Int64(Int32.min) {
        return Int32.min
    }
    if value > Int64(Int32.max) {
        return Int32.max
    }
    return Int32(value)
}

@inline(__always) private func terrainCellBlockCount(fromNoiseSize size: Int) -> Int32 {
    let shift = max(0, min(30, size + 1))
    return Int32(1 << shift)
}

@inline(__always) private func lodCellBlockCount(fromNoiseSize size: Int) -> Int32 {
    let shift = max(1, min(30, size))
    return Int32(1 << shift)
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
    func sectionAxisData(chunkStartX: Int32, chunkStartZ: Int32) -> VoronoiSectionAxisData {
        var pxs = [Int32](repeating: 0, count: ProtoChunkSection.sideLength)
        var pzs = [Int32](repeating: 0, count: ProtoChunkSection.sideLength)
        var dxs = [Int32](repeating: 0, count: ProtoChunkSection.sideLength)
        var dzs = [Int32](repeating: 0, count: ProtoChunkSection.sideLength)
        let startX = chunkStartX &- 2
        let startZ = chunkStartZ &- 2
        var minPX = Int32.max
        var maxPX = Int32.min
        var minPZ = Int32.max
        var maxPZ = Int32.min

        for localX in 0..<ProtoChunkSection.sideLength {
            let x = startX &+ Int32(localX)
            let pX = x >> 2
            pxs[localX] = pX
            dxs[localX] = (x & 3) &* 10_240
            minPX = min(minPX, pX)
            maxPX = max(maxPX, pX)
        }
        for localZ in 0..<ProtoChunkSection.sideLength {
            let z = startZ &+ Int32(localZ)
            let pZ = z >> 2
            pzs[localZ] = pZ
            dzs[localZ] = (z & 3) &* 10_240
            minPZ = min(minPZ, pZ)
            maxPZ = max(maxPZ, pZ)
        }

        return VoronoiSectionAxisData(
            dxs: dxs,
            dzs: dzs,
            xRuns: voronoiAxisRuns(from: pxs),
            zRuns: voronoiAxisRuns(from: pzs),
            minPX: minPX,
            maxPX: maxPX,
            minPZ: minPZ,
            maxPZ: maxPZ
        )
    }

    func sectionBiomeLatticeMap(
        axisData: VoronoiSectionAxisData,
        sectionStartY: Int32,
        voronoiSHA: UInt64
    ) -> SectionBiomeLatticeMap {
        let startY = sectionStartY &- 2
        let yPattern = VoronoiYAxisPattern.byStartRemainder[Int(startY & 3)]
        let minPY = startY >> 2
        let maxPY = minPY &+ yPattern.maxCellOffset
        let offsetCountX = Int(axisData.maxPX - axisData.minPX + 2)
        let offsetCountY = Int(maxPY - minPY + 2)
        let offsetCountZ = Int(axisData.maxPZ - axisData.minPZ + 2)
        let offsetCount = offsetCountX * offsetCountY * offsetCountZ
        var offsetXs = [Int32](repeating: 0, count: offsetCount)
        var offsetYs = [Int32](repeating: 0, count: offsetCount)
        var offsetZs = [Int32](repeating: 0, count: offsetCount)
        var uniqueIndicesByCell = [Int16](repeating: -1, count: offsetCountX * offsetCountY * offsetCountZ)

        @inline(__always)
        func offsetIndex(_ x: Int, _ y: Int, _ z: Int) -> Int {
            return (y * offsetCountZ + z) * offsetCountX + x
        }

        for offsetY in 0..<offsetCountY {
            let cellY = minPY &+ Int32(offsetY)
            for offsetZ in 0..<offsetCountZ {
                let cellZ = axisData.minPZ &+ Int32(offsetZ)
                for offsetX in 0..<offsetCountX {
                    let cellX = axisData.minPX &+ Int32(offsetX)
                    let index = offsetIndex(offsetX, offsetY, offsetZ)
                    let offset = Self.getVoronoiCell(voronoiSHA, cellX, cellY, cellZ)
                    offsetXs[index] = offset.x
                    offsetYs[index] = offset.y
                    offsetZs[index] = offset.z
                }
            }
        }

        var uniquePositions: [BiomeLatticePosition] = []
        uniquePositions.reserveCapacity(1024)
        var blockToUniqueIndex = [UInt16](repeating: 0, count: ProtoChunkSection.blockCount)
        var samplingOrder: [UInt16] = []
        samplingOrder.reserveCapacity(1024)
        let cornerXBits = [0, 0, 0, 0, 1, 1, 1, 1]
        let cornerYBits = [0, 0, 1, 1, 0, 0, 1, 1]
        let cornerZBits = [0, 1, 0, 1, 0, 1, 0, 1]
        let cellShift = Int32(40 * 1024)
        var xTerms = [UInt64](repeating: 0, count: ProtoChunkSection.sideLength * 8)
        var yTerms = [UInt64](repeating: 0, count: ProtoChunkSection.sideLength * 8)
        var zTerms = [UInt64](repeating: 0, count: ProtoChunkSection.sideLength * 8)

        for yRun in yPattern.runs {
            let offsetY = Int(yRun.p)
            for zRun in axisData.zRuns {
                let offsetZ = Int(zRun.p - axisData.minPZ)
                for xRun in axisData.xRuns {
                    let offsetX = Int(xRun.p - axisData.minPX)
                    let yRunP = minPY &+ yRun.p

                    for cornerIndex in 0..<8 {
                        let bx = cornerXBits[cornerIndex]
                        let by = cornerYBits[cornerIndex]
                        let bz = cornerZBits[cornerIndex]
                        let cellIndex = offsetIndex(offsetX + bx, offsetY + by, offsetZ + bz)
                        let xBase = offsetXs[cellIndex] &- cellShift &* Int32(bx)
                        let yBase = offsetYs[cellIndex] &- cellShift &* Int32(by)
                        let zBase = offsetZs[cellIndex] &- cellShift &* Int32(bz)
                        let termBase = cornerIndex * ProtoChunkSection.sideLength

                        for localX in xRun.start..<xRun.endExclusive {
                            let rx = Int64(xBase &+ axisData.dxs[localX])
                            xTerms[termBase + localX] = UInt64(rx &* rx)
                        }
                        for localY in yRun.start..<yRun.endExclusive {
                            let ry = Int64(yBase &+ yPattern.dys[localY])
                            yTerms[termBase + localY] = UInt64(ry &* ry)
                        }
                        for localZ in zRun.start..<zRun.endExclusive {
                            let rz = Int64(zBase &+ axisData.dzs[localZ])
                            zTerms[termBase + localZ] = UInt64(rz &* rz)
                        }
                    }

                    for localY in yRun.start..<yRun.endExclusive {
                        let yBlockBase = localY << 8
                        for localZ in zRun.start..<zRun.endExclusive {
                            let yzBlockBase = yBlockBase | (localZ << 4)
                            for localX in xRun.start..<xRun.endExclusive {
                                var bestCorner = 0
                                var bestDistance = UInt64.max

                                for cornerIndex in 0..<8 {
                                    let termBase = cornerIndex * ProtoChunkSection.sideLength
                                    let distance = xTerms[termBase + localX]
                                        &+ yTerms[termBase + localY]
                                        &+ zTerms[termBase + localZ]
                                    if distance < bestDistance {
                                        bestDistance = distance
                                        bestCorner = cornerIndex
                                    }
                                }

                                let bx = cornerXBits[bestCorner]
                                let by = cornerYBits[bestCorner]
                                let bz = cornerZBits[bestCorner]
                                let uniqueIndex = offsetIndex(offsetX + bx, offsetY + by, offsetZ + bz)
                                let blockIndex = yzBlockBase | localX
                                let existingIndex = uniqueIndicesByCell[uniqueIndex]
                                if existingIndex >= 0 {
                                    blockToUniqueIndex[blockIndex] = UInt16(existingIndex)
                                } else {
                                    let newIndex = UInt16(uniquePositions.count)
                                    uniquePositions.append(
                                        BiomeLatticePosition(
                                            PosInt3D(
                                                x: xRun.p &+ Int32(bx),
                                                y: yRunP &+ Int32(by),
                                                z: zRun.p &+ Int32(bz)
                                            )
                                        )
                                    )
                                    uniqueIndicesByCell[uniqueIndex] = Int16(bitPattern: newIndex)
                                    blockToUniqueIndex[blockIndex] = newIndex
                                }
                            }
                        }
                    }
                }
            }
        }

        for offsetZ in 0..<offsetCountZ {
            for offsetX in 0..<offsetCountX {
                for offsetY in 0..<offsetCountY {
                    let uniqueIndex = uniqueIndicesByCell[offsetIndex(offsetX, offsetY, offsetZ)]
                    if uniqueIndex >= 0 {
                        samplingOrder.append(UInt16(uniqueIndex))
                    }
                }
            }
        }

        return SectionBiomeLatticeMap(
            uniquePositions: uniquePositions,
            blockToUniqueIndex: blockToUniqueIndex,
            samplingOrder: samplingOrder
        )
    }

    @inline(__always)
    static func getVoronoiCell(_ sha: UInt64, _ a: Int32, _ b: Int32, _ c: Int32) -> PosInt3D {
        var seed = sha
        seed = Self.stepSeed(seed, salt: Self.salt(a))
        seed = Self.stepSeed(seed, salt: Self.salt(b))
        seed = Self.stepSeed(seed, salt: Self.salt(c))
        seed = Self.stepSeed(seed, salt: Self.salt(a))
        seed = Self.stepSeed(seed, salt: Self.salt(b))
        seed = Self.stepSeed(seed, salt: Self.salt(c))

        let x = (Int32((seed >> 24) & 1023) &- 512) &* 36
        seed = Self.stepSeed(seed, salt: sha)
        let y = (Int32((seed >> 24) & 1023) &- 512) &* 36
        seed = Self.stepSeed(seed, salt: sha)
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

    static func makeVoronoiSHA(_ seed: WorldSeed) -> UInt64 {
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

    var bufferedSamplingBounds: ChunkSamplingBounds {
        return self.bounds
    }
}

final class ChunkFlatCache: DensityFunction, DensityFunctionWrapperIntrospectable {
    private let delegate: any DensityFunction
    private let bounds: ChunkSamplingBounds
    private let startBiomeX: Int32
    private let startBiomeZ: Int32
    private let horizontalCacheSize: Int
    private var cache: [Double]

    init(wrapping delegate: any DensityFunction, bounds: ChunkSamplingBounds) {
        self.delegate = delegate
        self.bounds = bounds
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

    var bufferedSamplingBounds: ChunkSamplingBounds {
        return self.bounds
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

    var bufferedSamplingBounds: ChunkSamplingBounds {
        return self.bounds
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

    var bufferedSamplingBounds: ChunkSamplingBounds {
        return self.bounds
    }

    var bufferedHorizontalCellBlockCount: Int32 {
        return self.horizontalCellBlockCount
    }

    var bufferedVerticalCellBlockCount: Int32 {
        return self.verticalCellBlockCount
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
            let baked = withAutoAppliedFlatCache(try self.bindDensityFunction(function), bounds: self.bounds)
            self.memo[key] = baked
            return baked
        }
        return withAutoAppliedFlatCache(try self.bindDensityFunction(function), bounds: self.bounds)
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
        {
            return function
        }
        if function is ChunkFlatCache
            || function is ChunkCache2D
            || function is ChunkPositionCache
            || function is ChunkInterpolatedCache
        {
            return function
        }
        if let cacheMarker = function as? CacheMarker {
            return try self.bake(cacheMarker: cacheMarker)
        }
        if let unary = function as? UnaryDensityFunction {
            let operand = try self.bakeDensityFunction(unary.inputOperand)
            guard !sameDensityFunctionInstance(operand, unary.inputOperand) else {
                return function
            }
            return UnaryDensityFunction(operand: operand, type: unary.operationType)
        }
        if let binary = function as? BinaryDensityFunction {
            let first = try self.bakeDensityFunction(binary.firstOperand)
            let second = try self.bakeDensityFunction(binary.secondOperand)
            guard !sameDensityFunctionInstance(first, binary.firstOperand)
                || !sameDensityFunctionInstance(second, binary.secondOperand)
            else {
                return function
            }
            return BinaryDensityFunction(firstOperand: first, secondOperand: second, type: binary.operationType)
        }
        if let clampFunction = function as? ClampDensityFunction {
            let input = try self.bakeDensityFunction(clampFunction.clampedInput)
            guard !sameDensityFunctionInstance(input, clampFunction.clampedInput) else {
                return function
            }
            return ClampDensityFunction(
                input: input,
                lowerBound: clampFunction.minimumValue,
                upperBound: clampFunction.maximumValue
            )
        }
        if let rangeChoice = function as? RangeChoice {
            let inputChoice = try self.bakeDensityFunction(rangeChoice.inputChoiceFunction)
            let whenInRange = try self.bakeDensityFunction(rangeChoice.whenInRangeOutput)
            let whenOutOfRange = try self.bakeDensityFunction(rangeChoice.whenOutOfRangeOutput)
            guard !sameDensityFunctionInstance(inputChoice, rangeChoice.inputChoiceFunction)
                || !sameDensityFunctionInstance(whenInRange, rangeChoice.whenInRangeOutput)
                || !sameDensityFunctionInstance(whenOutOfRange, rangeChoice.whenOutOfRangeOutput)
            else {
                return function
            }
            return RangeChoice(
                inputChoice: inputChoice,
                minInclusive: rangeChoice.minimumInclusive,
                maxExclusive: rangeChoice.maximumExclusive,
                whenInRange: whenInRange,
                whenOutOfRange: whenOutOfRange
            )
        }
        if let shiftedNoise = function as? ShiftedNoise {
            let shiftX = try self.bakeDensityFunction(shiftedNoise.shiftXFunction)
            let shiftY = try self.bakeDensityFunction(shiftedNoise.shiftYFunction)
            let shiftZ = try self.bakeDensityFunction(shiftedNoise.shiftZFunction)
            guard !sameDensityFunctionInstance(shiftX, shiftedNoise.shiftXFunction)
                || !sameDensityFunctionInstance(shiftY, shiftedNoise.shiftYFunction)
                || !sameDensityFunctionInstance(shiftZ, shiftedNoise.shiftZFunction)
            else {
                return function
            }
            return ShiftedNoise(
                noise: shiftedNoise.noiseSampler,
                shiftX: shiftX,
                shiftY: shiftY,
                shiftZ: shiftZ,
                scaleXZ: shiftedNoise.xzScaleValue,
                scaleY: shiftedNoise.yScaleValue
            )
        }
        if let blendDensity = function as? BlendDensity {
            let argument = try self.bakeDensityFunction(blendDensity.argumentFunction)
            guard !sameDensityFunctionInstance(argument, blendDensity.argumentFunction) else {
                return function
            }
            return BlendDensity(wrapping: argument)
        }
        if let weirdScaledSampler = function as? WeirdScaledSampler {
            let input = try self.bakeDensityFunction(weirdScaledSampler.inputFunction)
            guard !sameDensityFunctionInstance(input, weirdScaledSampler.inputFunction) else {
                return function
            }
            return WeirdScaledSampler(
                type: weirdScaledSampler.scalingType,
                withInput: input,
                withNoise: weirdScaledSampler.noiseSampler
            )
        }
        if let splineDensity = function as? SplineDensityFunction {
            let segment = try self.bindSplineSegment(splineDensity.splineSegment)
            guard !sameSplineSegmentIdentity(segment, splineDensity.splineSegment) else {
                return function
            }
            return SplineDensityFunction(withSpline: segment)
        }
        if let topSurface = function as? FindTopSurface {
            let density = try self.bakeDensityFunction(topSurface.densityFunction)
            let upperBound = try self.bakeDensityFunction(topSurface.upperBoundFunction)
            guard !sameDensityFunctionInstance(density, topSurface.densityFunction)
                || !sameDensityFunctionInstance(upperBound, topSurface.upperBoundFunction)
            else {
                return function
            }
            return FindTopSurface(
                density: density,
                upperBound: upperBound,
                lowerBound: topSurface.lowerBoundHeight,
                cellHeight: topSurface.cellHeightValue
            )
        }
        if function is ShiftDensityFunction || function is NoiseDensityFunction {
            return function
        }
        return try function.bake(withBaker: self)
    }

    private func bindSplineSegment(_ segment: SplineSegment) throws -> SplineSegment {
        switch segment {
        case .number:
            return segment
        case .object(let object):
            let input = try self.bakeDensityFunction(object.inputFunction)
            var didChange = !sameDensityFunctionInstance(input, object.inputFunction)
            var values: [SplineSegment] = []
            values.reserveCapacity(object.pointValues.count)
            for value in object.pointValues {
                let boundValue = try self.bindSplineSegment(value)
                if !sameSplineSegmentIdentity(boundValue, value) {
                    didChange = true
                }
                values.append(boundValue)
            }
            guard didChange else {
                return segment
            }
            return .object(
                SplineObject(
                    withInput: input,
                    locations: object.pointLocations,
                    values: values,
                    derivatives: object.pointDerivatives
                )
            )
        }
    }

    private enum BakingErrors: Error {
        case noiseNotAlreadyBaked(String)
        case referenceNotAlreadyBaked(String)
    }
}

/// Stores one 16x16x16 chunk section of terrain, exact block-biome data, and quart-biome data.
/// Not concurrency-safe; callers must synchronize concurrent reads and writes.
public final class ProtoChunkSection {
    /// The length of each block axis in a section.
    public static let sideLength = 16
    /// The number of block positions in a section.
    public static let blockCount = sideLength * sideLength * sideLength
    /// The number of words in the solid-terrain bitmap.
    public static let bitmapWordCount = blockCount / 64
    /// The length of each quart-biome axis in a section.
    public static let biomeSideLength = 4
    /// The number of quart-biome positions in a section.
    public static let biomeCount = biomeSideLength * biomeSideLength * biomeSideLength

    private var terrainBitmap = [UInt64](repeating: 0, count: bitmapWordCount)
    private let defaultTerrainState: BlockState
    private var blockOverrides: [Int: BlockState] = [:]
    private var blockBiomes = [RegistryKey<Biome>?](repeating: nil, count: blockCount)
    private var quartBiomes = [RegistryKey<Biome>?](repeating: nil, count: biomeCount)

    /// Creates an empty section with no terrain bits and no assigned biomes.
    /// Not concurrency-safe.
    public init(
        defaultTerrainState: BlockState = BlockState(id: "minecraft:stone"),
        storesBiomeData: Bool = true
    ) {
        self.defaultTerrainState = defaultTerrainState
        if !storesBiomeData {
            self.blockBiomes = []
            self.quartBiomes = []
        }
    }

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
        self.blockOverrides.removeAll(keepingCapacity: true)
        if !self.blockBiomes.isEmpty {
            self.blockBiomes = [RegistryKey<Biome>?](repeating: nil, count: Self.blockCount)
        }
        if !self.quartBiomes.isEmpty {
            self.quartBiomes = [RegistryKey<Biome>?](repeating: nil, count: Self.biomeCount)
        }
    }

    @inline(__always) func setTerrainUnchecked(_ isSolid: Bool, blockIndex: Int) {
        let wordIndex = blockIndex >> 6
        let bitMask = UInt64(1) << UInt64(blockIndex & 63)
        if isSolid {
            self.terrainBitmap[wordIndex] |= bitMask
        } else {
            self.terrainBitmap[wordIndex] &= ~bitMask
        }
        self.blockOverrides.removeValue(forKey: blockIndex)
    }

    @inline(__always) func setBlockUnchecked(_ state: BlockState, blockIndex: Int) {
        let solid = Self.isSolid(state)
        let wordIndex = blockIndex >> 6
        let bitMask = UInt64(1) << UInt64(blockIndex & 63)
        if solid {
            self.terrainBitmap[wordIndex] |= bitMask
        } else {
            self.terrainBitmap[wordIndex] &= ~bitMask
        }
        let implicitState = solid ? self.defaultTerrainState : Blocks.airState
        if state == implicitState {
            self.blockOverrides.removeValue(forKey: blockIndex)
        } else {
            self.blockOverrides[blockIndex] = state
        }
    }

    /// Stores a generated material while retaining raw final-density occupancy.
    @inline(__always) func setGeneratedBlockUnchecked(
        _ state: BlockState?,
        isDensityTerrain: Bool,
        blockIndex: Int
    ) {
        let state = state ?? self.defaultTerrainState
        let wordIndex = blockIndex >> 6
        let bitMask = UInt64(1) << UInt64(blockIndex & 63)
        if isDensityTerrain {
            self.terrainBitmap[wordIndex] |= bitMask
        } else {
            self.terrainBitmap[wordIndex] &= ~bitMask
        }
        let implicitState = isDensityTerrain ? self.defaultTerrainState : Blocks.airState
        if state == implicitState {
            self.blockOverrides.removeValue(forKey: blockIndex)
        } else {
            self.blockOverrides[blockIndex] = state
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
        self.blockOverrides.removeValue(forKey: blockIndex)
    }

    @inline(__always) func setBlock(_ state: BlockState, at pos: PosInt3D) {
        let blockIndex = Self.blockIndex(pos)
        let solid = Self.isSolid(state)
        self.setTerrainBitmap(solid, at: pos)
        let implicitState = solid ? self.defaultTerrainState : Blocks.airState
        if state == implicitState {
            self.blockOverrides.removeValue(forKey: blockIndex)
        } else {
            self.blockOverrides[blockIndex] = state
        }
    }

    @inline(__always) func block(at pos: PosInt3D) -> BlockState {
        let blockIndex = Self.blockIndex(pos)
        if let override = self.blockOverrides[blockIndex] { return override }
        return self.isTerrain(at: pos) ? self.defaultTerrainState : Blocks.airState
    }

    @inline(__always) private func setTerrainBitmap(_ isSolid: Bool, at pos: PosInt3D) {
        let blockIndex = (Int(pos.y) << 8) | (Int(pos.z) << 4) | Int(pos.x)
        let wordIndex = blockIndex >> 6
        let bitMask = UInt64(1) << UInt64(blockIndex & 63)
        if isSolid {
            self.terrainBitmap[wordIndex] |= bitMask
        } else {
            self.terrainBitmap[wordIndex] &= ~bitMask
        }
    }

    @inline(__always) private static func isSolid(_ state: BlockState) -> Bool {
        !state.isAir && state.id != "minecraft:water" && state.id != "minecraft:lava"
    }

    @inline(__always) private static func blockIndex(_ pos: PosInt3D) -> Int {
        (Int(pos.y) << 8) | (Int(pos.z) << 4) | Int(pos.x)
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

    @inline(__always) func setBiomesUnchecked(_ biomes: [RegistryKey<Biome>], using blockToBiomeIndex: [UInt16]) {
        self.blockBiomes.withUnsafeMutableBufferPointer { blockBiomes in
            let blockBase = blockBiomes.baseAddress!
            for blockIndex in 0..<Self.blockCount {
                blockBase[blockIndex] = biomes[Int(blockToBiomeIndex[blockIndex])]
            }
        }
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
    /// The horizontal length of a chunk in blocks.
    public static let sideLength = 16
    /// The vertical length of each chunk section in blocks.
    public static let sectionHeight = 16
    /// The horizontal length of a chunk in quart-biome coordinates.
    public static let biomeSideLength = 4
    /// The number of blocks represented by one quart-biome coordinate.
    public static let biomeScale = 4

    public private(set) var minY: Int32 = 0
    public private(set) var height: Int32 = 0
    private var sections: [ProtoChunkSection] = []
    private var defaultTerrainState = BlockState(id: "minecraft:stone")
    var aquiferSampler: AquiferSampler?

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
    public func configure(
        minY: Int32,
        height: Int32,
        defaultTerrainState: BlockState = BlockState(id: "minecraft:stone"),
        storesBiomeData: Bool = true
    ) throws {
        guard height > 0 && height % Int32(Self.sectionHeight) == 0 else {
            throw WorldGenerationErrors.invalidProtoChunkHeight(Int(height))
        }

        self.minY = minY
        self.height = height
        self.defaultTerrainState = defaultTerrainState
        self.aquiferSampler = nil
        self.sections = (0..<Int(height / Int32(Self.sectionHeight))).map { _ in
            ProtoChunkSection(defaultTerrainState: defaultTerrainState, storesBiomeData: storesBiomeData)
        }
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

    /// Sets a block state at one chunk-local position and keeps the terrain bitmap in sync.
    @inline(__always) public func setBlock(_ state: BlockState, atLocal pos: PosInt3D) {
        precondition(pos.x >= 0 && pos.x < Int32(Self.sideLength), "x position out of range")
        precondition(pos.y >= 0 && pos.y < self.height, "y position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.sideLength), "z position out of range")
        let sectionIndex = Int(pos.y) >> 4
        self.sections[sectionIndex].setBlock(state, at: PosInt3D(x: pos.x, y: pos.y & 15, z: pos.z))
    }

    /// Returns the block state at one chunk-local position.
    @inline(__always) public func block(atLocal pos: PosInt3D) -> BlockState {
        precondition(pos.x >= 0 && pos.x < Int32(Self.sideLength), "x position out of range")
        precondition(pos.y >= 0 && pos.y < self.height, "y position out of range")
        precondition(pos.z >= 0 && pos.z < Int32(Self.sideLength), "z position out of range")
        let sectionIndex = Int(pos.y) >> 4
        return self.sections[sectionIndex].block(at: PosInt3D(x: pos.x, y: pos.y & 15, z: pos.z))
    }
}

/// Optional metadata to compute for each three-dimensional terrain LOD sample.
public struct TerrainLODPayloadOptions: OptionSet, Sendable, Equatable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Include exact block-biome samples from the generated chunk at each LOD sample point.
    public static let biome = TerrainLODPayloadOptions(rawValue: 1 << 0)
    /// Include a material ID derived from the current terrain occupancy model (`minecraft:stone` or `minecraft:air`).
    public static let material = TerrainLODPayloadOptions(rawValue: 1 << 1)
}

/// Optional biome and material metadata attached to one terrain LOD sample.
public struct TerrainLODSamplePayload: Equatable {
    public let biome: RegistryKey<Biome>?
    public let materialID: String?
}

/// The chunk coordinates used to index grouped LOD output.
public struct TerrainLODChunkKey: Hashable, Sendable {
    public let x: Int32
    public let z: Int32

    public init(x: Int32, z: Int32) {
        self.x = x
        self.z = z
    }
}

/// One point-sampled terrain column returned by `WorldGenerator.sampleLOD(from:radius:startingRadius:radiusStep:maxCellSizePower:threadCount:payloads:)`.
public struct TerrainLODColumn: Equatable {
    public let x: Int32
    public let z: Int32
    public let cellSize: Int32
    public let samples: [Bool]
    public let samplePayloads: [TerrainLODSamplePayload]?
}

/// Terrain LOD columns grouped by their containing chunk.
public struct TerrainLODChunk: Equatable {
    public let key: TerrainLODChunkKey
    public let columns: [TerrainLODColumn]
}

/// A chunk-indexed set of adaptive terrain columns sampled around an origin.
public struct TerrainLODResult: Equatable {
    public let originX: Int32
    public let originY: Int32
    public let originZ: Int32
    public let radius: Int32
    public let startingRadius: Int32
    public let radiusStep: Int32
    public let maxCellSizePower: Int
    public let baseCellSize: Int32
    public let minX: Int32
    public let minY: Int32
    public let minZ: Int32
    public let maxXExclusive: Int32
    public let maxYExclusive: Int32
    public let maxZExclusive: Int32
    public let payloads: TerrainLODPayloadOptions
    public let chunks: [TerrainLODChunk]
    public let chunkIndex: [TerrainLODChunkKey: Int]

    public var columns: [TerrainLODColumn] {
        return self.chunks.flatMap(\.columns)
    }
}

/// One adaptive horizontal cell containing an optional surface height and biome.
public struct TerrainSurfaceLODCell: Equatable {
    public let x: Int32
    public let z: Int32
    public let cellSize: Int32
    public let surfaceY: Int32?
    public let surfaceBiome: RegistryKey<Biome>?
}

/// Surface LOD cells grouped by their containing chunk.
public struct TerrainSurfaceLODChunk: Equatable {
    public let key: TerrainLODChunkKey
    public let cells: [TerrainSurfaceLODCell]
}

/// A chunk-indexed set of adaptive 2D terrain-surface samples around an origin.
public struct TerrainSurfaceLODResult: Equatable {
    public let originX: Int32
    public let originY: Int32
    public let originZ: Int32
    public let radius: Int32
    public let startingRadius: Int32
    public let radiusStep: Int32
    public let maxCellSizePower: Int
    public let baseCellSize: Int32
    public let minX: Int32
    public let minY: Int32
    public let minZ: Int32
    public let maxXExclusive: Int32
    public let maxYExclusive: Int32
    public let maxZExclusive: Int32
    public let chunks: [TerrainSurfaceLODChunk]
    public let chunkIndex: [TerrainLODChunkKey: Int]

    public var cells: [TerrainSurfaceLODCell] {
        return self.chunks.flatMap(\.cells)
    }
}

/// A progress snapshot emitted while streaming terrain or surface LOD chunks.
public struct TerrainLODProgress: Sendable, Equatable {
    public let completedChunkCount: Int
    public let totalChunkCount: Int
    public let completedSampleCount: Int
    public let totalSampleCount: Int
    public let lastCompletedChunkKey: TerrainLODChunkKey?

    public var fractionCompleted: Double {
        guard self.totalSampleCount > 0 else {
            return 1.0
        }
        return Double(self.completedSampleCount) / Double(self.totalSampleCount)
    }

    public var isFinished: Bool {
        return self.completedChunkCount >= self.totalChunkCount
            && self.completedSampleCount >= self.totalSampleCount
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

private struct ChunkGenerationDensityFunctions {
    let terrainDensity: any DensityFunction
    let biomeDensityFunctions: ChunkBiomeDensityFunctions
}

private struct DirectPointSamplingDensityFunctionVariant {
    let finalDensity: any DensityFunction
    let preliminarySurfaceLevel: (any DensityFunction)?
    let initialDensityWithoutJaggedness: (any DensityFunction)?
    let biomeDensityFunctions: ChunkBiomeDensityFunctions
}

private struct DirectPointSamplingDensityFunctions {
    let cached: DirectPointSamplingDensityFunctionVariant
    let cacheless: DirectPointSamplingDensityFunctionVariant
}

private enum DirectPointSamplingCacheMode {
    case preserveWorldScaleCaches
    case stripAllCaches
}

enum ChunkBiomeGenerationMode {
    case quartOnly
    case blockOnly
    case quartAndBlock
}

#if DEBUG && !(os(WASI) || arch(wasm32))
struct ChunkGenerationComponentBenchmark {
    let configureNanos: UInt64
    let samplerInitNanos: UInt64
    let sharedBakeNanos: UInt64
    let terrainOnlyNanos: UInt64
    let quartBiomesOnlyNanos: UInt64
    let blockBiomesOnlyNanos: UInt64
    let fullGenerateIntoNanos: UInt64
}

struct TimedComponentBenchmark {
    let callCount: UInt64
    let totalNanos: UInt64
}

struct ChunkBiomeGenerationDetailedBenchmark {
    let temperature: TimedComponentBenchmark
    let humidity: TimedComponentBenchmark
    let continentalness: TimedComponentBenchmark
    let erosion: TimedComponentBenchmark
    let weirdness: TimedComponentBenchmark
    let depth: TimedComponentBenchmark
    let searchTree: TimedComponentBenchmark
}

struct ChunkTerrainGenerationDetailedBenchmark {
    let terrainDensity: TimedComponentBenchmark
}

struct ChunkGenerationDetailedProfileBenchmark {
    let configureNanos: UInt64
    let samplerInitNanos: UInt64
    let sharedBakeNanos: UInt64
    let terrainOnlyNanos: UInt64
    let terrainOnlyProfile: ChunkTerrainGenerationDetailedBenchmark
    let quartBiomesOnlyNanos: UInt64
    let quartBiomesOnlyProfile: ChunkBiomeGenerationDetailedBenchmark?
    let blockBiomesOnlyNanos: UInt64
    let blockBiomesOnlyProfile: ChunkBiomeGenerationDetailedBenchmark?
    let fullGenerateIntoNanos: UInt64
    let fullTerrainProfile: ChunkTerrainGenerationDetailedBenchmark
    let fullBiomeProfile: ChunkBiomeGenerationDetailedBenchmark?
}

private func benchmarkRuntimeOnlyDecodeError(_ decoder: any Decoder, forType typeName: String) -> DecodingError {
    return DecodingError.dataCorrupted(
        DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "\(typeName) is a runtime-only benchmark profiling wrapper."
        )
    )
}

private func benchmarkRuntimeOnlyEncodeError(_ encoder: any Encoder, forType typeName: String) -> EncodingError {
    return EncodingError.invalidValue(
        typeName,
        EncodingError.Context(
            codingPath: encoder.codingPath,
            debugDescription: "\(typeName) is a runtime-only benchmark profiling wrapper."
        )
    )
}

final class MutableTimedComponentBenchmark {
    var callCount: UInt64 = 0
    var totalNanos: UInt64 = 0

    @inline(__always)
    func record<T>(_ body: () -> T) -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = body()
        self.totalNanos &+= DispatchTime.now().uptimeNanoseconds - start
        self.callCount &+= 1
        return value
    }

    func snapshot() -> TimedComponentBenchmark {
        return TimedComponentBenchmark(callCount: self.callCount, totalNanos: self.totalNanos)
    }
}

private final class MutableChunkBiomeGenerationDetailedBenchmark {
    let temperature = MutableTimedComponentBenchmark()
    let humidity = MutableTimedComponentBenchmark()
    let continentalness = MutableTimedComponentBenchmark()
    let erosion = MutableTimedComponentBenchmark()
    let weirdness = MutableTimedComponentBenchmark()
    let depth = MutableTimedComponentBenchmark()
    let searchTree = MutableTimedComponentBenchmark()

    func snapshot() -> ChunkBiomeGenerationDetailedBenchmark {
        return ChunkBiomeGenerationDetailedBenchmark(
            temperature: self.temperature.snapshot(),
            humidity: self.humidity.snapshot(),
            continentalness: self.continentalness.snapshot(),
            erosion: self.erosion.snapshot(),
            weirdness: self.weirdness.snapshot(),
            depth: self.depth.snapshot(),
            searchTree: self.searchTree.snapshot()
        )
    }
}

private final class MutableChunkTerrainGenerationDetailedBenchmark {
    let terrainDensity = MutableTimedComponentBenchmark()

    func snapshot() -> ChunkTerrainGenerationDetailedBenchmark {
        return ChunkTerrainGenerationDetailedBenchmark(terrainDensity: self.terrainDensity.snapshot())
    }
}

final class BenchmarkProfilingDensityFunction: DensityFunction, DensityFunctionWrapperIntrospectable {
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
        throw benchmarkRuntimeOnlyDecodeError(decoder, forType: "BenchmarkProfilingDensityFunction")
    }

    func encode(to encoder: any Encoder) throws {
        throw benchmarkRuntimeOnlyEncodeError(encoder, forType: "BenchmarkProfilingDensityFunction")
    }
}
#endif

private final class SharedTerrainLODProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let totalChunkCount: Int
    private let totalSampleCount: Int
    private let handler: (@Sendable (TerrainLODProgress) -> Void)?
    private var completedChunkCount = 0
    private var completedSampleCount = 0

    init(
        totalChunkCount: Int,
        totalSampleCount: Int,
        handler: (@Sendable (TerrainLODProgress) -> Void)?
    ) {
        self.totalChunkCount = totalChunkCount
        self.totalSampleCount = totalSampleCount
        self.handler = handler
    }

    func reportInitialProgress() {
        self.handler?(
            TerrainLODProgress(
                completedChunkCount: 0,
                totalChunkCount: self.totalChunkCount,
                completedSampleCount: 0,
                totalSampleCount: self.totalSampleCount,
                lastCompletedChunkKey: nil
            )
        )
    }

    func reportCompletedChunk(_ chunkKey: TerrainLODChunkKey, sampleCount: Int) {
        let progress: TerrainLODProgress
        self.lock.lock()
        self.completedChunkCount += 1
        self.completedSampleCount += sampleCount
        progress = TerrainLODProgress(
            completedChunkCount: self.completedChunkCount,
            totalChunkCount: self.totalChunkCount,
            completedSampleCount: self.completedSampleCount,
            totalSampleCount: self.totalSampleCount,
            lastCompletedChunkKey: chunkKey
        )
        self.lock.unlock()
        self.handler?(progress)
    }
}

private final class WeakCompiledDensityFunctionBulk {
    weak var value: CompiledDensityFunctionBulk?

    init(_ value: CompiledDensityFunctionBulk) {
        self.value = value
    }
}

/// One climate point and the biome selected from it by a multi-noise biome source.
public struct ClimateBiomeSample {
    public let climate: NoisePoint
    public let biome: RegistryKey<Biome>

    public init(climate: NoisePoint, biome: RegistryKey<Biome>) {
        self.climate = climate
        self.biome = biome
    }
}

/// A fixed-shape compiled sampler which evaluates climate values and biome selection together.
public final class CompiledClimateBiomeBulkSampler: @unchecked Sendable {
    public let strategy: CompilationBackend
    public let bufferContext: CompiledDensityFunctionBufferContext
    public let dimension: RegistryKey<Dimension>
    private let stateLock = NSLock()
    private var storedWasmModule: [UInt8]?
    private var implementation: (PosInt3D) -> [ClimateBiomeSample]

    /// A module exporting `sample_bulk` and `memory`, present only for the WASM strategy.
    public var wasmModule: [UInt8]? {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.storedWasmModule
    }

    init(
        strategy: CompilationBackend,
        wasmModule: [UInt8]? = nil,
        bufferContext: CompiledDensityFunctionBufferContext,
        dimension: RegistryKey<Dimension>,
        implementation: @escaping (PosInt3D) -> [ClimateBiomeSample]
    ) {
        self.strategy = strategy
        self.storedWasmModule = wasmModule
        self.bufferContext = bufferContext
        self.dimension = dimension
        self.implementation = implementation
    }

    func replaceImplementation(with replacement: CompiledClimateBiomeBulkSampler) {
        precondition(self.strategy == replacement.strategy)
        precondition(self.dimension == replacement.dimension)
        precondition(
            self.bufferContext.xCount == replacement.bufferContext.xCount
                && self.bufferContext.yCount == replacement.bufferContext.yCount
                && self.bufferContext.zCount == replacement.bufferContext.zCount
                && self.bufferContext.xStep == replacement.bufferContext.xStep
                && self.bufferContext.yStep == replacement.bufferContext.yStep
                && self.bufferContext.zStep == replacement.bufferContext.zStep
        )
        replacement.stateLock.lock()
        let replacementModule = replacement.storedWasmModule
        let replacementImplementation = replacement.implementation
        replacement.stateLock.unlock()
        self.stateLock.lock()
        self.storedWasmModule = replacementModule
        self.implementation = replacementImplementation
        self.stateLock.unlock()
    }

    /// Evaluates the fixed volume in z/x/y order.
    public func callAsFunction(at basePosition: PosInt3D) -> [ClimateBiomeSample] {
        self.stateLock.lock()
        let implementation = self.implementation
        self.stateLock.unlock()
        return implementation(basePosition)
    }
}

private final class WeakCompiledClimateBiomeBulkSampler {
    weak var value: CompiledClimateBiomeBulkSampler?

    init(_ value: CompiledClimateBiomeBulkSampler) {
        self.value = value
    }
}

private final class WeakCompiledNoiseRouterBiomeBulkSampler {
    weak var value: CompiledNoiseRouterBiomeBulkSampler?
    let dimension: RegistryKey<Dimension>

    init(_ value: CompiledNoiseRouterBiomeBulkSampler, dimension: RegistryKey<Dimension>) {
        self.value = value
        self.dimension = dimension
    }
}

private struct SectionBiomeLatticeMap {
    let uniquePositions: [BiomeLatticePosition]
    let blockToUniqueIndex: [UInt16]
    let samplingOrder: [UInt16]
}

private struct VoronoiSectionAxisData {
    let dxs: [Int32]
    let dzs: [Int32]
    let xRuns: [VoronoiAxisRun]
    let zRuns: [VoronoiAxisRun]
    let minPX: Int32
    let maxPX: Int32
    let minPZ: Int32
    let maxPZ: Int32
}

private struct VoronoiAxisRun {
    let start: Int
    let endExclusive: Int
    let p: Int32
}

private struct VoronoiYAxisPattern {
    let dys: [Int32]
    let runs: [VoronoiAxisRun]
    let maxCellOffset: Int32

    static let byStartRemainder: [VoronoiYAxisPattern] = (0..<4).map { startRemainder in
        var pys = [Int32](repeating: 0, count: ProtoChunkSection.sideLength)
        var dys = [Int32](repeating: 0, count: ProtoChunkSection.sideLength)
        for localY in 0..<ProtoChunkSection.sideLength {
            let y = startRemainder + localY
            pys[localY] = Int32(y >> 2)
            dys[localY] = Int32(y & 3) &* 10_240
        }
        return VoronoiYAxisPattern(
            dys: dys,
            runs: voronoiAxisRuns(from: pys),
            maxCellOffset: pys.last ?? 0
        )
    }
}

private func voronoiAxisRuns(from positions: [Int32]) -> [VoronoiAxisRun] {
    precondition(!positions.isEmpty)
    var runs: [VoronoiAxisRun] = []
    runs.reserveCapacity(5)
    var start = 0
    var current = positions[0]
    for index in 1..<positions.count {
        if positions[index] == current { continue }
        runs.append(VoronoiAxisRun(start: start, endExclusive: index, p: current))
        start = index
        current = positions[index]
    }
    runs.append(VoronoiAxisRun(start: start, endExclusive: positions.count, p: current))
    return runs
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
    private var worldSeed: WorldSeed
    private let biomeSubsampler = VoronoiBiomeSubsampler()
    private var voronoiSHA: UInt64
    private var datapacks: [DataPack] = []
    private var config: NoiseSettings?
    /// The selected noise settings before their seed-dependent density functions are baked.
    private var unbakedConfig: NoiseSettings?
    private let configuredSettingsKeyName: String?
    private let compilationBackend: CompilationBackend?
    private let useBiomeSearchAlternative: Bool
    private let wasmRuntime: (any WASMRuntime)?
    private var configuredDimensionKey: RegistryKey<Dimension>?
    private var registries = WorldGenerationRegistries()
    private let sharedSeededNoises = SharedSeededNoiseStorage()
    private var hasInitialisedCompiledSeedState = false
    private var searchTrees: [RegistryKey<Dimension>: BiomeSearchTree] = [:]
    private var compiledSearchTrees: [RegistryKey<Dimension>: CompiledBiomeSearchTree] = [:]
    private var endBiomeDimensions = Set<RegistryKey<Dimension>>()
    private var directPointSamplingDensityFunctions: DirectPointSamplingDensityFunctions?
    private var compiledBiomeDensityFunctions: CompiledBiomeDensityFunctions?
    /// The final-density program used by vanilla terrain generation. Its buffer shape is the
    /// complete generation-cell corner lattice for one chunk, not a scalar sample.
    private var compiledChunkTerrainDensityRegistry: [CompiledDensityFunctionBufferContext: CompiledDensityFunctionBulk] = [:]
    private var finalDensityBulkSamplers: [WeakCompiledDensityFunctionBulk] = []
    private var climateBiomeBulkSamplers: [WeakCompiledClimateBiomeBulkSampler] = []
    private var biomeIDBulkSamplers: [WeakCompiledNoiseRouterBiomeBulkSampler] = []
    // Terrain generation walks a shared baked density-function graph composed of reference types.
    // Serializing `generateInto` prevents concurrent cache mutation inside that shared graph.
    private let terrainGenerationLock = NSLock()

    /// Initialise this world generator.
    /// Datapack setup and compiled graphs are retained separately from seed-dependent sampler state.
    /// Use ``setWorldSeed(_:)`` to update that shared state without rebuilding either one.
    /// - Parameters:
    ///   - seed: The seed of the world to generate.
    ///   - datapacks: The datapacks to generate. Entries from later elements in this array will override earlier ones.
    ///   - configKey: A registry key pointing to the noise settings to use for generation. While this can be omitted, it should not be except for debugging purposes.
    ///   - buildSearchTrees: Whether to build biome search trees.
    ///   - compilationBackend: Optionally compiles biome climate functions and search trees with this backend.
    ///   - useBiomeSearchAlternative: Reuses the previous winning leaf when searching each compiled biome tree.
    ///   - wasmRuntime: The host WebAssembly engine bridge used when `compilationBackend` is `.wasm`.
    /// It is recommended (though not required) to place the vanilla datapack at the end of this array.
    public init(
        withWorldSeed seed: WorldSeed,
        usingDataPacks datapacks: [DataPack],
        usingSettings configKey: RegistryKey<NoiseSettings>? = nil,
        buildSearchTrees: Bool = true,
        compilationBackend: CompilationBackend? = nil,
        useBiomeSearchAlternative: Bool = false,
        wasmRuntime: (any WASMRuntime)? = nil
    ) throws {
        self.worldSeed = seed
        self.voronoiSHA = VoronoiBiomeSubsampler.makeVoronoiSHA(seed)
        self.configuredSettingsKeyName = configKey?.name
        self.compilationBackend = compilationBackend
        self.useBiomeSearchAlternative = useBiomeSearchAlternative
        self.wasmRuntime = wasmRuntime
        try self.initialiseDataPacks(datapacks, usingSettings: configKey, buildSearchTrees: buildSearchTrees)
        try self.setWorldSeed(seed)
    }

    /// Rebuilds seed-dependent noises and density functions. Compiled graphs and biome search
    /// trees are retained; their shared seed storage is updated in place.
    public func setWorldSeed(_ seed: WorldSeed) throws {
        self.terrainGenerationLock.lock()
        defer { self.terrainGenerationLock.unlock() }

        self.worldSeed = seed
        self.voronoiSHA = VoronoiBiomeSubsampler.makeVoronoiSHA(seed)
        self.registries.densityFunctionRegistry = Registry()
        self.registries.bakedNoiseRegistry = Registry()
        self.directPointSamplingDensityFunctions = nil
        if !self.hasInitialisedCompiledSeedState {
            self.registries.compiledDensityFunctionRegistry = nil
            self.compiledBiomeDensityFunctions = nil
            self.compiledChunkTerrainDensityRegistry = [:]
            self.compiledSearchTrees = [:]
        }
        self.config = self.unbakedConfig

        for datapack in self.datapacks {
            self.registries.densityFunctionRegistry.mergeDown(with: datapack.densityFunctionRegistry)
        }

        var random = XoroshiroRandom(seed: seed)
        let low = random.nextLong()
        let high = random.nextLong()
        for datapack in self.datapacks {
            datapack.noiseRegistry.forEach { key, value in
                let noise = value.instantiate(seedLo: low, seedHi: high)
                self.registries.bakedNoiseRegistry.register(noise, forKey: key.convertType())
            }
        }

        try self.bakeDensityFunctions()
        if !self.hasInitialisedCompiledSeedState {
            try self.populateCompiledDensityFunctionRegistry()
            try self.compileConfiguredFunctions()
            self.hasInitialisedCompiledSeedState = true
        }
    }

    /// Labelled spelling retained for callers that prefer an explicit seed argument.
    public func setWorldSeed(newSeed seed: WorldSeed) throws {
        try self.setWorldSeed(seed)
    }

    private func initialiseDataPacks(
        _ datapacks: [DataPack],
        usingSettings configKey: RegistryKey<NoiseSettings>?,
        buildSearchTrees: Bool
    ) throws {
        self.datapacks = datapacks

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
            self.unbakedConfig = config
            self.config = config
        }

        for datapack in datapacks {
            self.registries.densityFunctionRegistry.mergeDown(with: datapack.densityFunctionRegistry)
            if let compiled = datapack.compiledDensityFunctionRegistry {
                if self.registries.compiledDensityFunctionRegistry == nil {
                    self.registries.compiledDensityFunctionRegistry = Registry()
                }
                self.registries.compiledDensityFunctionRegistry!.mergeDown(with: compiled)
            }
            self.registries.biomeRegistry.mergeDown(with: datapack.biomeRegistry)
            self.registries.dimensionRegistry.mergeDown(with: datapack.dimensionsRegistry)
            self.registries.configuredCarverRegistry.mergeDown(with: datapack.configuredCarverRegistry)
            self.registries.tagRegistry.mergeDown(with: datapack.tagRegistry)
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
            // The built-in climate table is versioned with the vanilla pack.
            // Datapacks are documented to be ordered with vanilla last, so its
            // selected format is the one that controls the predefined entries.
            let vanillaPackFormat = self.datapacks.last?.packFormat ?? .assumedCurrent
            self.searchTrees[RegistryKey(referencing: "minecraft:overworld")] = try buildBiomeSearchTree(
                from: self.registries.biomeRegistry,
                entries: try getPredefinedBiomeSearchTreeData(for: "overworld", packFormat: vanillaPackFormat)!,
                packFormat: vanillaPackFormat
            )
            self.searchTrees[RegistryKey(referencing: "minecraft:nether")] = try buildBiomeSearchTree(
                from: self.registries.biomeRegistry,
                entries: try getPredefinedBiomeSearchTreeData(for: "nether", packFormat: vanillaPackFormat)!,
                packFormat: vanillaPackFormat
            )
            self.endBiomeDimensions.insert(RegistryKey(referencing: "minecraft:end"))
            self.endBiomeDimensions.insert(RegistryKey(referencing: "minecraft:the_end"))

            try self.registries.dimensionRegistry.forEach { (key: RegistryKey<Dimension>, value: Dimension) in
                guard let generator = value.generator as? NoiseDimensionGenerator else {
                    return
                }
                if generator.biomeSource is TheEndBiomeSource {
                    self.endBiomeDimensions.insert(key)
                    return
                }
                guard let biomeSource = generator.biomeSource as? MultiNoiseBiomeSource else {
                    return
                }

                if let preset = biomeSource.preset {
                    guard let canonicalPreset = canonicalPredefinedBiomePreset(preset) else {
                        throw WorldGenerationErrors.invalidMultiNoiseBiomeSourceParameterList(preset)
                    }
                    self.searchTrees[key] = self.searchTrees[RegistryKey(referencing: canonicalPreset)]
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

    private var densityFunctionCompilationStrategy: CompilationBackend? {
        self.compilationBackend ?? self.datapacks.reversed().compactMap(\.densityFunctionCompilationStrategy).first
    }

    private func populateCompiledDensityFunctionRegistry() throws {
        guard let strategy = self.densityFunctionCompilationStrategy else { return }

        let compiled = Registry<CompiledDensityFunction>()
        try self.registries.densityFunctionRegistry.forEach { key, densityFunction in
            compiled.register(
                try compile(
                    densityFunction: densityFunction,
                    strategy: strategy,
                    registry: self.registries.densityFunctionRegistry,
                    runtime: self.wasmRuntime
                ),
                forKey: key.convertType()
            )
        }
        self.registries.compiledDensityFunctionRegistry = compiled
    }

    private func compiledDensityFunction(for densityFunction: any DensityFunction) -> CompiledDensityFunction? {
        guard let compiledRegistry = self.registries.compiledDensityFunctionRegistry else { return nil }
        let identity = ObjectIdentifier(densityFunction as AnyObject)
        for entry in self.registries.densityFunctionRegistry.entries() {
            guard ObjectIdentifier(entry.value as AnyObject) == identity else { continue }
            return compiledRegistry.get(entry.key.convertType())
        }
        return nil
    }

    private func compileConfiguredFunctions() throws {
        if let compilationBackend {
        var compiledSearchTrees: [RegistryKey<Dimension>: CompiledBiomeSearchTree] = [:]
        var compiledSearchTreesByIdentity: [ObjectIdentifier: CompiledBiomeSearchTree] = [:]
        for (key, tree) in self.searchTrees {
            let identity = ObjectIdentifier(tree)
            let compiled: CompiledBiomeSearchTree
            if let existing = compiledSearchTreesByIdentity[identity] {
                compiled = existing
            } else {
                compiled = try tree.compile(
                    strategy: compilationBackend,
                    useAlternativeNode: self.useBiomeSearchAlternative,
                    runtime: self.wasmRuntime
                )
                compiledSearchTreesByIdentity[identity] = compiled
            }
            compiledSearchTrees[key] = compiled
        }
        self.compiledSearchTrees = compiledSearchTrees
        }

        guard let config = self.config else { return }
        let router = config.noiseRouter
        let registry = self.registries.densityFunctionRegistry
        let climateFunctions: [any DensityFunction] = [
            router.temperature,
            router.humidity,
            router.continents,
            router.erosion,
            router.weirdness,
            router.depth
        ]
        if let temperature = self.compiledDensityFunction(for: router.temperature),
           let humidity = self.compiledDensityFunction(for: router.humidity),
           let continentalness = self.compiledDensityFunction(for: router.continents),
           let erosion = self.compiledDensityFunction(for: router.erosion),
           let weirdness = self.compiledDensityFunction(for: router.weirdness),
           let depth = self.compiledDensityFunction(for: router.depth) {
            self.compiledBiomeDensityFunctions = .scalar(
                temperature: temperature,
                humidity: humidity,
                continentalness: continentalness,
                erosion: erosion,
                weirdness: weirdness,
                depth: depth
            )
            return
        }

        guard let densityFunctionCompilationStrategy else { return }
        if densityFunctionCompilationStrategy == .wasm, let wasmRuntime, wasmRuntime.supportsClimateFunctions {
            self.compiledBiomeDensityFunctions = .wasm(try compileWASMClimateFunctions(
                climateFunctions,
                registry: registry,
                runtime: wasmRuntime
            ))
            return
        }
        self.compiledBiomeDensityFunctions = try .scalar(
            temperature: compile(
                densityFunction: router.temperature,
                strategy: densityFunctionCompilationStrategy,
                registry: registry,
                runtime: self.wasmRuntime
            ),
            humidity: compile(
                densityFunction: router.humidity,
                strategy: densityFunctionCompilationStrategy,
                registry: registry,
                runtime: self.wasmRuntime
            ),
            continentalness: compile(
                densityFunction: router.continents,
                strategy: densityFunctionCompilationStrategy,
                registry: registry,
                runtime: self.wasmRuntime
            ),
            erosion: compile(
                densityFunction: router.erosion,
                strategy: densityFunctionCompilationStrategy,
                registry: registry,
                runtime: self.wasmRuntime
            ),
            weirdness: compile(
                densityFunction: router.weirdness,
                strategy: densityFunctionCompilationStrategy,
                registry: registry,
                runtime: self.wasmRuntime
            ),
            depth: compile(
                densityFunction: router.depth,
                strategy: densityFunctionCompilationStrategy,
                registry: registry,
                runtime: self.wasmRuntime
            )
        )
    }

    private func compileFinalDensityBulkSampler(
        for volume: CompiledDensityFunctionBufferContext,
        strategy: CompilationBackend
    ) throws -> CompiledDensityFunctionBulk {
        let functions = try self.validatedDirectPointSamplingDensityFunctions(
            for: "Final density bulk sampling"
        )
        return try compile(
            densityFunction: functions.cacheless.finalDensity,
            bufferContext: volume,
            strategy: strategy,
            registry: self.registries.densityFunctionRegistry,
            runtime: self.wasmRuntime
        )
    }

    private func refreshFinalDensityBulkSamplers() throws {
        var liveSamplers: [CompiledDensityFunctionBulk] = []
        liveSamplers.reserveCapacity(self.finalDensityBulkSamplers.count)
        for reference in self.finalDensityBulkSamplers {
            if let sampler = reference.value {
                liveSamplers.append(sampler)
            }
        }

        var replacements: [(CompiledDensityFunctionBulk, CompiledDensityFunctionBulk)] = []
        replacements.reserveCapacity(liveSamplers.count)
        for sampler in liveSamplers {
            replacements.append((
                sampler,
                try self.compileFinalDensityBulkSampler(
                    for: sampler.bufferContext,
                    strategy: sampler.strategy
                )
            ))
        }
        for (sampler, replacement) in replacements {
            sampler.replaceImplementation(with: replacement)
        }
        self.finalDensityBulkSamplers = liveSamplers.map(WeakCompiledDensityFunctionBulk.init)
    }

    private func compileClimateBiomeBulkSampler(
        for volume: CompiledDensityFunctionBufferContext,
        in dimension: RegistryKey<Dimension>,
        strategy: CompilationBackend
    ) throws -> CompiledClimateBiomeBulkSampler {
        let functions = try self.validatedDirectPointSamplingDensityFunctions(
            for: "Climate-biome bulk sampling"
        ).cacheless.biomeDensityFunctions
        let climateFunctions: [any DensityFunction] = [
            functions.temperature,
            functions.humidity,
            functions.continentalness,
            functions.erosion,
            functions.weirdness,
            functions.depth
        ]
        guard !self.usesTheEndBiomeGetter(for: dimension), let searchTree = self.searchTrees[dimension] else {
            throw WorldGenerationErrors.biomeSearchTreeNotPresent(dimension.name)
        }
        let registry = self.registries.densityFunctionRegistry

        if strategy == .llvm {
            let compiledClimate = try climateFunctions.map { densityFunction in
                try compile(
                    densityFunction: densityFunction,
                    bufferContext: volume,
                    strategy: .llvm,
                    registry: registry
                )
            }
            let compiledSearch = try compile(
                biomeSearchTree: searchTree,
                strategy: .llvm,
                useAlternativeNode: self.useBiomeSearchAlternative
            )
            return CompiledClimateBiomeBulkSampler(
                strategy: .llvm,
                bufferContext: volume,
                dimension: dimension
            ) { basePosition in
                let values = compiledClimate.map { $0(at: basePosition) }
                return (0..<volume.sampleCount).map { index in
                    let point = NoisePoint(
                        temperature: values[0][index],
                        humidity: values[1][index],
                        continentalness: values[2][index],
                        erosion: values[3][index],
                        weirdness: values[4][index],
                        depth: values[5][index]
                    )
                    return ClimateBiomeSample(climate: point, biome: compiledSearch(point))
                }
            }
        }

        let snapshot = searchTree.makeCompilerSnapshot()
        var fallbackFunctions: [Int: any DensityFunction] = [:]
        var wasmClimateFunctions: [any DensityFunction] = []
        wasmClimateFunctions.reserveCapacity(climateFunctions.count)
        for (index, densityFunction) in climateFunctions.enumerated() {
            let scalarProgram = try buildDensityFunctionIR(densityFunction: densityFunction, registry: registry)
            let isSelfContained = scalarProgram.densityFunctions.isEmpty
                && scalarProgram.noises.allSatisfy { $0 is BakedNoise }
            if isSelfContained {
                wasmClimateFunctions.append(densityFunction)
            } else {
                fallbackFunctions[index] = densityFunction
                wasmClimateFunctions.append(ConstantDensityFunction(value: 0))
            }
        }
        let program = try buildClimateBiomeIR(
            densityFunctions: wasmClimateFunctions,
            registry: registry,
            tree: snapshot.tree
        )
        let module = try buildDensityFunctionWASMModule(
            program,
            bulkContext: volume,
            embedSharedSeedStorage: self.wasmRuntime == nil
        )
        let (rawValueCount, rawValueCountOverflow) = volume.sampleCount.multipliedReportingOverflow(
            by: program.outputs.count
        )
        guard !rawValueCountOverflow else {
            throw DensityFunctionCompilationError.badDensityFunction("Climate-biome bulk output size overflowed Int.")
        }
        let invocation: WASMDensityFunctionBulkInvocation?
        if let wasmRuntime = self.wasmRuntime {
            let imports = WASMDensityFunctionImports(
                sampleDensity: { index, x, y, z in
                    precondition(index >= 0 && Int(index) < program.densityFunctions.count)
                    return program.densityFunctions[Int(index)].sample(at: PosInt3D(x: x, y: y, z: z))
                },
                sampleNoise: { index, x, y, z in
                    precondition(index >= 0 && Int(index) < program.noises.count)
                    return program.noises[Int(index)].sample(x: x, y: y, z: z)
                }
            )
            invocation = try wasmRuntime.instantiateDensityFunctionBulk(
                module: module,
                exportName: "sample_bulk",
                memoryExportName: "memory",
                sampleCount: rawValueCount,
                imports: imports
            )
        } else {
            #if os(WASI) || arch(wasm32)
            throw DensityFunctionCompilationError.wasmRuntimeUnavailable
            #else
            invocation = nil
            #endif
        }

        return CompiledClimateBiomeBulkSampler(
            strategy: .wasm,
            wasmModule: module,
            bufferContext: volume,
            dimension: dimension
        ) { basePosition in
            var rawValues = [Double](repeating: 0, count: rawValueCount)
            if let invocation {
                rawValues.withUnsafeMutableBufferPointer { output in
                    invocation(basePosition.x, basePosition.y, basePosition.z, output.baseAddress!)
                }
            }

            var samples: [ClimateBiomeSample] = []
            samples.reserveCapacity(volume.sampleCount)
            var biomePoint = [Int64](repeating: 0, count: 7)
            var sampleIndex = 0
            for zOffset in 0..<volume.zCount {
                for xOffset in 0..<volume.xCount {
                    for yOffset in 0..<volume.yCount {
                        let position = PosInt3D(
                            x: basePosition.x + xOffset * volume.xStep,
                            y: basePosition.y + yOffset * volume.yStep,
                            z: basePosition.z + zOffset * volume.zStep
                        )
                        let rawIndex = sampleIndex * program.outputs.count
                        var temperature: Double
                        var humidity: Double
                        var continentalness: Double
                        var erosion: Double
                        var weirdness: Double
                        var depth: Double
                        if invocation != nil {
                            temperature = rawValues[rawIndex]
                            humidity = rawValues[rawIndex + 1]
                            continentalness = rawValues[rawIndex + 2]
                            erosion = rawValues[rawIndex + 3]
                            weirdness = rawValues[rawIndex + 4]
                            depth = rawValues[rawIndex + 5]
                            for (index, densityFunction) in fallbackFunctions {
                                let value = densityFunction.sample(at: position)
                                switch index {
                                case 0: temperature = value
                                case 1: humidity = value
                                case 2: continentalness = value
                                case 3: erosion = value
                                case 4: weirdness = value
                                case 5: depth = value
                                default: preconditionFailure("Invalid climate function index.")
                                }
                            }
                        } else {
                            temperature = climateFunctions[0].sample(at: position)
                            humidity = climateFunctions[1].sample(at: position)
                            continentalness = climateFunctions[2].sample(at: position)
                            erosion = climateFunctions[3].sample(at: position)
                            weirdness = climateFunctions[4].sample(at: position)
                            depth = climateFunctions[5].sample(at: position)
                        }
                        let point = NoisePoint(
                            temperature: temperature,
                            humidity: humidity,
                            continentalness: continentalness,
                            erosion: erosion,
                            weirdness: weirdness,
                            depth: depth
                        )
                        let biomeIndex: Int32
                        if invocation != nil && fallbackFunctions.isEmpty {
                            biomeIndex = Int32(rawValues[rawIndex + 6])
                        } else {
                            biomePoint[0] = Int64(point.temperature * 10_000)
                            biomePoint[1] = Int64(point.humidity * 10_000)
                            biomePoint[2] = Int64(point.continentalness * 10_000)
                            biomePoint[3] = Int64(point.erosion * 10_000)
                            biomePoint[4] = Int64(point.depth * 10_000)
                            biomePoint[5] = Int64(point.weirdness * 10_000)
                            biomeIndex = snapshot.tree.search(biomePoint)
                        }
                        precondition(biomeIndex >= 0 && Int(biomeIndex) < snapshot.biomes.count)
                        samples.append(ClimateBiomeSample(
                            climate: point,
                            biome: snapshot.biomes[Int(biomeIndex)]
                        ))
                        sampleIndex += 1
                    }
                }
            }
            return samples
        }
    }

    private func refreshClimateBiomeBulkSamplers() throws {
        let liveSamplers = self.climateBiomeBulkSamplers.compactMap(\.value)
        var replacements: [(CompiledClimateBiomeBulkSampler, CompiledClimateBiomeBulkSampler)] = []
        replacements.reserveCapacity(liveSamplers.count)
        for sampler in liveSamplers {
            replacements.append((
                sampler,
                try self.compileClimateBiomeBulkSampler(
                    for: sampler.bufferContext,
                    in: sampler.dimension,
                    strategy: sampler.strategy
                )
            ))
        }
        for (sampler, replacement) in replacements {
            sampler.replaceImplementation(with: replacement)
        }
        self.climateBiomeBulkSamplers = liveSamplers.map(WeakCompiledClimateBiomeBulkSampler.init)
    }

    private func compileBiomeIDBulkSampler(
        for volume: CompiledDensityFunctionBufferContext,
        in dimension: RegistryKey<Dimension>,
        strategy: CompilationBackend
    ) throws -> CompiledNoiseRouterBiomeBulkSampler {
        guard !self.usesTheEndBiomeGetter(for: dimension), let searchTree = self.searchTrees[dimension] else {
            throw WorldGenerationErrors.biomeSearchTreeNotPresent(dimension.name)
        }
        let settings = try self.validatedTerrainConfig(for: "Biome ID bulk sampling")
        return try compile(
            noiseRouter: settings.noiseRouter,
            biomeSearchTree: searchTree,
            bufferContext: volume,
            strategy: strategy,
            useAlternativeNode: self.useBiomeSearchAlternative,
            registry: self.registries.densityFunctionRegistry,
            runtime: self.wasmRuntime
        )
    }

    private func refreshBiomeIDBulkSamplers() throws {
        let liveSamplers = self.biomeIDBulkSamplers.compactMap { reference in
            reference.value.map { ($0, reference.dimension) }
        }
        var replacements: [(CompiledNoiseRouterBiomeBulkSampler, CompiledNoiseRouterBiomeBulkSampler)] = []
        replacements.reserveCapacity(liveSamplers.count)
        for (sampler, dimension) in liveSamplers {
            replacements.append((
                sampler,
                try self.compileBiomeIDBulkSampler(
                    for: sampler.bufferContext,
                    in: dimension,
                    strategy: sampler.strategy
                )
            ))
        }
        for (sampler, replacement) in replacements {
            sampler.replaceImplementation(with: replacement)
        }
        self.biomeIDBulkSamplers = liveSamplers.map {
            WeakCompiledNoiseRouterBiomeBulkSampler($0.0, dimension: $0.1)
        }
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
            registries: self.registries,
            sharedSeededNoises: self.sharedSeededNoises
        )
        try self.registries.densityFunctionRegistry.forEach { (key: RegistryKey<any DensityFunction>, value: any DensityFunction) in
            if baker.hasBeenBaked(atKey: key) { return }
            baker.registries.densityFunctionRegistry.register(try value.bake(withBaker: baker), forKey: key)
        }

        if self.config != nil {
            self.config = self.config!.with(noiseRouter: try self.config!.noiseRouter.bakeAll(withBaker: baker))
            self.directPointSamplingDensityFunctions = try self.makeDirectPointSamplingDensityFunctions(from: self.config!)
        }
    }

    private func usesTheEndBiomeGetter(for dim: RegistryKey<Dimension>) -> Bool {
        return self.endBiomeDimensions.contains(dim)
    }

    private func configuredChunkBiomeSampler() -> ConfiguredBiomeSampler? {
        if let configuredDimensionKey {
            if self.usesTheEndBiomeGetter(for: configuredDimensionKey) {
                return .theEnd
            }
            if let tree = self.searchTrees[configuredDimensionKey] {
                return .searchTree(tree, self.compiledSearchTrees[configuredDimensionKey])
            }
        }
        if let configuredSettingsKeyName {
            let key = RegistryKey<Dimension>(referencing: configuredSettingsKeyName)
            if self.usesTheEndBiomeGetter(for: key) {
                return .theEnd
            }
            if let tree = self.searchTrees[key] {
                return .searchTree(tree, self.compiledSearchTrees[key])
            }
        }
        if let overworld = self.searchTrees[RegistryKey(referencing: "minecraft:overworld")] {
            let key = RegistryKey<Dimension>(referencing: "minecraft:overworld")
            return .searchTree(overworld, self.compiledSearchTrees[key])
        }
        if let nether = self.searchTrees[RegistryKey(referencing: "minecraft:nether")] {
            let key = RegistryKey<Dimension>(referencing: "minecraft:nether")
            return .searchTree(nether, self.compiledSearchTrees[key])
        }
        if !self.endBiomeDimensions.isEmpty {
            return .theEnd
        }
        if let tree = self.searchTrees.first?.value {
            return .searchTree(tree, nil)
        }
        return nil
    }

    @inline(__always)
    private func voronoiAccess3D(_ pos: PosInt3D) -> PosInt3D {
        let x = pos.x &- 2
        let y = pos.y &- 2
        let z = pos.z &- 2
        let pX = x >> 2
        let pY = y >> 2
        let pZ = z >> 2
        let dx = (x & 3) * 10_240
        let dy = (y & 3) * 10_240
        let dz = (z & 3) * 10_240
        var bestX = Int32(0)
        var bestY = Int32(0)
        var bestZ = Int32(0)
        var minDistance = UInt64.max

        for index in 0..<8 {
            let bx = Int32((index & 4) != 0 ? 1 : 0)
            let by = Int32((index & 2) != 0 ? 1 : 0)
            let bz = Int32((index & 1) != 0 ? 1 : 0)
            let cellX = pX &+ bx
            let cellY = pY &+ by
            let cellZ = pZ &+ bz
            let offset = VoronoiBiomeSubsampler.getVoronoiCell(self.voronoiSHA, cellX, cellY, cellZ)

            let rx = Int64(offset.x &+ dx &- 40_960 &* bx)
            let ry = Int64(offset.y &+ dy &- 40_960 &* by)
            let rz = Int64(offset.z &+ dz &- 40_960 &* bz)
            let distance = UInt64(rx &* rx) &+ UInt64(ry &* ry) &+ UInt64(rz &* rz)
            if distance < minDistance {
                minDistance = distance
                bestX = cellX
                bestY = cellY
                bestZ = cellZ
            }
        }

        return PosInt3D(x: bestX, y: bestY, z: bestZ)
    }

    private func validatedTerrainConfig(for operation: String) throws -> NoiseSettings {
        guard let config = self.config else {
            throw WorldGenerationErrors.noiseSettingsNotPresent("\(operation) requires a configured noise settings entry.")
        }
        guard config.height > 0 && config.height % ProtoChunk.sectionHeight == 0 else {
            throw WorldGenerationErrors.invalidProtoChunkHeight(config.height)
        }
        return config
    }

    private func validatedDirectPointSamplingDensityFunctions(
        for operation: String
    ) throws -> DirectPointSamplingDensityFunctions {
        guard let functions = self.directPointSamplingDensityFunctions else {
            throw WorldGenerationErrors.noiseSettingsNotPresent("\(operation) requires a configured noise settings entry.")
        }
        return functions
    }

    private func makeDirectPointSamplingDensityFunctions(
        from config: NoiseSettings
    ) throws -> DirectPointSamplingDensityFunctions {
        return DirectPointSamplingDensityFunctions(
            cached: try self.makeDirectPointSamplingDensityFunctionVariant(
                from: config,
                cacheMode: .preserveWorldScaleCaches
            ),
            cacheless: try self.makeDirectPointSamplingDensityFunctionVariant(
                from: config,
                cacheMode: .stripAllCaches
            )
        )
    }

    private func makeDirectPointSamplingDensityFunctionVariant(
        from config: NoiseSettings,
        cacheMode: DirectPointSamplingCacheMode
    ) throws -> DirectPointSamplingDensityFunctionVariant {
        let sampler = VanillaChunkTerrainSampler(
            chunkPos: PosInt2D(x: 0, z: 0),
            minY: Int32(config.minY),
            height: Int32(config.height),
            sizeHorizontal: config.sizeHorizontal,
            sizeVertical: config.sizeVertical
        )
        let preserveWorldScaleCaches = cacheMode == .preserveWorldScaleCaches
        let noiseRouter: NoiseRouter
        switch cacheMode {
        case .preserveWorldScaleCaches:
            noiseRouter = try config.noiseRouter.bakeAll(withBaker: WorldScaleDensityFunctionBaker())
        case .stripAllCaches:
            noiseRouter = config.noiseRouter
        }

        return DirectPointSamplingDensityFunctionVariant(
            finalDensity: sampler.makeDirectPointSamplingTerrainDensity(
                from: noiseRouter.finalDensity,
                preserveWorldScaleCaches: preserveWorldScaleCaches
            ),
            preliminarySurfaceLevel: noiseRouter.preliminarySurfaceLevel.map {
                sampler.makeDirectPointSamplingFunction(
                    from: $0,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                )
            },
            initialDensityWithoutJaggedness: noiseRouter.initialDensityWithoutJaggedness.map {
                sampler.makeDirectPointSamplingFunction(
                    from: $0,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                )
            },
            biomeDensityFunctions: ChunkBiomeDensityFunctions(
                temperature: sampler.makeDirectPointSamplingFunction(
                    from: noiseRouter.temperature,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                ),
                humidity: sampler.makeDirectPointSamplingFunction(
                    from: noiseRouter.humidity,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                ),
                continentalness: sampler.makeDirectPointSamplingFunction(
                    from: noiseRouter.continents,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                ),
                erosion: sampler.makeDirectPointSamplingFunction(
                    from: noiseRouter.erosion,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                ),
                weirdness: sampler.makeDirectPointSamplingFunction(
                    from: noiseRouter.weirdness,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                ),
                depth: sampler.makeDirectPointSamplingFunction(
                    from: noiseRouter.depth,
                    preserveWorldScaleCaches: preserveWorldScaleCaches
                )
            )
        )
    }

    private func bakeChunkGenerationDensityFunctions(
        from noiseRouter: NoiseRouter,
        with chunkSampler: VanillaChunkTerrainSampler,
        chunkPos: PosInt2D,
        minY: Int32,
        height: Int32,
        sizeHorizontal: Int,
        sizeVertical: Int
    ) throws -> ChunkGenerationDensityFunctions {
        let biomeBaker = ChunkDensityFunctionBaker(
            chunkPos: chunkPos,
            minY: minY,
            height: height,
            sizeHorizontal: sizeHorizontal,
            sizeVertical: sizeVertical
        )
        return ChunkGenerationDensityFunctions(
            terrainDensity: try chunkSampler.bakeDensityFunction(noiseRouter.finalDensity),
            biomeDensityFunctions: ChunkBiomeDensityFunctions(
                temperature: try biomeBaker.bakeDensityFunction(noiseRouter.temperature),
                humidity: try biomeBaker.bakeDensityFunction(noiseRouter.humidity),
                continentalness: try biomeBaker.bakeDensityFunction(noiseRouter.continents),
                erosion: try biomeBaker.bakeDensityFunction(noiseRouter.erosion),
                weirdness: try biomeBaker.bakeDensityFunction(noiseRouter.weirdness),
                depth: try biomeBaker.bakeDensityFunction(noiseRouter.depth)
            )
        )
    }

    private func bakeChunkBiomeDensityFunctions(
        from noiseRouter: NoiseRouter,
        chunkPos: PosInt2D,
        minY: Int32,
        height: Int32,
        sizeHorizontal: Int,
        sizeVertical: Int
    ) throws -> ChunkBiomeDensityFunctions {
        let biomeBaker = ChunkDensityFunctionBaker(
            chunkPos: chunkPos,
            minY: minY,
            height: height,
            sizeHorizontal: sizeHorizontal,
            sizeVertical: sizeVertical
        )
        return ChunkBiomeDensityFunctions(
            temperature: try biomeBaker.bakeDensityFunction(noiseRouter.temperature),
            humidity: try biomeBaker.bakeDensityFunction(noiseRouter.humidity),
            continentalness: try biomeBaker.bakeDensityFunction(noiseRouter.continents),
            erosion: try biomeBaker.bakeDensityFunction(noiseRouter.erosion),
            weirdness: try biomeBaker.bakeDensityFunction(noiseRouter.weirdness),
            depth: try biomeBaker.bakeDensityFunction(noiseRouter.depth)
        )
    }

    private func generateTerrainChunk(
        at chunkPos: PosInt2D,
        using config: NoiseSettings,
        storesBiomeData: Bool = true
    ) throws -> ProtoChunk {
        let chunk = ProtoChunk()
        let minY = Int32(config.minY)
        let height = Int32(config.height)
        try chunk.configure(
            minY: minY,
            height: height,
            defaultTerrainState: config.defaultBlock,
            storesBiomeData: storesBiomeData
        )

        let chunkSampler = VanillaChunkTerrainSampler(
            chunkPos: chunkPos,
            minY: minY,
            height: height,
            sizeHorizontal: config.sizeHorizontal,
            sizeVertical: config.sizeVertical
        )
        let terrainDensity = try chunkSampler.bakeDensityFunction(config.noiseRouter.finalDensity)
        let sampledTerrainDensity = self.compiledTerrainDensityIfPossible(
            fallback: terrainDensity,
            chunkPos: chunkPos,
            minY: minY,
            height: height,
            sizeHorizontal: config.sizeHorizontal,
            sizeVertical: config.sizeVertical
        )
        chunkSampler.generateTerrain(into: chunk, with: sampledTerrainDensity)
        return chunk
    }

    /// Returns the compiled full-chunk corner lattice when the configured backend can express it.
    ///
    /// The registry's scalar programs remain useful for isolated climate samples. Terrain is
    /// different: vanilla evaluates final density over a complete generation-cell lattice before
    /// interpolating blocks, so this path compiles that full chunk-shaped volume and reuses the
    /// resulting program for every generated chunk. Unsupported functions retain the exact
    /// interpreted terrain path.
    private func compiledTerrainDensityIfPossible(
        fallback: any DensityFunction,
        chunkPos: PosInt2D,
        minY: Int32,
        height: Int32,
        sizeHorizontal: Int,
        sizeVertical: Int
    ) -> any DensityFunction {
        guard let strategy = self.densityFunctionCompilationStrategy,
              let context = Self.chunkTerrainCornerBufferContext(
                  height: height,
                  sizeHorizontal: sizeHorizontal,
                  sizeVertical: sizeVertical
              ) else {
            return fallback
        }

        let compiled: CompiledDensityFunctionBulk
        if let existing = self.compiledChunkTerrainDensityRegistry[context],
           existing.strategy == strategy {
            compiled = existing
        } else {
            guard let generated = try? compile(
                densityFunction: try self.validatedDirectPointSamplingDensityFunctions(
                    for: "Compiled chunk terrain generation"
                ).cacheless.finalDensity,
                bufferContext: context,
                strategy: strategy,
                registry: self.registries.densityFunctionRegistry,
                runtime: self.wasmRuntime
            ) else {
                return fallback
            }
            self.compiledChunkTerrainDensityRegistry[context] = generated
            compiled = generated
        }

        return CompiledChunkTerrainDensity(
            fallback: fallback,
            sampler: compiled,
            basePosition: PosInt3D(
                x: chunkPos.x * Int32(ProtoChunk.sideLength),
                y: minY,
                z: chunkPos.z * Int32(ProtoChunk.sideLength)
            )
        )
    }

    private static func chunkTerrainCornerBufferContext(
        height: Int32,
        sizeHorizontal: Int,
        sizeVertical: Int
    ) -> CompiledDensityFunctionBufferContext? {
        let horizontalStep = terrainCellBlockCount(fromNoiseSize: sizeHorizontal)
        let verticalStep = terrainCellBlockCount(fromNoiseSize: sizeVertical)
        guard Int32(ProtoChunk.sideLength) % horizontalStep == 0, height % verticalStep == 0 else {
            return nil
        }
        return CompiledDensityFunctionBufferContext(
            xCount: Int32(ProtoChunk.sideLength) / horizontalStep + 1,
            yCount: height / verticalStep + 1,
            zCount: Int32(ProtoChunk.sideLength) / horizontalStep + 1,
            xStep: horizontalStep,
            yStep: verticalStep,
            zStep: horizontalStep
        )
    }

    private func generateLODBiomeChunk(
        at chunkPos: PosInt2D,
        using config: NoiseSettings,
        with biomeDensityFunctions: ChunkBiomeDensityFunctions
    ) throws -> ProtoChunk {
        let chunk = ProtoChunk()
        let minY = Int32(config.minY)
        let height = Int32(config.height)
        try chunk.configure(minY: minY, height: height, defaultTerrainState: config.defaultBlock)

        if let biomeSampler = self.configuredChunkBiomeSampler() {
            switch biomeSampler {
            case .searchTree(let searchTree, let compiledSearchTree):
                self.generateBiomesIntoChunk(
                    chunk,
                    at: chunkPos,
                    minY: minY,
                    using: searchTree,
                    compiledSearchTree: compiledSearchTree,
                    with: biomeDensityFunctions
                )
            case .theEnd:
                self.generateEndBiomesIntoChunk(
                    chunk,
                    at: chunkPos,
                    minY: minY,
                    with: biomeDensityFunctions
                )
            }
        }
        return chunk
    }

    @inline(__always)
    private func terrainCellSize(fromBaseCellSize baseCellSize: Int32, power: Int) -> Int32 {
        let safePower = max(0, min(30, power))
        return clampToInt32(Int64(baseCellSize) << safePower)
    }

    @inline(__always)
    private func firstAlignedLODCoordinate(
        atOrAbove minimum: Int32,
        relativeTo origin: Int32,
        spacing: Int32
    ) -> Int32 {
        let delta = Int64(minimum) - Int64(origin)
        let quotient = delta >= 0
            ? delta / Int64(spacing)
            : -((-delta + Int64(spacing) - 1) / Int64(spacing))
        let candidate = Int64(origin) + quotient * Int64(spacing)
        return candidate < Int64(minimum) ? clampToInt32(candidate + Int64(spacing)) : clampToInt32(candidate)
    }

    @inline(__always)
    private func lodMidpoint(start: Int32, size: Int32) -> Int32 {
        return clampToInt32(Int64(start) + Int64(size / 2))
    }

    @inline(__always)
    private func lodMaterialID(isSolid: Bool) -> String {
        return isSolid ? "minecraft:stone" : "minecraft:air"
    }

    @inline(__always)
    private func sampleTheEndBiome(
        biomeX: Int32,
        biomeY: Int32,
        biomeZ: Int32,
        erosionAtSectionCenter: Double
    ) -> RegistryKey<Biome> {
        let sectionX = floorDiv(biomeX, by: 4)
        let sectionZ = floorDiv(biomeZ, by: 4)
        let centerDistance = Int64(sectionX) * Int64(sectionX) + Int64(sectionZ) * Int64(sectionZ)
        if centerDistance <= 4096 {
            return hardcodedBiomeKey("minecraft:the_end")
        }

        let hx = sectionX &* 2 &+ 1
        let hz = sectionZ &* 2 &+ 1
        let ringDistanceSquared = Int64(hx) * Int64(hx) + Int64(hz) * Int64(hz)
        if Int32(truncatingIfNeeded: ringDistanceSquared) < 0 {
            return hardcodedBiomeKey("minecraft:end_barrens")
        }

        let _ = biomeY
        if erosionAtSectionCenter > 0.25 {
            return hardcodedBiomeKey("minecraft:end_highlands")
        }
        if erosionAtSectionCenter >= -0.0625 {
            return hardcodedBiomeKey("minecraft:end_midlands")
        }
        if erosionAtSectionCenter >= -0.21875 {
            return hardcodedBiomeKey("minecraft:end_barrens")
        }
        return hardcodedBiomeKey("minecraft:small_end_islands")
    }

    private func generateBiomesIntoChunk(
        _ chunk: ProtoChunk,
        at chunkPos: PosInt2D,
        minY: Int32,
        mode: ChunkBiomeGenerationMode = .quartAndBlock,
        sampledBiomeAt: (Int32, Int32, Int32) -> RegistryKey<Biome>
    ) {
        let chunkStartX = chunkPos.x &* Int32(ProtoChunk.sideLength)
        let chunkStartZ = chunkPos.z &* Int32(ProtoChunk.sideLength)
        let sectionAxisData = self.biomeSubsampler.sectionAxisData(chunkStartX: chunkStartX, chunkStartZ: chunkStartZ)
        let quartBiomeStartX = biomeCoord(fromBlock: chunkStartX)
        let quartBiomeStartY = biomeCoord(fromBlock: minY)
        let quartBiomeStartZ = biomeCoord(fromBlock: chunkStartZ)
        let minSampleBiomeX = biomeCoord(fromBlock: chunkStartX &- 2)
        let maxSampleBiomeX = biomeCoord(fromBlock: chunkStartX &+ Int32(ProtoChunk.sideLength - 1) &- 2) &+ 1
        let minSampleBiomeY = biomeCoord(fromBlock: minY &- 2)
        let maxSampleBiomeY = biomeCoord(fromBlock: minY &+ chunk.height &- 1 &- 2) &+ 1
        let minSampleBiomeZ = biomeCoord(fromBlock: chunkStartZ &- 2)
        let maxSampleBiomeZ = biomeCoord(fromBlock: chunkStartZ &+ Int32(ProtoChunk.sideLength - 1) &- 2) &+ 1
        let sampledBiomeWidth = Int(maxSampleBiomeX - minSampleBiomeX + 1)
        let sampledBiomeHeight = Int(maxSampleBiomeY - minSampleBiomeY + 1)
        let sampledBiomeDepth = Int(maxSampleBiomeZ - minSampleBiomeZ + 1)
        var sampledBiomes = [RegistryKey<Biome>?](repeating: nil, count: sampledBiomeWidth * sampledBiomeHeight * sampledBiomeDepth)

        @inline(__always)
        func sampledBiomeIndex(x: Int32, y: Int32, z: Int32) -> Int {
            let x = Int(x - minSampleBiomeX)
            let y = Int(y - minSampleBiomeY)
            let z = Int(z - minSampleBiomeZ)
            return (y * sampledBiomeDepth + z) * sampledBiomeWidth + x
        }

        @inline(__always)
        func cachedBiome(x: Int32, y: Int32, z: Int32) -> RegistryKey<Biome> {
            let sampledIndex = sampledBiomeIndex(x: x, y: y, z: z)
            if let cached = sampledBiomes[sampledIndex] {
                return cached
            }

            let biome = sampledBiomeAt(x, y, z)
            sampledBiomes[sampledIndex] = biome
            return biome
        }

        @inline(__always)
        func cachedBiomeFast(x: Int32, y: Int32, z: Int32) -> RegistryKey<Biome> {
            let sampledIndex = sampledBiomeIndex(x: x, y: y, z: z)
            if let cached = sampledBiomes[sampledIndex] {
                return cached
            }

            let biome = sampledBiomeAt(x, y, z)
            sampledBiomes[sampledIndex] = biome
            return biome
        }

        @inline(__always)
        func sampledSectionBiomesFast(for latticeMap: SectionBiomeLatticeMap) -> [RegistryKey<Biome>] {
            if latticeMap.uniquePositions.isEmpty {
                return []
            }
            return Array(unsafeUninitializedCapacity: latticeMap.uniquePositions.count) { buffer, initializedCount in
                let base = buffer.baseAddress!
                for uniqueIndex in latticeMap.samplingOrder {
                    let index = Int(uniqueIndex)
                    let latticePos = latticeMap.uniquePositions[index]
                    base.advanced(by: index).initialize(
                        to: cachedBiomeFast(x: latticePos.x, y: latticePos.y, z: latticePos.z)
                    )
                }
                initializedCount = latticeMap.uniquePositions.count
            }
        }

        if mode != .blockOnly {
            for sectionIndex in 0..<chunk.sectionCount {
                let section = chunk.sectionUnchecked(at: sectionIndex)
                let sectionBiomeStartY = quartBiomeStartY &+ Int32(sectionIndex * ProtoChunkSection.biomeSideLength)
                for localBiomeY in 0..<ProtoChunkSection.biomeSideLength {
                    let biomeY = sectionBiomeStartY &+ Int32(localBiomeY)
                    let sectionBiomeY = localBiomeY << 4
                    for localBiomeZ in 0..<ProtoChunk.biomeSideLength {
                        let biomeZ = quartBiomeStartZ &+ Int32(localBiomeZ)
                        let sectionBiomeZ = localBiomeZ << 2
                        for localBiomeX in 0..<ProtoChunk.biomeSideLength {
                            let biomeX = quartBiomeStartX &+ Int32(localBiomeX)
                            let sectionBiomeIndex = sectionBiomeY | sectionBiomeZ | localBiomeX
                            let biome = cachedBiomeFast(x: biomeX, y: biomeY, z: biomeZ)
                            section.setBiomeUnchecked(biome, biomeIndex: sectionBiomeIndex)
                        }
                    }
                }
            }
        }

        if mode != .quartOnly {
            for sectionIndex in 0..<chunk.sectionCount {
                let section = chunk.sectionUnchecked(at: sectionIndex)
                let sectionStartY = minY + Int32(sectionIndex * ProtoChunk.sectionHeight)
                let latticeMap = self.biomeSubsampler.sectionBiomeLatticeMap(
                    axisData: sectionAxisData,
                    sectionStartY: sectionStartY,
                    voronoiSHA: self.voronoiSHA
                )
                let sectionBiomes = sampledSectionBiomesFast(for: latticeMap)
                section.setBiomesUnchecked(sectionBiomes, using: latticeMap.blockToUniqueIndex)
            }
        }
    }

    private func generateBiomesIntoChunk(
        _ chunk: ProtoChunk,
        at chunkPos: PosInt2D,
        minY: Int32,
        using searchTree: BiomeSearchTree,
        compiledSearchTree: CompiledBiomeSearchTree? = nil,
        with functions: ChunkBiomeDensityFunctions,
        mode: ChunkBiomeGenerationMode = .quartAndBlock
    ) {
        let lookupState = searchTree.makeReusableLookupState()
        self.generateBiomesIntoChunk(chunk, at: chunkPos, minY: minY, mode: mode) { biomeX, biomeY, biomeZ in
            let pos = PosInt3D(
                x: blockCoord(fromBiome: biomeX),
                y: blockCoord(fromBiome: biomeY),
                z: blockCoord(fromBiome: biomeZ)
            )
            let temperature = functions.temperature.sample(at: pos)
            let humidity = functions.humidity.sample(at: pos)
            let continentalness = functions.continentalness.sample(at: pos)
            let erosion = functions.erosion.sample(at: pos)
            let weirdness = functions.weirdness.sample(at: pos)
            let depth = functions.depth.sample(at: pos)
            if let compiledSearchTree {
                return compiledSearchTree(
                    temperature: temperature,
                    humidity: humidity,
                    continentalness: continentalness,
                    erosion: erosion,
                    weirdness: weirdness,
                    depth: depth
                )
            }
            return searchTree.getUnchecked(
                temperature: temperature,
                humidity: humidity,
                continentalness: continentalness,
                erosion: erosion,
                weirdness: weirdness,
                depth: depth,
                using: lookupState
            )
        }
    }

    #if DEBUG && !(os(WASI) || arch(wasm32))
    private func generateBiomesIntoChunk(
        _ chunk: ProtoChunk,
        at chunkPos: PosInt2D,
        minY: Int32,
        using searchTree: BiomeSearchTree,
        with functions: ChunkBiomeDensityFunctions,
        mode: ChunkBiomeGenerationMode = .quartAndBlock,
        searchTreeProfile: MutableTimedComponentBenchmark
    ) {
        let lookupState = searchTree.makeReusableLookupState()
        self.generateBiomesIntoChunk(chunk, at: chunkPos, minY: minY, mode: mode) { biomeX, biomeY, biomeZ in
            let pos = PosInt3D(
                x: blockCoord(fromBiome: biomeX),
                y: blockCoord(fromBiome: biomeY),
                z: blockCoord(fromBiome: biomeZ)
            )
            let temperature = functions.temperature.sample(at: pos)
            let humidity = functions.humidity.sample(at: pos)
            let continentalness = functions.continentalness.sample(at: pos)
            let erosion = functions.erosion.sample(at: pos)
            let weirdness = functions.weirdness.sample(at: pos)
            let depth = functions.depth.sample(at: pos)
            return searchTreeProfile.record {
                searchTree.getUnchecked(
                    temperature: temperature,
                    humidity: humidity,
                    continentalness: continentalness,
                    erosion: erosion,
                    weirdness: weirdness,
                    depth: depth,
                    using: lookupState
                )
            }
        }
    }
    #endif

    private func generateEndBiomesIntoChunk(
        _ chunk: ProtoChunk,
        at chunkPos: PosInt2D,
        minY: Int32,
        with functions: ChunkBiomeDensityFunctions,
        mode: ChunkBiomeGenerationMode = .quartAndBlock
    ) {
        self.generateBiomesIntoChunk(chunk, at: chunkPos, minY: minY, mode: mode) { biomeX, biomeY, biomeZ in
            let sectionX = floorDiv(biomeX, by: 4)
            let sectionZ = floorDiv(biomeZ, by: 4)
            let erosionSamplePos = PosInt3D(
                x: (sectionX &* 2 &+ 1) &* 8,
                y: blockCoord(fromBiome: biomeY),
                z: (sectionZ &* 2 &+ 1) &* 8
            )
            return self.sampleTheEndBiome(
                biomeX: biomeX,
                biomeY: biomeY,
                biomeZ: biomeZ,
                erosionAtSectionCenter: functions.erosion.sample(at: erosionSamplePos)
            )
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
        if let compiled = self.compiledBiomeDensityFunctions {
            return compiled.sample(at: pos)
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

    @inline(__always)
    private func sampleTheEndBiome(at pos: PosInt3D) -> RegistryKey<Biome> {
        guard let config = self.config else {
            assertionFailure("WorldGenerator.sampleTheEndBiome(at:) called without configured noise settings")
            return hardcodedBiomeKey("minecraft:the_end")
        }
        let biomeX = biomeCoord(fromBlock: pos.x)
        let biomeY = biomeCoord(fromBlock: pos.y)
        let biomeZ = biomeCoord(fromBlock: pos.z)
        let sectionX = floorDiv(biomeX, by: 4)
        let sectionZ = floorDiv(biomeZ, by: 4)
        return self.sampleTheEndBiome(
            biomeX: biomeX,
            biomeY: biomeY,
            biomeZ: biomeZ,
            erosionAtSectionCenter: config.noiseRouter.erosion.sample(
                at: PosInt3D(
                    x: (sectionX &* 2 &+ 1) &* 8,
                    y: blockCoord(fromBiome: biomeY),
                    z: (sectionZ &* 2 &+ 1) &* 8
                )
            )
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
        if self.usesTheEndBiomeGetter(for: dim) {
            return self.sampleTheEndBiome(at: pos)
        }
        let point = self.sampleNoisePoint(at: pos)
        guard let searchTree = self.searchTrees[dim] else {
            assertionFailure("WorldGenerator.sampleBiome(at:in:) called without a search tree for \(dim.name)")
            return nil
        }
        if let compiled = self.compiledSearchTrees[dim] {
            return compiled(point)
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
        let biomePos = self.voronoiAccess3D(pos)
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
    ///   - forceBaking: Whether to force the function to bake the caches, irrespective of generation size.
    /// - Throws: Any errors thrown by biome sampling or cache generation (if applied), or if `to` is less than `from`.
    /// - Returns: An X-major array of biomes (indexed by [Z*(to.x-from.x)+X]).
    public func generateBiomesInSquare(
        from fromPos: PosInt2D,
        to toPos: PosInt2D,
        atY y: Int32,
        in dim: RegistryKey<Dimension>,
        scale: Int32 = 4,
        forceNoBaking: Bool = false,
        forceBaking: Bool = false
    ) throws -> [RegistryKey<Biome>]? {
        if scale <= 0 {
            throw WorldGenerationErrors.invalidScale
        }
        if fromPos.x >= toPos.x || fromPos.z >= toPos.z {
            throw WorldGenerationErrors.fromPosGreaterThanToPos
        }

        let isTheEnd = self.usesTheEndBiomeGetter(for: dim)
        let searchTree = self.searchTrees[dim]
        let compiledSearchTree = self.compiledSearchTrees[dim]
        if !isTheEnd && searchTree == nil {
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

        @inline(__always)
        func selectBiome(
            temperature: Double,
            humidity: Double,
            continentalness: Double,
            erosion: Double,
            weirdness: Double,
            depth: Double
        ) -> RegistryKey<Biome> {
            if let compiledSearchTree {
                return compiledSearchTree(
                    temperature: temperature,
                    humidity: humidity,
                    continentalness: continentalness,
                    erosion: erosion,
                    weirdness: weirdness,
                    depth: depth
                )
            }
            return searchTree!.getUnchecked(
                temperature: temperature,
                humidity: humidity,
                continentalness: continentalness,
                erosion: erosion,
                weirdness: weirdness,
                depth: depth
            )
        }

        if (!forceBaking && area <= smallAreaThreshold) || self.config == nil || forceNoBaking {
            if useScale {
                let startWorldX = fromX * scale
                var worldZ = fromZ * scale
                for _ in fromZ..<toZ {
                    var worldX = startWorldX
                    for _ in fromX..<toX {
                        let pos = PosInt3D(x: worldX, y: y, z: worldZ)
                        let biome: RegistryKey<Biome>
                        if isTheEnd {
                            biome = self.sampleTheEndBiome(at: pos)
                        } else {
                            let point = self.sampleNoisePoint(at: pos)
                            biome = selectBiome(
                                temperature: point.temperature,
                                humidity: point.humidity,
                                continentalness: point.continentalness,
                                erosion: point.erosion,
                                weirdness: point.weirdness,
                                depth: point.depth
                            )
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
                        if isTheEnd {
                            biome = self.sampleTheEndBiome(at: pos)
                        } else {
                            let point = self.sampleNoisePoint(at: pos)
                            biome = selectBiome(
                                temperature: point.temperature,
                                humidity: point.humidity,
                                continentalness: point.continentalness,
                                erosion: point.erosion,
                                weirdness: point.weirdness,
                                depth: point.depth
                            )
                        }
                        biomes.append(biome)
                    }
                }
                return biomes
            }
        }

        let baker = WorldScaleDensityFunctionBaker()

        let noiseRouter = self.config!.noiseRouter
        let erosion = !isTheEnd ? try baker.bakeDensityFunction(noiseRouter.erosion) : nil
        let temperature = !isTheEnd ? try baker.bakeDensityFunction(noiseRouter.temperature) : nil
        let humidity = !isTheEnd ? try baker.bakeDensityFunction(noiseRouter.humidity) : nil
        let continentalness = !isTheEnd ? try baker.bakeDensityFunction(noiseRouter.continents) : nil
        let weirdness = !isTheEnd ? try baker.bakeDensityFunction(noiseRouter.weirdness) : nil
        let depthFunc = !isTheEnd ? try baker.bakeDensityFunction(noiseRouter.depth) : nil

        if useScale {
            let startWorldX = fromX * scale
            var worldZ = fromZ * scale
            for _ in fromZ..<toZ {
                var worldX = startWorldX
                for _ in fromX..<toX {
                    let pos = PosInt3D(x: worldX, y: y, z: worldZ)
                    let biome: RegistryKey<Biome>
                    if isTheEnd {
                        biome = self.sampleTheEndBiome(at: pos)
                    } else {
                        biome = selectBiome(
                            temperature: temperature!.sample(at: pos),
                            humidity: humidity!.sample(at: pos),
                            continentalness: continentalness!.sample(at: pos),
                            erosion: erosion!.sample(at: pos),
                            weirdness: weirdness!.sample(at: pos),
                            depth: depthFunc!.sample(at: pos)
                        )
                    }
                    biomes.append(biome)
                    worldX += scale
                }
                worldZ += scale
            }
        } else {
            for z in fromPos.z..<toPos.z {
                for x in fromPos.x..<toPos.x {
                    let pos = PosInt3D(x: x, y: y, z: z)
                    let biome: RegistryKey<Biome>
                    if isTheEnd {
                        biome = self.sampleTheEndBiome(at: pos)
                    } else {
                        biome = selectBiome(
                            temperature: temperature!.sample(at: pos),
                            humidity: humidity!.sample(at: pos),
                            continentalness: continentalness!.sample(at: pos),
                            erosion: erosion!.sample(at: pos),
                            weirdness: weirdness!.sample(at: pos),
                            depth: depthFunc!.sample(at: pos)
                        )
                    }
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

        let config = try self.validatedTerrainConfig(for: "Terrain generation")

        let minY = Int32(config.minY)
        let height = Int32(config.height)
        try chunk.configure(minY: minY, height: height, defaultTerrainState: config.defaultBlock)

        let chunkSampler = VanillaChunkTerrainSampler(
            chunkPos: chunkPos,
            minY: minY,
            height: height,
            sizeHorizontal: config.sizeHorizontal,
            sizeVertical: config.sizeVertical
        )

        let chunkGenerationFunctions = try self.bakeChunkGenerationDensityFunctions(
            from: config.noiseRouter,
            with: chunkSampler,
            chunkPos: chunkPos,
            minY: minY,
            height: height,
            sizeHorizontal: config.sizeHorizontal,
            sizeVertical: config.sizeVertical
        )
        if let biomeSampler = self.configuredChunkBiomeSampler() {
            switch biomeSampler {
            case .searchTree(let searchTree, let compiledSearchTree):
                self.generateBiomesIntoChunk(
                    chunk,
                    at: chunkPos,
                    minY: minY,
                    using: searchTree,
                    compiledSearchTree: compiledSearchTree,
                    with: chunkGenerationFunctions.biomeDensityFunctions
                )
            case .theEnd:
                self.generateEndBiomesIntoChunk(
                    chunk,
                    at: chunkPos,
                    minY: minY,
                    with: chunkGenerationFunctions.biomeDensityFunctions
                )
            }
        }

        let aquifer = AquiferSampler(settings: config, chunkPos: chunkPos, worldSeed: self.worldSeed)
        chunk.aquiferSampler = aquifer
        let terrainDensity = self.compiledTerrainDensityIfPossible(
            fallback: chunkGenerationFunctions.terrainDensity,
            chunkPos: chunkPos,
            minY: minY,
            height: height,
            sizeHorizontal: config.sizeHorizontal,
            sizeVertical: config.sizeVertical
        )
        chunkSampler.generateTerrain(
            into: chunk,
            with: terrainDensity,
            aquifer: aquifer
        )
    }

    /// Generates only raw density terrain for structure-start heightmap validation.
    ///
    /// Structure start checks inspect ``ProtoChunk/isTerrain(atLocal:)``, which deliberately
    /// represents final-density occupancy rather than aquifer material or biome data.  Avoid
    /// generating those unused layers when scanning many potential starts.
    func generateTerrainForStructureStartValidation(at chunkPos: PosInt2D) throws -> ProtoChunk {
        self.terrainGenerationLock.lock()
        defer { self.terrainGenerationLock.unlock() }

        let config = try self.validatedTerrainConfig(for: "Structure-start terrain validation")
        return try self.generateTerrainChunk(at: chunkPos, using: config, storesBiomeData: false)
    }

    /// Samples one raw-terrain heightmap column for structure-start validation without allocating
    /// or filling a complete chunk. The sampler still evaluates the exact four generation-cell
    /// corner columns that vanilla interpolation uses for this block column.
    func terrainHeightForStructureStartValidation(atX x: Int32, z: Int32) throws -> Int32 {
        let chunkPos = PosInt2D(x: floorDiv(x, by: 16), z: floorDiv(z, by: 16))
        return try self.terrainHeightSamplerForStructureStartValidation(at: chunkPos).height(
            atX: x,
            z: z
        ) ?? Int32.min
    }

    /// Creates a reusable evaluator so nearby structure footprint checks share the baked density
    /// tree and any generation-cell corner columns used by vanilla interpolation.
    func terrainHeightSamplerForStructureStartValidation(
        at chunkPos: PosInt2D
    ) throws -> StructureStartTerrainChunkSampler {
        self.terrainGenerationLock.lock()
        defer { self.terrainGenerationLock.unlock() }

        let config = try self.validatedTerrainConfig(for: "Structure-start terrain-height validation")
        let minY = Int32(config.minY)
        let height = Int32(config.height)
        let chunkSampler = VanillaChunkTerrainSampler(
            chunkPos: chunkPos,
            minY: minY,
            height: height,
            sizeHorizontal: config.sizeHorizontal,
            sizeVertical: config.sizeVertical
        )
        let terrainDensity = try chunkSampler.bakeDensityFunction(config.noiseRouter.finalDensity)
        let sampledTerrainDensity = self.compiledTerrainDensityIfPossible(
            fallback: terrainDensity,
            chunkPos: chunkPos,
            minY: minY,
            height: height,
            sizeHorizontal: config.sizeHorizontal,
            sizeVertical: config.sizeVertical
        )
        return StructureStartTerrainChunkSampler(
            sampler: chunkSampler,
            density: sampledTerrainDensity
        )
    }

    /// Applies the configured surface rule to a previously generated chunk.
    /// Call this after ``generateInto(_:at:)`` and before ``carve(_:at:)``.
    public func applySurfaceRules(to chunk: ProtoChunk, at chunkPos: PosInt2D) throws {
        self.terrainGenerationLock.lock()
        defer { self.terrainGenerationLock.unlock() }
        let config = try self.validatedTerrainConfig(for: "Surface generation")
        guard chunk.minY == Int32(config.minY), chunk.height == Int32(config.height) else {
            throw WorldGenerationErrors.invalidProtoChunkHeight(Int(chunk.height))
        }
        SurfaceRuleApplicator(
            settings: config,
            noises: self.registries.bakedNoiseRegistry,
            biomes: self.registries.biomeRegistry,
            worldSeed: self.worldSeed
        ).apply(to: chunk, at: chunkPos)
    }

    /// Runs configured biome carvers against a previously generated and surfaced chunk.
    /// Carver starts from the vanilla 17x17 source-chunk neighborhood are considered.
    public func carve(_ chunk: ProtoChunk, at chunkPos: PosInt2D) throws {
        self.terrainGenerationLock.lock()
        defer { self.terrainGenerationLock.unlock() }
        let config = try self.validatedTerrainConfig(for: "Carving")
        guard chunk.minY == Int32(config.minY), chunk.height == Int32(config.height) else {
            throw WorldGenerationErrors.invalidProtoChunkHeight(Int(chunk.height))
        }
        try self.applyCarvers(to: chunk, at: chunkPos)
    }

    private func applyCarvers(to chunk: ProtoChunk, at chunkPos: PosInt2D) throws {
        guard !self.registries.configuredCarverRegistry.entries().isEmpty else { return }
        if chunk.aquiferSampler == nil {
            let config = try self.validatedTerrainConfig(for: "Carving")
            chunk.aquiferSampler = AquiferSampler(settings: config, chunkPos: chunkPos, worldSeed: self.worldSeed)
        }
        let applicator = CarverApplicator { [registries = self.registries] replaceable, blockID in
            Self.carverReplaceable(replaceable, contains: blockID, tags: registries.tagRegistry)
        }
        var mask = CarvingMask(minY: chunk.minY, height: chunk.height)
        for offsetX in -8...8 {
            for offsetZ in -8...8 {
                let source = PosInt2D(x: chunkPos.x + Int32(offsetX), z: chunkPos.z + Int32(offsetZ))
                let biomeKey: RegistryKey<Biome>?
                if let dimension = self.configuredDimensionKey {
                    biomeKey = try self.sampleBiome(
                        at: PosInt3D(x: source.x * 16, y: 0, z: source.z * 16),
                        in: dimension
                    )
                } else {
                    biomeKey = chunk.biome(atLocal: PosInt3D(x: 8, y: min(max(0, -chunk.minY), chunk.height - 1), z: 8))
                }
                guard let biomeKey, let biome = self.registries.biomeRegistry.get(biomeKey) else { continue }
                var configured: [(ConfiguredCarver, Int)] = []
                configured.reserveCapacity(biome.carvers.count)
                for (index, id) in biome.carvers.enumerated() {
                    let key = RegistryKey<ConfiguredCarver>(referencing: addDefaultNamespace(id))
                    if let carver = self.registries.configuredCarverRegistry.get(key) {
                        configured.append((carver, index))
                    }
                }
                applicator.apply(
                    configured,
                    to: chunk,
                    targetChunkPos: chunkPos,
                    sourceChunkPos: source,
                    worldSeed: self.worldSeed,
                    aquifer: chunk.aquiferSampler,
                    mask: &mask
                )
            }
        }
    }

    private static func carverReplaceable(
        _ configured: String,
        contains blockID: String,
        tags: Registry<TagDefinition>
    ) -> Bool {
        if !configured.hasPrefix("#") { return addDefaultNamespace(configured) == addDefaultNamespace(blockID) }
        var visited = Set<String>()
        func matches(tagName: String) -> Bool {
            let normalized = addDefaultNamespace(tagName)
            guard visited.insert(normalized).inserted else { return false }
            let parts = normalized.split(separator: ":", maxSplits: 1).map(String.init)
            let namespacedBlockTag = parts.count == 2 ? "\(parts[0]):block/\(parts[1])" : "minecraft:block/\(normalized)"
            guard let tag = tags.get(RegistryKey<TagDefinition>(referencing: namespacedBlockTag)) else { return false }
            for value in tag.values {
                switch value {
                case .rawID(let id): if addDefaultNamespace(id) == addDefaultNamespace(blockID) { return true }
                case .tagID(let id): if matches(tagName: id) { return true }
                }
            }
            return false
        }
        return matches(tagName: String(configured.dropFirst()))
    }

    #if DEBUG && !(os(WASI) || arch(wasm32))
    // Visible for testing/benchmarking only.
    func benchmarkChunkGenerationComponents(at chunkPos: PosInt2D) throws -> ChunkGenerationComponentBenchmark {
        self.terrainGenerationLock.lock()
        defer { self.terrainGenerationLock.unlock() }

        let config = try self.validatedTerrainConfig(for: "Terrain generation benchmarking")
        let minY = Int32(config.minY)
        let height = Int32(config.height)
        let biomeSampler = self.configuredChunkBiomeSampler()

        func makeContext() throws -> (ProtoChunk, VanillaChunkTerrainSampler, ChunkGenerationDensityFunctions, UInt64, UInt64, UInt64) {
            let chunk = ProtoChunk()
            let configureStart = DispatchTime.now().uptimeNanoseconds
            try chunk.configure(minY: minY, height: height, defaultTerrainState: config.defaultBlock)
            let configureEnd = DispatchTime.now().uptimeNanoseconds

            let samplerInitStart = DispatchTime.now().uptimeNanoseconds
            let chunkSampler = VanillaChunkTerrainSampler(
                chunkPos: chunkPos,
                minY: minY,
                height: height,
                sizeHorizontal: config.sizeHorizontal,
                sizeVertical: config.sizeVertical
            )
            let samplerInitEnd = DispatchTime.now().uptimeNanoseconds

            let bakeStart = DispatchTime.now().uptimeNanoseconds
            let densityFunctions = try self.bakeChunkGenerationDensityFunctions(
                from: config.noiseRouter,
                with: chunkSampler,
                chunkPos: chunkPos,
                minY: minY,
                height: height,
                sizeHorizontal: config.sizeHorizontal,
                sizeVertical: config.sizeVertical
            )
            let bakeEnd = DispatchTime.now().uptimeNanoseconds

            return (
                chunk,
                chunkSampler,
                densityFunctions,
                configureEnd - configureStart,
                samplerInitEnd - samplerInitStart,
                bakeEnd - bakeStart
            )
        }

        let (_, _, _, configureNanos, samplerInitNanos, sharedBakeNanos) = try makeContext()

        let (terrainChunk, terrainSampler, terrainFunctions, _, _, _) = try makeContext()
        let terrainStart = DispatchTime.now().uptimeNanoseconds
        terrainSampler.generateTerrain(into: terrainChunk, with: terrainFunctions.terrainDensity)
        let terrainOnlyNanos = DispatchTime.now().uptimeNanoseconds - terrainStart

        var quartBiomesOnlyNanos: UInt64 = 0
        var blockBiomesOnlyNanos: UInt64 = 0
        if let biomeSampler {
            let (quartChunk, _, quartFunctions, _, _, _) = try makeContext()
            let quartStart = DispatchTime.now().uptimeNanoseconds
            switch biomeSampler {
            case .searchTree(let searchTree, _):
                self.generateBiomesIntoChunk(
                    quartChunk,
                    at: chunkPos,
                    minY: minY,
                    using: searchTree,
                    with: quartFunctions.biomeDensityFunctions,
                    mode: .quartOnly
                )
            case .theEnd:
                self.generateEndBiomesIntoChunk(
                    quartChunk,
                    at: chunkPos,
                    minY: minY,
                    with: quartFunctions.biomeDensityFunctions,
                    mode: .quartOnly
                )
            }
            quartBiomesOnlyNanos = DispatchTime.now().uptimeNanoseconds - quartStart

            let (blockChunk, _, blockFunctions, _, _, _) = try makeContext()
            let blockStart = DispatchTime.now().uptimeNanoseconds
            switch biomeSampler {
            case .searchTree(let searchTree, _):
                self.generateBiomesIntoChunk(
                    blockChunk,
                    at: chunkPos,
                    minY: minY,
                    using: searchTree,
                    with: blockFunctions.biomeDensityFunctions,
                    mode: .blockOnly
                )
            case .theEnd:
                self.generateEndBiomesIntoChunk(
                    blockChunk,
                    at: chunkPos,
                    minY: minY,
                    with: blockFunctions.biomeDensityFunctions,
                    mode: .blockOnly
                )
            }
            blockBiomesOnlyNanos = DispatchTime.now().uptimeNanoseconds - blockStart
        }

        let (fullChunk, fullSampler, fullFunctions, _, _, _) = try makeContext()
        let fullStart = DispatchTime.now().uptimeNanoseconds
        if let biomeSampler {
            switch biomeSampler {
            case .searchTree(let searchTree, _):
                self.generateBiomesIntoChunk(
                    fullChunk,
                    at: chunkPos,
                    minY: minY,
                    using: searchTree,
                    with: fullFunctions.biomeDensityFunctions
                )
            case .theEnd:
                self.generateEndBiomesIntoChunk(
                    fullChunk,
                    at: chunkPos,
                    minY: minY,
                    with: fullFunctions.biomeDensityFunctions
                )
            }
        }
        fullSampler.generateTerrain(into: fullChunk, with: fullFunctions.terrainDensity)
        let fullGenerateIntoNanos = DispatchTime.now().uptimeNanoseconds - fullStart

        return ChunkGenerationComponentBenchmark(
            configureNanos: configureNanos,
            samplerInitNanos: samplerInitNanos,
            sharedBakeNanos: sharedBakeNanos,
            terrainOnlyNanos: terrainOnlyNanos,
            quartBiomesOnlyNanos: quartBiomesOnlyNanos,
            blockBiomesOnlyNanos: blockBiomesOnlyNanos,
            fullGenerateIntoNanos: fullGenerateIntoNanos
        )
    }

    // Visible for testing/benchmarking only.
    func benchmarkChunkGenerationDetailedProfile(at chunkPos: PosInt2D) throws -> ChunkGenerationDetailedProfileBenchmark {
        self.terrainGenerationLock.lock()
        defer { self.terrainGenerationLock.unlock() }

        let config = try self.validatedTerrainConfig(for: "Detailed terrain generation benchmarking")
        let minY = Int32(config.minY)
        let height = Int32(config.height)
        let biomeSampler = self.configuredChunkBiomeSampler()

        func makeContext() throws -> (ProtoChunk, VanillaChunkTerrainSampler, ChunkGenerationDensityFunctions, UInt64, UInt64, UInt64) {
            let chunk = ProtoChunk()
            let configureStart = DispatchTime.now().uptimeNanoseconds
            try chunk.configure(minY: minY, height: height, defaultTerrainState: config.defaultBlock)
            let configureEnd = DispatchTime.now().uptimeNanoseconds

            let samplerInitStart = DispatchTime.now().uptimeNanoseconds
            let chunkSampler = VanillaChunkTerrainSampler(
                chunkPos: chunkPos,
                minY: minY,
                height: height,
                sizeHorizontal: config.sizeHorizontal,
                sizeVertical: config.sizeVertical
            )
            let samplerInitEnd = DispatchTime.now().uptimeNanoseconds

            let bakeStart = DispatchTime.now().uptimeNanoseconds
            let densityFunctions = try self.bakeChunkGenerationDensityFunctions(
                from: config.noiseRouter,
                with: chunkSampler,
                chunkPos: chunkPos,
                minY: minY,
                height: height,
                sizeHorizontal: config.sizeHorizontal,
                sizeVertical: config.sizeVertical
            )
            let bakeEnd = DispatchTime.now().uptimeNanoseconds

            return (
                chunk,
                chunkSampler,
                densityFunctions,
                configureEnd - configureStart,
                samplerInitEnd - samplerInitStart,
                bakeEnd - bakeStart
            )
        }

        func profiledBiomeFunctions(
            _ functions: ChunkBiomeDensityFunctions,
            using profile: MutableChunkBiomeGenerationDetailedBenchmark
        ) -> ChunkBiomeDensityFunctions {
            return ChunkBiomeDensityFunctions(
                temperature: BenchmarkProfilingDensityFunction(wrapping: functions.temperature, profile: profile.temperature),
                humidity: BenchmarkProfilingDensityFunction(wrapping: functions.humidity, profile: profile.humidity),
                continentalness: BenchmarkProfilingDensityFunction(wrapping: functions.continentalness, profile: profile.continentalness),
                erosion: BenchmarkProfilingDensityFunction(wrapping: functions.erosion, profile: profile.erosion),
                weirdness: BenchmarkProfilingDensityFunction(wrapping: functions.weirdness, profile: profile.weirdness),
                depth: BenchmarkProfilingDensityFunction(wrapping: functions.depth, profile: profile.depth)
            )
        }

        let (_, _, _, configureNanos, samplerInitNanos, sharedBakeNanos) = try makeContext()

        let terrainOnlyProfileState = MutableChunkTerrainGenerationDetailedBenchmark()
        let (terrainChunk, terrainSampler, terrainFunctions, _, _, _) = try makeContext()
        let terrainStart = DispatchTime.now().uptimeNanoseconds
        terrainSampler.generateTerrain(
            into: terrainChunk,
            with: terrainFunctions.terrainDensity,
            profiling: terrainOnlyProfileState.terrainDensity
        )
        let terrainOnlyNanos = DispatchTime.now().uptimeNanoseconds - terrainStart

        var quartBiomesOnlyNanos: UInt64 = 0
        var quartBiomesOnlyProfile: ChunkBiomeGenerationDetailedBenchmark? = nil
        var blockBiomesOnlyNanos: UInt64 = 0
        var blockBiomesOnlyProfile: ChunkBiomeGenerationDetailedBenchmark? = nil
        if let biomeSampler {
            let quartProfileState = MutableChunkBiomeGenerationDetailedBenchmark()
            let (quartChunk, _, quartFunctions, _, _, _) = try makeContext()
            let quartStart = DispatchTime.now().uptimeNanoseconds
            switch biomeSampler {
            case .searchTree(let searchTree, _):
                self.generateBiomesIntoChunk(
                    quartChunk,
                    at: chunkPos,
                    minY: minY,
                    using: searchTree,
                    with: profiledBiomeFunctions(quartFunctions.biomeDensityFunctions, using: quartProfileState),
                    mode: .quartOnly,
                    searchTreeProfile: quartProfileState.searchTree
                )
            case .theEnd:
                self.generateEndBiomesIntoChunk(
                    quartChunk,
                    at: chunkPos,
                    minY: minY,
                    with: profiledBiomeFunctions(quartFunctions.biomeDensityFunctions, using: quartProfileState),
                    mode: .quartOnly
                )
            }
            quartBiomesOnlyNanos = DispatchTime.now().uptimeNanoseconds - quartStart
            quartBiomesOnlyProfile = quartProfileState.snapshot()

            let blockProfileState = MutableChunkBiomeGenerationDetailedBenchmark()
            let (blockChunk, _, blockFunctions, _, _, _) = try makeContext()
            let blockStart = DispatchTime.now().uptimeNanoseconds
            switch biomeSampler {
            case .searchTree(let searchTree, _):
                self.generateBiomesIntoChunk(
                    blockChunk,
                    at: chunkPos,
                    minY: minY,
                    using: searchTree,
                    with: profiledBiomeFunctions(blockFunctions.biomeDensityFunctions, using: blockProfileState),
                    mode: .blockOnly,
                    searchTreeProfile: blockProfileState.searchTree
                )
            case .theEnd:
                self.generateEndBiomesIntoChunk(
                    blockChunk,
                    at: chunkPos,
                    minY: minY,
                    with: profiledBiomeFunctions(blockFunctions.biomeDensityFunctions, using: blockProfileState),
                    mode: .blockOnly
                )
            }
            blockBiomesOnlyNanos = DispatchTime.now().uptimeNanoseconds - blockStart
            blockBiomesOnlyProfile = blockProfileState.snapshot()
        }

        let fullTerrainProfileState = MutableChunkTerrainGenerationDetailedBenchmark()
        var fullBiomeProfile: ChunkBiomeGenerationDetailedBenchmark? = nil
        let (fullChunk, fullSampler, fullFunctions, _, _, _) = try makeContext()
        let fullStart = DispatchTime.now().uptimeNanoseconds
        if let biomeSampler {
            let fullBiomeProfileState = MutableChunkBiomeGenerationDetailedBenchmark()
            switch biomeSampler {
            case .searchTree(let searchTree, _):
                self.generateBiomesIntoChunk(
                    fullChunk,
                    at: chunkPos,
                    minY: minY,
                    using: searchTree,
                    with: profiledBiomeFunctions(fullFunctions.biomeDensityFunctions, using: fullBiomeProfileState),
                    searchTreeProfile: fullBiomeProfileState.searchTree
                )
            case .theEnd:
                self.generateEndBiomesIntoChunk(
                    fullChunk,
                    at: chunkPos,
                    minY: minY,
                    with: profiledBiomeFunctions(fullFunctions.biomeDensityFunctions, using: fullBiomeProfileState)
                )
            }
            fullBiomeProfile = fullBiomeProfileState.snapshot()
        }
        fullSampler.generateTerrain(
            into: fullChunk,
            with: fullFunctions.terrainDensity,
            profiling: fullTerrainProfileState.terrainDensity
        )
        let fullGenerateIntoNanos = DispatchTime.now().uptimeNanoseconds - fullStart

        return ChunkGenerationDetailedProfileBenchmark(
            configureNanos: configureNanos,
            samplerInitNanos: samplerInitNanos,
            sharedBakeNanos: sharedBakeNanos,
            terrainOnlyNanos: terrainOnlyNanos,
            terrainOnlyProfile: terrainOnlyProfileState.snapshot(),
            quartBiomesOnlyNanos: quartBiomesOnlyNanos,
            quartBiomesOnlyProfile: quartBiomesOnlyProfile,
            blockBiomesOnlyNanos: blockBiomesOnlyNanos,
            blockBiomesOnlyProfile: blockBiomesOnlyProfile,
            fullGenerateIntoNanos: fullGenerateIntoNanos,
            fullTerrainProfile: fullTerrainProfileState.snapshot(),
            fullBiomeProfile: fullBiomeProfile
        )
    }
    #endif

    // Currently visible for testing only.
    func sampleFinalDensity(at pos: PosInt3D) throws -> Double {
        return try self.validatedDirectPointSamplingDensityFunctions(
            for: "Final density sampling"
        ).cacheless.finalDensity.sample(at: pos)
    }

    // Currently visible for testing only.
    func cachedFinalDensityFunction() throws -> any DensityFunction {
        return try self.validatedDirectPointSamplingDensityFunctions(
            for: "Cached final density access"
        ).cached.finalDensity
    }

    // Currently visible for testing only. This form intentionally strips the
    // world-scale cache wrappers: compiled backends lower the underlying tree,
    // whereas those wrappers must remain in the Swift evaluator.
    func cachelessFinalDensityFunction() throws -> any DensityFunction {
        return try self.validatedDirectPointSamplingDensityFunctions(
            for: "Cacheless final density access"
        ).cacheless.finalDensity
    }

    // Currently visible for testing only.
    func terrainSettingsForTesting() throws -> NoiseSettings {
        try self.validatedTerrainConfig(for: "Terrain settings access")
    }

    // Currently visible for testing only.
    func densityFunctionRegistryForTesting() -> Registry<DensityFunction> {
        self.registries.densityFunctionRegistry
    }

    // Currently visible for testing only.
    func compiledDensityFunctionRegistryForTesting() -> Registry<CompiledDensityFunction>? {
        self.registries.compiledDensityFunctionRegistry
    }

    /// Returns a compiled sampler for a fixed z/x/y-ordered volume of the configured final density.
    /// The sampler is refreshed when ``setWorldSeed(_:)`` is called, so an existing sampler follows
    /// the generator's current seed. If no strategy is supplied, the generator's configured backend
    /// is used, followed by the platform's native default.
    public func makeFinalDensityBulkSampler(
        for volume: CompiledDensityFunctionBufferContext,
        strategy: CompilationBackend? = nil
    ) throws -> CompiledDensityFunctionBulk {
        self.terrainGenerationLock.lock()
        defer { self.terrainGenerationLock.unlock() }

        let selectedStrategy: CompilationBackend
        if let strategy {
            selectedStrategy = strategy
        } else if let compilationBackend = self.compilationBackend {
            selectedStrategy = compilationBackend
        } else {
            #if canImport(CLLVM)
            selectedStrategy = .llvm
            #else
            selectedStrategy = .wasm
            #endif
        }
        let sampler = try self.compileFinalDensityBulkSampler(
            for: volume,
            strategy: selectedStrategy
        )
        self.finalDensityBulkSamplers.append(WeakCompiledDensityFunctionBulk(sampler))
        return sampler
    }

    /// Returns a compiled sampler for the six climate values and selected biome across a fixed volume.
    /// Results use z/x/y order. The dimension must use a multi-noise biome search tree. As with the
    /// final-density bulk sampler, an existing sampler is refreshed by ``setWorldSeed(_:)``.
    public func makeClimateBiomeBulkSampler(
        for volume: CompiledDensityFunctionBufferContext,
        in dimension: RegistryKey<Dimension>,
        strategy: CompilationBackend? = nil
    ) throws -> CompiledClimateBiomeBulkSampler {
        self.terrainGenerationLock.lock()
        defer { self.terrainGenerationLock.unlock() }

        let selectedStrategy: CompilationBackend
        if let strategy {
            selectedStrategy = strategy
        } else if let compilationBackend = self.compilationBackend {
            selectedStrategy = compilationBackend
        } else {
            #if canImport(CLLVM)
            selectedStrategy = .llvm
            #else
            selectedStrategy = .wasm
            #endif
        }
        let sampler = try self.compileClimateBiomeBulkSampler(
            for: volume,
            in: dimension,
            strategy: selectedStrategy
        )
        self.climateBiomeBulkSamplers.append(WeakCompiledClimateBiomeBulkSampler(sampler))
        return sampler
    }

    /// Returns a fused fixed-volume sampler for this generator's noise router and biome tree.
    /// Results contain z/x/y-ordered integer palette indices and the biome-key palette. A retained
    /// sampler is recompiled in place when ``setWorldSeed(_:)`` changes the generator seed.
    public func makeBiomeIDBulkSampler(
        for volume: CompiledDensityFunctionBufferContext,
        in dimension: RegistryKey<Dimension>,
        strategy: CompilationBackend? = nil
    ) throws -> CompiledNoiseRouterBiomeBulkSampler {
        self.terrainGenerationLock.lock()
        defer { self.terrainGenerationLock.unlock() }

        let selectedStrategy: CompilationBackend
        if let strategy {
            selectedStrategy = strategy
        } else if let compilationBackend = self.compilationBackend {
            selectedStrategy = compilationBackend
        } else {
            #if canImport(CLLVM)
            selectedStrategy = .llvm
            #else
            selectedStrategy = .wasm
            #endif
        }
        let sampler = try self.compileBiomeIDBulkSampler(
            for: volume,
            in: dimension,
            strategy: selectedStrategy
        )
        self.biomeIDBulkSamplers.append(
            WeakCompiledNoiseRouterBiomeBulkSampler(sampler, dimension: dimension)
        )
        return sampler
    }

    /// Samples terrain in an adaptive block-radius around an origin using point samples spaced by generation-cell detail.
    /// Columns inside `startingRadius` are omitted, and each farther ring grows its spacing by powers of two based on
    /// how many `radiusStep` intervals it lies beyond `startingRadius`.
    public func sampleLOD(
        from origin: PosInt3D,
        radius: Int32,
        startingRadius: Int32 = 0,
        radiusStep: Int32 = 1,
        maxCellSizePower: Int = 0,
        threadCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        payloads: TerrainLODPayloadOptions = [.biome],
        progressHandler: (@Sendable (TerrainLODProgress) -> Void)? = nil,
        chunkHandler: (@Sendable (TerrainLODChunk, Int32, Int32) -> Void)? = nil
    ) throws -> TerrainLODResult {
        precondition(radius >= 0, "radius must be non-negative")
        precondition(startingRadius >= 0, "startingRadius must be non-negative")
        precondition(radiusStep > 0, "radiusStep must be positive")
        precondition(maxCellSizePower >= 0, "maxCellSizePower must be non-negative")
        precondition(threadCount > 0, "threadCount must be positive")

        let config = try self.validatedTerrainConfig(for: "LOD sampling")
        let baseCellSize = lodCellBlockCount(fromNoiseSize: config.sizeHorizontal)
        let worldMinY = Int32(config.minY)
        let worldMaxYExclusive = worldMinY + Int32(config.height)

        let requestedMinX = clampToInt32(Int64(origin.x) - Int64(radius))
        let requestedMaxXExclusive = clampToInt32(Int64(origin.x) + Int64(radius) + 1)
        let requestedMinZ = clampToInt32(Int64(origin.z) - Int64(radius))
        let requestedMaxZExclusive = clampToInt32(Int64(origin.z) + Int64(radius) + 1)

        struct ColumnRequest {
            let x: Int32
            let z: Int32
            let cellSize: Int32
            let sampleX: Int32
            let sampleZ: Int32
            let chunkKey: TerrainLODChunkKey
        }

        func chunkKey(forSampleX x: Int32, z: Int32) -> TerrainLODChunkKey {
            return TerrainLODChunkKey(
                x: floorDiv(x, by: Int32(ProtoChunk.sideLength)),
                z: floorDiv(z, by: Int32(ProtoChunk.sideLength))
            )
        }

        func chebyshevDistance(fromX x: Int32, z: Int32) -> Int32 {
            let dx = abs(Int64(x) - Int64(origin.x))
            let dz = abs(Int64(z) - Int64(origin.z))
            return clampToInt32(max(dx, dz))
        }

        var requests: [ColumnRequest] = []
        let effectiveStartingRadius = min(startingRadius, radius + 1)
        var bandIndex = 0
        var bandMin = effectiveStartingRadius
        while bandMin <= radius {
            let nextBandMin = clampToInt32(Int64(effectiveStartingRadius) + Int64(bandIndex + 1) * Int64(radiusStep))
            let bandMaxExclusive = min(radius + 1, nextBandMin)
            let cellSize = self.terrainCellSize(
                fromBaseCellSize: baseCellSize,
                power: min(bandIndex, maxCellSizePower)
            )

            var z = self.firstAlignedLODCoordinate(atOrAbove: requestedMinZ, relativeTo: origin.z, spacing: cellSize)
            while z < requestedMaxZExclusive {
                var x = self.firstAlignedLODCoordinate(atOrAbove: requestedMinX, relativeTo: origin.x, spacing: cellSize)
                while x < requestedMaxXExclusive {
                    let distance = chebyshevDistance(fromX: x, z: z)
                    if distance >= bandMin && distance < bandMaxExclusive {
                        let sampleX = self.lodMidpoint(start: x, size: min(cellSize, requestedMaxXExclusive - x))
                        let sampleZ = self.lodMidpoint(start: z, size: min(cellSize, requestedMaxZExclusive - z))
                        requests.append(
                            ColumnRequest(
                                x: x,
                                z: z,
                                cellSize: cellSize,
                                sampleX: sampleX,
                                sampleZ: sampleZ,
                                chunkKey: chunkKey(forSampleX: sampleX, z: sampleZ)
                            )
                        )
                    }
                    x = clampToInt32(Int64(x) + Int64(cellSize))
                }
                z = clampToInt32(Int64(z) + Int64(cellSize))
            }

            guard bandMaxExclusive > bandMin else {
                break
            }
            bandIndex += 1
            bandMin = bandMaxExclusive
        }

        var requestsByChunk: [TerrainLODChunkKey: [ColumnRequest]] = [:]
        for request in requests {
            requestsByChunk[request.chunkKey, default: []].append(request)
        }
        let sortedChunkKeys = requestsByChunk.keys.sorted { left, right in
            if left.z != right.z {
                return left.z < right.z
            }
            return left.x < right.x
        }

        let chunkPlans: [(TerrainLODChunkKey, [ColumnRequest])] = sortedChunkKeys.map { key in
            let chunkRequests = (requestsByChunk[key] ?? []).sorted { left, right in
                if left.z != right.z {
                    return left.z < right.z
                }
                if left.x != right.x {
                    return left.x < right.x
                }
                return left.cellSize < right.cellSize
            }
            return (key, chunkRequests)
        }

        let includeBiomes = payloads.contains(.biome)
        let includeMaterial = payloads.contains(.material)
        let workerCount = max(1, min(threadCount, max(1, chunkPlans.count)))
        let progressReporter = SharedTerrainLODProgressReporter(
            totalChunkCount: chunkPlans.count,
            totalSampleCount: requests.count,
            handler: progressHandler
        )
        progressReporter.reportInitialProgress()
        final class UnsafeSendableBox<Value>: @unchecked Sendable {
            let value: Value

            init(_ value: Value) {
                self.value = value
            }
        }
        final class SharedSampleLODResults: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var firstError: Error?
            private var generatedChunks: [TerrainLODChunkKey: TerrainLODChunk] = [:]

            func shouldAbort() -> Bool {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.firstError != nil
            }

            func recordError(_ error: Error) {
                self.lock.lock()
                if self.firstError == nil {
                    self.firstError = error
                }
                self.lock.unlock()
            }

            func merge(_ localResults: [TerrainLODChunkKey: TerrainLODChunk]) {
                self.lock.lock()
                for (key, value) in localResults {
                    self.generatedChunks[key] = value
                }
                self.lock.unlock()
            }

            func generatedChunk(for key: TerrainLODChunkKey) -> TerrainLODChunk? {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.generatedChunks[key]
            }
        }
        let generatorBox = UnsafeSendableBox(self)
        let configBox = UnsafeSendableBox(config)
        let sharedResults = SharedSampleLODResults()
        let directPointFunctions = try self.validatedDirectPointSamplingDensityFunctions(for: "LOD sampling")
        let statelessDirectPointFunctionsBox = UnsafeSendableBox(directPointFunctions.cacheless)
        let needsCachedDirectPointFunctions = includeBiomes
        let midpoint: @Sendable (Int32, Int32) -> Int32 = { start, size in
            clampToInt32(Int64(start) + Int64(size / 2))
        }
        let materialIDForSolid: @Sendable (Bool) -> String = { isSolid in
            isSolid ? "minecraft:stone" : "minecraft:air"
        }

        @Sendable func materializedColumn(
            from request: ColumnRequest,
            terrainDensity: any DensityFunction,
            biomeChunk: ProtoChunk?
        ) -> TerrainLODColumn {
            let chunkOriginX = request.chunkKey.x * Int32(ProtoChunk.sideLength)
            let chunkOriginZ = request.chunkKey.z * Int32(ProtoChunk.sideLength)
            let localSampleX = request.sampleX - chunkOriginX
            let localSampleZ = request.sampleZ - chunkOriginZ

            var samples: [Bool] = []
            var samplePayloads: [TerrainLODSamplePayload]? = payloads.isEmpty ? nil : []
            var bandStartY = worldMinY
            while bandStartY < worldMaxYExclusive {
                let bandHeight = min(request.cellSize, worldMaxYExclusive - bandStartY)
                let sampleY = midpoint(bandStartY, bandHeight)
                let samplePos = PosInt3D(
                    x: request.sampleX,
                    y: sampleY,
                    z: request.sampleZ
                )
                let localSamplePos = PosInt3D(
                    x: localSampleX,
                    y: sampleY - worldMinY,
                    z: localSampleZ
                )
                let isSolid = terrainDensity.sample(at: samplePos) > 0.0
                samples.append(isSolid)

                if samplePayloads != nil {
                    samplePayloads!.append(
                        TerrainLODSamplePayload(
                            biome: includeBiomes ? biomeChunk?.biome(atLocal: localSamplePos) : nil,
                            materialID: includeMaterial ? materialIDForSolid(isSolid) : nil
                        )
                    )
                }

                bandStartY = clampToInt32(Int64(bandStartY) + Int64(request.cellSize))
            }

            return TerrainLODColumn(
                x: request.x,
                z: request.z,
                cellSize: request.cellSize,
                samples: samples,
                samplePayloads: samplePayloads
            )
        }

        if workerCount == 1 {
            let cachedDirectPointFunctions = needsCachedDirectPointFunctions ? directPointFunctions.cached : nil
            for (chunkKey, chunkRequests) in chunkPlans {
                let biomeChunk = includeBiomes ? try self.generateLODBiomeChunk(
                    at: PosInt2D(x: chunkKey.x, z: chunkKey.z),
                    using: config,
                    with: cachedDirectPointFunctions?.biomeDensityFunctions ?? statelessDirectPointFunctionsBox.value.biomeDensityFunctions
                ) : nil
                let terrainChunk = TerrainLODChunk(
                    key: chunkKey,
                    columns: chunkRequests.map {
                        materializedColumn(
                            from: $0,
                            terrainDensity: statelessDirectPointFunctionsBox.value.finalDensity,
                            biomeChunk: biomeChunk
                        )
                    }
                )
                chunkHandler?(terrainChunk, worldMinY, worldMaxYExclusive)
                sharedResults.merge([chunkKey: terrainChunk])
                progressReporter.reportCompletedChunk(chunkKey, sampleCount: chunkRequests.count)
            }
        } else {
            performConcurrentIterations(iterations: workerCount) { workerIndex in
                var localResults: [TerrainLODChunkKey: TerrainLODChunk] = [:]
                let cachedDirectPointFunctions: DirectPointSamplingDensityFunctionVariant?
                do {
                    cachedDirectPointFunctions = needsCachedDirectPointFunctions
                        ? try generatorBox.value.makeDirectPointSamplingDensityFunctionVariant(
                            from: configBox.value,
                            cacheMode: .preserveWorldScaleCaches
                        )
                        : nil
                } catch {
                    sharedResults.recordError(error)
                    return
                }
                for planIndex in stride(from: workerIndex, to: chunkPlans.count, by: workerCount) {
                    if sharedResults.shouldAbort() {
                        break
                    }

                    let plan = chunkPlans[planIndex]
                    do {
                        let biomeChunk = includeBiomes ? try generatorBox.value.generateLODBiomeChunk(
                            at: PosInt2D(x: plan.0.x, z: plan.0.z),
                            using: configBox.value,
                            with: cachedDirectPointFunctions?.biomeDensityFunctions
                                ?? statelessDirectPointFunctionsBox.value.biomeDensityFunctions
                        ) : nil
                        let terrainChunk = TerrainLODChunk(
                            key: plan.0,
                            columns: plan.1.map {
                                materializedColumn(
                                    from: $0,
                                    terrainDensity: statelessDirectPointFunctionsBox.value.finalDensity,
                                    biomeChunk: biomeChunk
                                )
                            }
                        )
                        chunkHandler?(terrainChunk, worldMinY, worldMaxYExclusive)
                        localResults[plan.0] = terrainChunk
                        progressReporter.reportCompletedChunk(plan.0, sampleCount: plan.1.count)
                    } catch {
                        sharedResults.recordError(error)
                        break
                    }
                }

                if !localResults.isEmpty {
                    sharedResults.merge(localResults)
                }
            }
        }

        if let firstError = sharedResults.firstError {
            throw firstError
        }

        let chunks = sortedChunkKeys.compactMap { sharedResults.generatedChunk(for: $0) }
        let chunkIndex = Dictionary(
            uniqueKeysWithValues: chunks.enumerated().map { (index, chunk) in
                (chunk.key, index)
            }
        )

        return TerrainLODResult(
            originX: origin.x,
            originY: origin.y,
            originZ: origin.z,
            radius: radius,
            startingRadius: startingRadius,
            radiusStep: radiusStep,
            maxCellSizePower: maxCellSizePower,
            baseCellSize: baseCellSize,
            minX: requestedMinX,
            minY: worldMinY,
            minZ: requestedMinZ,
            maxXExclusive: requestedMaxXExclusive,
            maxYExclusive: worldMaxYExclusive,
            maxZExclusive: requestedMaxZExclusive,
            payloads: payloads,
            chunks: chunks,
            chunkIndex: chunkIndex
        )
    }

    /// Streams terrain LOD chunks in an adaptive block-radius around an origin using point samples spaced by generation-cell detail.
    /// Unlike `sampleLOD`, this method does not retain streamed chunks after invoking `streamer`.
    /// The `streamer` closure is invoked synchronously on the internal sampling threads.
    /// When `threadCount` is greater than 1, calls may happen concurrently and out of chunk order.
    /// The closure does not need to be asynchronous, but it must be thread-safe and should hand work off internally
    /// if it needs asynchronous or blocking downstream processing.
    public func streamLOD(
        from origin: PosInt3D,
        radius: Int32,
        startingRadius: Int32 = 0,
        radiusStep: Int32 = 1,
        maxCellSizePower: Int = 0,
        threadCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        payloads: TerrainLODPayloadOptions = [.biome],
        progressHandler: (@Sendable (TerrainLODProgress) -> Void)? = nil,
        streamer: @escaping @Sendable (TerrainLODChunk, Int32, Int32) -> Void
    ) throws {
        precondition(radius >= 0, "radius must be non-negative")
        precondition(startingRadius >= 0, "startingRadius must be non-negative")
        precondition(radiusStep > 0, "radiusStep must be positive")
        precondition(maxCellSizePower >= 0, "maxCellSizePower must be non-negative")
        precondition(threadCount > 0, "threadCount must be positive")

        let config = try self.validatedTerrainConfig(for: "LOD streaming")
        let baseCellSize = lodCellBlockCount(fromNoiseSize: config.sizeHorizontal)
        let worldMinY = Int32(config.minY)
        let worldMaxYExclusive = worldMinY + Int32(config.height)

        struct ColumnRequest {
            let x: Int32
            let z: Int32
            let cellSize: Int32
            let sampleX: Int32
            let sampleZ: Int32
            let chunkKey: TerrainLODChunkKey
        }

        func chunkKey(forSampleX x: Int32, z: Int32) -> TerrainLODChunkKey {
            return TerrainLODChunkKey(
                x: floorDiv(x, by: Int32(ProtoChunk.sideLength)),
                z: floorDiv(z, by: Int32(ProtoChunk.sideLength))
            )
        }

        func chebyshevDistance(fromX x: Int32, z: Int32) -> Int32 {
            let dx = abs(Int64(x) - Int64(origin.x))
            let dz = abs(Int64(z) - Int64(origin.z))
            return clampToInt32(max(dx, dz))
        }

        let requestedMinX = clampToInt32(Int64(origin.x) - Int64(radius))
        let requestedMaxXExclusive = clampToInt32(Int64(origin.x) + Int64(radius) + 1)
        let requestedMinZ = clampToInt32(Int64(origin.z) - Int64(radius))
        let requestedMaxZExclusive = clampToInt32(Int64(origin.z) + Int64(radius) + 1)

        var requests: [ColumnRequest] = []
        let effectiveStartingRadius = min(startingRadius, radius + 1)
        var bandIndex = 0
        var bandMin = effectiveStartingRadius
        while bandMin <= radius {
            let nextBandMin = clampToInt32(Int64(effectiveStartingRadius) + Int64(bandIndex + 1) * Int64(radiusStep))
            let bandMaxExclusive = min(radius + 1, nextBandMin)
            let cellSize = self.terrainCellSize(
                fromBaseCellSize: baseCellSize,
                power: min(bandIndex, maxCellSizePower)
            )

            var z = self.firstAlignedLODCoordinate(atOrAbove: requestedMinZ, relativeTo: origin.z, spacing: cellSize)
            while z < requestedMaxZExclusive {
                var x = self.firstAlignedLODCoordinate(atOrAbove: requestedMinX, relativeTo: origin.x, spacing: cellSize)
                while x < requestedMaxXExclusive {
                    let distance = chebyshevDistance(fromX: x, z: z)
                    if distance >= bandMin && distance < bandMaxExclusive {
                        let sampleX = self.lodMidpoint(start: x, size: min(cellSize, requestedMaxXExclusive - x))
                        let sampleZ = self.lodMidpoint(start: z, size: min(cellSize, requestedMaxZExclusive - z))
                        requests.append(
                            ColumnRequest(
                                x: x,
                                z: z,
                                cellSize: cellSize,
                                sampleX: sampleX,
                                sampleZ: sampleZ,
                                chunkKey: chunkKey(forSampleX: sampleX, z: sampleZ)
                            )
                        )
                    }
                    x = clampToInt32(Int64(x) + Int64(cellSize))
                }
                z = clampToInt32(Int64(z) + Int64(cellSize))
            }

            guard bandMaxExclusive > bandMin else {
                break
            }
            bandIndex += 1
            bandMin = bandMaxExclusive
        }

        var requestsByChunk: [TerrainLODChunkKey: [ColumnRequest]] = [:]
        for request in requests {
            requestsByChunk[request.chunkKey, default: []].append(request)
        }
        let sortedChunkKeys = requestsByChunk.keys.sorted { left, right in
            if left.z != right.z {
                return left.z < right.z
            }
            return left.x < right.x
        }

        let chunkPlans: [(TerrainLODChunkKey, [ColumnRequest])] = sortedChunkKeys.map { key in
            let chunkRequests = (requestsByChunk[key] ?? []).sorted { left, right in
                if left.z != right.z {
                    return left.z < right.z
                }
                if left.x != right.x {
                    return left.x < right.x
                }
                return left.cellSize < right.cellSize
            }
            return (key, chunkRequests)
        }

        let includeBiomes = payloads.contains(.biome)
        let includeMaterial = payloads.contains(.material)
        let workerCount = max(1, min(threadCount, max(1, chunkPlans.count)))
        let progressReporter = SharedTerrainLODProgressReporter(
            totalChunkCount: chunkPlans.count,
            totalSampleCount: requests.count,
            handler: progressHandler
        )
        progressReporter.reportInitialProgress()

        final class UnsafeSendableBox<Value>: @unchecked Sendable {
            let value: Value

            init(_ value: Value) {
                self.value = value
            }
        }
        final class SharedLODStreamingState: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var firstError: Error?

            func shouldAbort() -> Bool {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.firstError != nil
            }

            func recordError(_ error: Error) {
                self.lock.lock()
                if self.firstError == nil {
                    self.firstError = error
                }
                self.lock.unlock()
            }
        }

        let generatorBox = UnsafeSendableBox(self)
        let configBox = UnsafeSendableBox(config)
        let streamingState = SharedLODStreamingState()
        let directPointFunctions = try self.validatedDirectPointSamplingDensityFunctions(for: "LOD streaming")
        let statelessDirectPointFunctionsBox = UnsafeSendableBox(directPointFunctions.cacheless)
        let needsCachedDirectPointFunctions = includeBiomes
        let midpoint: @Sendable (Int32, Int32) -> Int32 = { start, size in
            clampToInt32(Int64(start) + Int64(size / 2))
        }
        let materialIDForSolid: @Sendable (Bool) -> String = { isSolid in
            isSolid ? "minecraft:stone" : "minecraft:air"
        }

        @Sendable func materializedColumn(
            from request: ColumnRequest,
            terrainDensity: any DensityFunction,
            biomeChunk: ProtoChunk?
        ) -> TerrainLODColumn {
            let chunkOriginX = request.chunkKey.x * Int32(ProtoChunk.sideLength)
            let chunkOriginZ = request.chunkKey.z * Int32(ProtoChunk.sideLength)
            let localSampleX = request.sampleX - chunkOriginX
            let localSampleZ = request.sampleZ - chunkOriginZ

            var samples: [Bool] = []
            var samplePayloads: [TerrainLODSamplePayload]? = payloads.isEmpty ? nil : []
            var bandStartY = worldMinY
            while bandStartY < worldMaxYExclusive {
                let bandHeight = min(request.cellSize, worldMaxYExclusive - bandStartY)
                let sampleY = midpoint(bandStartY, bandHeight)
                let samplePos = PosInt3D(
                    x: request.sampleX,
                    y: sampleY,
                    z: request.sampleZ
                )
                let localSamplePos = PosInt3D(
                    x: localSampleX,
                    y: sampleY - worldMinY,
                    z: localSampleZ
                )
                let isSolid = terrainDensity.sample(at: samplePos) > 0.0
                samples.append(isSolid)

                if samplePayloads != nil {
                    samplePayloads!.append(
                        TerrainLODSamplePayload(
                            biome: includeBiomes ? biomeChunk?.biome(atLocal: localSamplePos) : nil,
                            materialID: includeMaterial ? materialIDForSolid(isSolid) : nil
                        )
                    )
                }

                bandStartY = clampToInt32(Int64(bandStartY) + Int64(request.cellSize))
            }

            return TerrainLODColumn(
                x: request.x,
                z: request.z,
                cellSize: request.cellSize,
                samples: samples,
                samplePayloads: samplePayloads
            )
        }

        if workerCount == 1 {
            let cachedDirectPointFunctions = needsCachedDirectPointFunctions ? directPointFunctions.cached : nil
            for (chunkKey, chunkRequests) in chunkPlans {
                let biomeChunk = includeBiomes ? try self.generateLODBiomeChunk(
                    at: PosInt2D(x: chunkKey.x, z: chunkKey.z),
                    using: config,
                    with: cachedDirectPointFunctions?.biomeDensityFunctions ?? statelessDirectPointFunctionsBox.value.biomeDensityFunctions
                ) : nil
                let terrainChunk = TerrainLODChunk(
                    key: chunkKey,
                    columns: chunkRequests.map {
                        materializedColumn(
                            from: $0,
                            terrainDensity: statelessDirectPointFunctionsBox.value.finalDensity,
                            biomeChunk: biomeChunk
                        )
                    }
                )
                streamer(terrainChunk, worldMinY, worldMaxYExclusive)
                progressReporter.reportCompletedChunk(chunkKey, sampleCount: chunkRequests.count)
            }
        } else {
            performConcurrentIterations(iterations: workerCount) { workerIndex in
                let cachedDirectPointFunctions: DirectPointSamplingDensityFunctionVariant?
                do {
                    cachedDirectPointFunctions = needsCachedDirectPointFunctions
                        ? try generatorBox.value.makeDirectPointSamplingDensityFunctionVariant(
                            from: configBox.value,
                            cacheMode: .preserveWorldScaleCaches
                        )
                        : nil
                } catch {
                    streamingState.recordError(error)
                    return
                }

                for planIndex in stride(from: workerIndex, to: chunkPlans.count, by: workerCount) {
                    if streamingState.shouldAbort() {
                        break
                    }

                    let plan = chunkPlans[planIndex]
                    do {
                        let biomeChunk = includeBiomes ? try generatorBox.value.generateLODBiomeChunk(
                            at: PosInt2D(x: plan.0.x, z: plan.0.z),
                            using: configBox.value,
                            with: cachedDirectPointFunctions?.biomeDensityFunctions
                                ?? statelessDirectPointFunctionsBox.value.biomeDensityFunctions
                        ) : nil
                        let terrainChunk = TerrainLODChunk(
                            key: plan.0,
                            columns: plan.1.map {
                                materializedColumn(
                                    from: $0,
                                    terrainDensity: statelessDirectPointFunctionsBox.value.finalDensity,
                                    biomeChunk: biomeChunk
                                )
                            }
                        )
                        streamer(terrainChunk, worldMinY, worldMaxYExclusive)
                        progressReporter.reportCompletedChunk(plan.0, sampleCount: plan.1.count)
                    } catch {
                        streamingState.recordError(error)
                        break
                    }
                }
            }
        }

        if let firstError = streamingState.firstError {
            throw firstError
        }
    }

    /// Samples terrain surfaces in an adaptive block-radius around an origin.
    /// Cells inside `startingRadius` are sampled at 1:1 block resolution using a full final-density surface scan.
    /// Farther rings reuse the same adaptive spacing as `sampleLOD`, but store one surface height and biome per 2D cell.
    public func sampleSurfaceLOD(
        from origin: PosInt3D,
        radius: Int32,
        startingRadius: Int32 = 0,
        radiusStep: Int32 = 1,
        maxCellSizePower: Int = 0,
        threadCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        progressHandler: (@Sendable (TerrainLODProgress) -> Void)? = nil,
        chunkHandler: (@Sendable (TerrainSurfaceLODChunk, Int32, Int32) -> Void)? = nil
    ) throws -> TerrainSurfaceLODResult {
        precondition(radius >= 0, "radius must be non-negative")
        precondition(startingRadius >= 0, "startingRadius must be non-negative")
        precondition(radiusStep > 0, "radiusStep must be positive")
        precondition(maxCellSizePower >= 0, "maxCellSizePower must be non-negative")
        precondition(threadCount > 0, "threadCount must be positive")

        let config = try self.validatedTerrainConfig(for: "Surface LOD sampling")
        let baseCellSize = lodCellBlockCount(fromNoiseSize: config.sizeHorizontal)
        let worldMinY = Int32(config.minY)
        let worldMaxYExclusive = worldMinY + Int32(config.height)

        let requestedMinX = clampToInt32(Int64(origin.x) - Int64(radius))
        let requestedMaxXExclusive = clampToInt32(Int64(origin.x) + Int64(radius) + 1)
        let requestedMinZ = clampToInt32(Int64(origin.z) - Int64(radius))
        let requestedMaxZExclusive = clampToInt32(Int64(origin.z) + Int64(radius) + 1)

        struct CellRequest {
            let x: Int32
            let z: Int32
            let cellSize: Int32
            let sampleX: Int32
            let sampleZ: Int32
            let chunkKey: TerrainLODChunkKey
        }

        func chunkKey(forSampleX x: Int32, z: Int32) -> TerrainLODChunkKey {
            return TerrainLODChunkKey(
                x: floorDiv(x, by: Int32(ProtoChunk.sideLength)),
                z: floorDiv(z, by: Int32(ProtoChunk.sideLength))
            )
        }

        func chebyshevDistance(fromX x: Int32, z: Int32) -> Int32 {
            let dx = abs(Int64(x) - Int64(origin.x))
            let dz = abs(Int64(z) - Int64(origin.z))
            return clampToInt32(max(dx, dz))
        }

        var requests: [CellRequest] = []
        let effectiveStartingRadius = min(startingRadius, radius + 1)
        if effectiveStartingRadius > 0 {
            var z = requestedMinZ
            while z < requestedMaxZExclusive {
                var x = requestedMinX
                while x < requestedMaxXExclusive {
                    if chebyshevDistance(fromX: x, z: z) < effectiveStartingRadius {
                        requests.append(
                            CellRequest(
                                x: x,
                                z: z,
                                cellSize: 1,
                                sampleX: x,
                                sampleZ: z,
                                chunkKey: chunkKey(forSampleX: x, z: z)
                            )
                        )
                    }
                    x = clampToInt32(Int64(x) + 1)
                }
                z = clampToInt32(Int64(z) + 1)
            }
        }

        var bandIndex = 0
        var bandMin = effectiveStartingRadius
        while bandMin <= radius {
            let nextBandMin = clampToInt32(Int64(effectiveStartingRadius) + Int64(bandIndex + 1) * Int64(radiusStep))
            let bandMaxExclusive = min(radius + 1, nextBandMin)
            let cellSize = self.terrainCellSize(
                fromBaseCellSize: baseCellSize,
                power: min(bandIndex, maxCellSizePower)
            )

            var z = self.firstAlignedLODCoordinate(atOrAbove: requestedMinZ, relativeTo: origin.z, spacing: cellSize)
            while z < requestedMaxZExclusive {
                var x = self.firstAlignedLODCoordinate(atOrAbove: requestedMinX, relativeTo: origin.x, spacing: cellSize)
                while x < requestedMaxXExclusive {
                    let distance = chebyshevDistance(fromX: x, z: z)
                    if distance >= bandMin && distance < bandMaxExclusive {
                        let cellWidth = min(cellSize, requestedMaxXExclusive - x)
                        let cellDepth = min(cellSize, requestedMaxZExclusive - z)
                        requests.append(
                            CellRequest(
                                x: x,
                                z: z,
                                cellSize: cellSize,
                                sampleX: self.lodMidpoint(start: x, size: cellWidth),
                                sampleZ: self.lodMidpoint(start: z, size: cellDepth),
                                chunkKey: chunkKey(
                                    forSampleX: self.lodMidpoint(start: x, size: cellWidth),
                                    z: self.lodMidpoint(start: z, size: cellDepth)
                                )
                            )
                        )
                    }
                    x = clampToInt32(Int64(x) + Int64(cellSize))
                }
                z = clampToInt32(Int64(z) + Int64(cellSize))
            }

            guard bandMaxExclusive > bandMin else {
                break
            }
            bandIndex += 1
            bandMin = bandMaxExclusive
        }

        let needsCoarseSurfaceSampling = requests.contains { $0.cellSize > 1 }
        if needsCoarseSurfaceSampling
            && config.noiseRouter.preliminarySurfaceLevel == nil
            && config.noiseRouter.initialDensityWithoutJaggedness == nil
        {
            throw WorldGenerationErrors.noSurfaceDensityInNoiseRouter
        }

        var requestsByChunk: [TerrainLODChunkKey: [CellRequest]] = [:]
        for request in requests {
            requestsByChunk[request.chunkKey, default: []].append(request)
        }
        let sortedChunkKeys = requestsByChunk.keys.sorted { left, right in
            if left.z != right.z {
                return left.z < right.z
            }
            return left.x < right.x
        }

        let chunkPlans: [(TerrainLODChunkKey, [CellRequest])] = sortedChunkKeys.map { key in
            let chunkRequests = (requestsByChunk[key] ?? []).sorted { left, right in
                if left.z != right.z {
                    return left.z < right.z
                }
                if left.x != right.x {
                    return left.x < right.x
                }
                return left.cellSize < right.cellSize
            }
            return (key, chunkRequests)
        }

        let includeBiomes = self.configuredChunkBiomeSampler() != nil
        let workerCount = max(1, min(threadCount, max(1, chunkPlans.count)))
        let progressReporter = SharedTerrainLODProgressReporter(
            totalChunkCount: chunkPlans.count,
            totalSampleCount: requests.count,
            handler: progressHandler
        )
        progressReporter.reportInitialProgress()
        final class UnsafeSendableBox<Value>: @unchecked Sendable {
            let value: Value

            init(_ value: Value) {
                self.value = value
            }
        }
        final class SharedSampleSurfaceLODResults: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var firstError: Error?
            private var generatedChunks: [TerrainLODChunkKey: TerrainSurfaceLODChunk] = [:]

            func shouldAbort() -> Bool {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.firstError != nil
            }

            func recordError(_ error: Error) {
                self.lock.lock()
                if self.firstError == nil {
                    self.firstError = error
                }
                self.lock.unlock()
            }

            func merge(_ localResults: [TerrainLODChunkKey: TerrainSurfaceLODChunk]) {
                self.lock.lock()
                for (key, value) in localResults {
                    self.generatedChunks[key] = value
                }
                self.lock.unlock()
            }

            func generatedChunk(for key: TerrainLODChunkKey) -> TerrainSurfaceLODChunk? {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.generatedChunks[key]
            }
        }

        let generatorBox = UnsafeSendableBox(self)
        let configBox = UnsafeSendableBox(config)
        let sharedResults = SharedSampleSurfaceLODResults()
        let directPointFunctions = try self.validatedDirectPointSamplingDensityFunctions(for: "Surface LOD sampling")
        let statelessDirectPointFunctionsBox = UnsafeSendableBox(directPointFunctions.cacheless)
        let needsCachedDirectPointFunctions = includeBiomes
        let roundedSurfaceHeight: @Sendable (Double, Int32) -> Int32 = { surfaceLevel, ratio in
            let rounded = Int64((surfaceLevel / Double(ratio)).rounded()) * Int64(ratio)
            let clampedUpperBound = Int64(worldMaxYExclusive) - 1
            return clampToInt32(min(max(Int64(worldMinY), rounded), clampedUpperBound))
        }
        let scannedSurfaceY: @Sendable (any DensityFunction, Int32, Int32, Int32) -> Int32? = { density, x, z, step in
            var y = worldMaxYExclusive - 1
            while y >= worldMinY {
                if density.sample(at: PosInt3D(x: x, y: y, z: z)) > 0.0 {
                    return y
                }

                let nextY = Int64(y) - Int64(step)
                if nextY < Int64(Int32.min) {
                    break
                }
                y = Int32(nextY)
            }
            return nil
        }

        @Sendable func materializedCell(
            from request: CellRequest,
            finalTerrainDensity: any DensityFunction,
            preliminarySurfaceLevel: (any DensityFunction)?,
            initialDensityWithoutJaggedness: (any DensityFunction)?,
            biomeChunk: ProtoChunk?
        ) -> TerrainSurfaceLODCell {
            let surfaceY: Int32?
            if request.cellSize == 1 {
                surfaceY = scannedSurfaceY(finalTerrainDensity, request.sampleX, request.sampleZ, 1)
            } else if let preliminarySurfaceLevel {
                let sampledSurfaceLevel = preliminarySurfaceLevel.sample(
                    at: PosInt3D(x: request.sampleX, y: 0, z: request.sampleZ)
                )
                surfaceY = roundedSurfaceHeight(sampledSurfaceLevel, request.cellSize)
            } else if let initialDensityWithoutJaggedness,
                let approximateSurfaceY = scannedSurfaceY(
                    initialDensityWithoutJaggedness,
                    request.sampleX,
                    request.sampleZ,
                    request.cellSize
                )
            {
                surfaceY = roundedSurfaceHeight(Double(approximateSurfaceY), request.cellSize)
            } else {
                surfaceY = nil
            }

            let surfaceBiome: RegistryKey<Biome>?
            if let biomeChunk, let surfaceY {
                let chunkOriginX = request.chunkKey.x * Int32(ProtoChunk.sideLength)
                let chunkOriginZ = request.chunkKey.z * Int32(ProtoChunk.sideLength)
                surfaceBiome = biomeChunk.biome(
                    atLocal: PosInt3D(
                        x: request.sampleX - chunkOriginX,
                        y: surfaceY - worldMinY,
                        z: request.sampleZ - chunkOriginZ
                    )
                )
            } else {
                surfaceBiome = nil
            }

            return TerrainSurfaceLODCell(
                x: request.x,
                z: request.z,
                cellSize: request.cellSize,
                surfaceY: surfaceY,
                surfaceBiome: surfaceBiome
            )
        }

        if workerCount == 1 {
            let cachedDirectPointFunctions = needsCachedDirectPointFunctions ? directPointFunctions.cached : nil
            for (chunkKey, chunkRequests) in chunkPlans {
                let biomeChunk = includeBiomes ? try self.generateLODBiomeChunk(
                    at: PosInt2D(x: chunkKey.x, z: chunkKey.z),
                    using: config,
                    with: cachedDirectPointFunctions?.biomeDensityFunctions ?? statelessDirectPointFunctionsBox.value.biomeDensityFunctions
                ) : nil
                let terrainChunk = TerrainSurfaceLODChunk(
                    key: chunkKey,
                    cells: chunkRequests.map {
                        materializedCell(
                            from: $0,
                            finalTerrainDensity: statelessDirectPointFunctionsBox.value.finalDensity,
                            preliminarySurfaceLevel: statelessDirectPointFunctionsBox.value.preliminarySurfaceLevel,
                            initialDensityWithoutJaggedness: statelessDirectPointFunctionsBox.value.initialDensityWithoutJaggedness,
                            biomeChunk: biomeChunk
                        )
                    }
                )
                chunkHandler?(terrainChunk, worldMinY, worldMaxYExclusive)
                sharedResults.merge([chunkKey: terrainChunk])
                progressReporter.reportCompletedChunk(chunkKey, sampleCount: chunkRequests.count)
            }
        } else {
            performConcurrentIterations(iterations: workerCount) { workerIndex in
                var localResults: [TerrainLODChunkKey: TerrainSurfaceLODChunk] = [:]
                let cachedDirectPointFunctions: DirectPointSamplingDensityFunctionVariant?
                do {
                    cachedDirectPointFunctions = needsCachedDirectPointFunctions
                        ? try generatorBox.value.makeDirectPointSamplingDensityFunctionVariant(
                            from: configBox.value,
                            cacheMode: .preserveWorldScaleCaches
                        )
                        : nil
                } catch {
                    sharedResults.recordError(error)
                    return
                }
                for planIndex in stride(from: workerIndex, to: chunkPlans.count, by: workerCount) {
                    if sharedResults.shouldAbort() {
                        break
                    }

                    let plan = chunkPlans[planIndex]
                    do {
                        let biomeChunk = includeBiomes ? try generatorBox.value.generateLODBiomeChunk(
                            at: PosInt2D(x: plan.0.x, z: plan.0.z),
                            using: configBox.value,
                            with: cachedDirectPointFunctions?.biomeDensityFunctions
                                ?? statelessDirectPointFunctionsBox.value.biomeDensityFunctions
                        ) : nil
                        let terrainChunk = TerrainSurfaceLODChunk(
                            key: plan.0,
                            cells: plan.1.map {
                                materializedCell(
                                    from: $0,
                                    finalTerrainDensity: statelessDirectPointFunctionsBox.value.finalDensity,
                                    preliminarySurfaceLevel: statelessDirectPointFunctionsBox.value.preliminarySurfaceLevel,
                                    initialDensityWithoutJaggedness: statelessDirectPointFunctionsBox.value.initialDensityWithoutJaggedness,
                                    biomeChunk: biomeChunk
                                )
                            }
                        )
                        chunkHandler?(terrainChunk, worldMinY, worldMaxYExclusive)
                        localResults[plan.0] = terrainChunk
                        progressReporter.reportCompletedChunk(plan.0, sampleCount: plan.1.count)
                    } catch {
                        sharedResults.recordError(error)
                        break
                    }
                }

                if !localResults.isEmpty {
                    sharedResults.merge(localResults)
                }
            }
        }

        if let firstError = sharedResults.firstError {
            throw firstError
        }

        let chunks = sortedChunkKeys.compactMap { sharedResults.generatedChunk(for: $0) }
        let chunkIndex = Dictionary(
            uniqueKeysWithValues: chunks.enumerated().map { (index, chunk) in
                (chunk.key, index)
            }
        )

        return TerrainSurfaceLODResult(
            originX: origin.x,
            originY: origin.y,
            originZ: origin.z,
            radius: radius,
            startingRadius: startingRadius,
            radiusStep: radiusStep,
            maxCellSizePower: maxCellSizePower,
            baseCellSize: baseCellSize,
            minX: requestedMinX,
            minY: worldMinY,
            minZ: requestedMinZ,
            maxXExclusive: requestedMaxXExclusive,
            maxYExclusive: worldMaxYExclusive,
            maxZExclusive: requestedMaxZExclusive,
            chunks: chunks,
            chunkIndex: chunkIndex
        )
    }

    /// Streams terrain surface LOD chunks in an adaptive block-radius around an origin.
    /// Unlike `sampleSurfaceLOD`, this method does not retain streamed chunks after invoking `streamer`.
    /// The `streamer` closure is invoked synchronously on the internal sampling threads.
    /// When `threadCount` is greater than 1, calls may happen concurrently and out of chunk order.
    /// The closure does not need to be asynchronous, but it must be thread-safe and should hand work off internally
    /// if it needs asynchronous or blocking downstream processing.
    public func streamSurfaceLOD(
        from origin: PosInt3D,
        radius: Int32,
        startingRadius: Int32 = 0,
        radiusStep: Int32 = 1,
        maxCellSizePower: Int = 0,
        threadCount: Int = ProcessInfo.processInfo.activeProcessorCount,
        progressHandler: (@Sendable (TerrainLODProgress) -> Void)? = nil,
        streamer: @escaping @Sendable (TerrainSurfaceLODChunk, Int32, Int32) -> Void
    ) throws {
        precondition(radius >= 0, "radius must be non-negative")
        precondition(startingRadius >= 0, "startingRadius must be non-negative")
        precondition(radiusStep > 0, "radiusStep must be positive")
        precondition(maxCellSizePower >= 0, "maxCellSizePower must be non-negative")
        precondition(threadCount > 0, "threadCount must be positive")

        let config = try self.validatedTerrainConfig(for: "Surface LOD streaming")
        let baseCellSize = lodCellBlockCount(fromNoiseSize: config.sizeHorizontal)
        let worldMinY = Int32(config.minY)
        let worldMaxYExclusive = worldMinY + Int32(config.height)

        let requestedMinX = clampToInt32(Int64(origin.x) - Int64(radius))
        let requestedMaxXExclusive = clampToInt32(Int64(origin.x) + Int64(radius) + 1)
        let requestedMinZ = clampToInt32(Int64(origin.z) - Int64(radius))
        let requestedMaxZExclusive = clampToInt32(Int64(origin.z) + Int64(radius) + 1)

        struct CellRequest {
            let x: Int32
            let z: Int32
            let cellSize: Int32
            let sampleX: Int32
            let sampleZ: Int32
            let chunkKey: TerrainLODChunkKey
        }

        func chunkKey(forSampleX x: Int32, z: Int32) -> TerrainLODChunkKey {
            return TerrainLODChunkKey(
                x: floorDiv(x, by: Int32(ProtoChunk.sideLength)),
                z: floorDiv(z, by: Int32(ProtoChunk.sideLength))
            )
        }

        func chebyshevDistance(fromX x: Int32, z: Int32) -> Int32 {
            let dx = abs(Int64(x) - Int64(origin.x))
            let dz = abs(Int64(z) - Int64(origin.z))
            return clampToInt32(max(dx, dz))
        }

        var requests: [CellRequest] = []
        let effectiveStartingRadius = min(startingRadius, radius + 1)
        if effectiveStartingRadius > 0 {
            var z = requestedMinZ
            while z < requestedMaxZExclusive {
                var x = requestedMinX
                while x < requestedMaxXExclusive {
                    if chebyshevDistance(fromX: x, z: z) < effectiveStartingRadius {
                        requests.append(
                            CellRequest(
                                x: x,
                                z: z,
                                cellSize: 1,
                                sampleX: x,
                                sampleZ: z,
                                chunkKey: chunkKey(forSampleX: x, z: z)
                            )
                        )
                    }
                    x = clampToInt32(Int64(x) + 1)
                }
                z = clampToInt32(Int64(z) + 1)
            }
        }

        var bandIndex = 0
        var bandMin = effectiveStartingRadius
        while bandMin <= radius {
            let nextBandMin = clampToInt32(Int64(effectiveStartingRadius) + Int64(bandIndex + 1) * Int64(radiusStep))
            let bandMaxExclusive = min(radius + 1, nextBandMin)
            let cellSize = self.terrainCellSize(
                fromBaseCellSize: baseCellSize,
                power: min(bandIndex, maxCellSizePower)
            )

            var z = self.firstAlignedLODCoordinate(atOrAbove: requestedMinZ, relativeTo: origin.z, spacing: cellSize)
            while z < requestedMaxZExclusive {
                var x = self.firstAlignedLODCoordinate(atOrAbove: requestedMinX, relativeTo: origin.x, spacing: cellSize)
                while x < requestedMaxXExclusive {
                    let distance = chebyshevDistance(fromX: x, z: z)
                    if distance >= bandMin && distance < bandMaxExclusive {
                        let cellWidth = min(cellSize, requestedMaxXExclusive - x)
                        let cellDepth = min(cellSize, requestedMaxZExclusive - z)
                        requests.append(
                            CellRequest(
                                x: x,
                                z: z,
                                cellSize: cellSize,
                                sampleX: self.lodMidpoint(start: x, size: cellWidth),
                                sampleZ: self.lodMidpoint(start: z, size: cellDepth),
                                chunkKey: chunkKey(
                                    forSampleX: self.lodMidpoint(start: x, size: cellWidth),
                                    z: self.lodMidpoint(start: z, size: cellDepth)
                                )
                            )
                        )
                    }
                    x = clampToInt32(Int64(x) + Int64(cellSize))
                }
                z = clampToInt32(Int64(z) + Int64(cellSize))
            }

            guard bandMaxExclusive > bandMin else {
                break
            }
            bandIndex += 1
            bandMin = bandMaxExclusive
        }

        let needsCoarseSurfaceSampling = requests.contains { $0.cellSize > 1 }
        if needsCoarseSurfaceSampling
            && config.noiseRouter.preliminarySurfaceLevel == nil
            && config.noiseRouter.initialDensityWithoutJaggedness == nil
        {
            throw WorldGenerationErrors.noSurfaceDensityInNoiseRouter
        }

        var requestsByChunk: [TerrainLODChunkKey: [CellRequest]] = [:]
        for request in requests {
            requestsByChunk[request.chunkKey, default: []].append(request)
        }
        let sortedChunkKeys = requestsByChunk.keys.sorted { left, right in
            if left.z != right.z {
                return left.z < right.z
            }
            return left.x < right.x
        }

        let chunkPlans: [(TerrainLODChunkKey, [CellRequest])] = sortedChunkKeys.map { key in
            let chunkRequests = (requestsByChunk[key] ?? []).sorted { left, right in
                if left.z != right.z {
                    return left.z < right.z
                }
                if left.x != right.x {
                    return left.x < right.x
                }
                return left.cellSize < right.cellSize
            }
            return (key, chunkRequests)
        }

        let includeBiomes = self.configuredChunkBiomeSampler() != nil
        let workerCount = max(1, min(threadCount, max(1, chunkPlans.count)))
        let progressReporter = SharedTerrainLODProgressReporter(
            totalChunkCount: chunkPlans.count,
            totalSampleCount: requests.count,
            handler: progressHandler
        )
        progressReporter.reportInitialProgress()

        final class UnsafeSendableBox<Value>: @unchecked Sendable {
            let value: Value

            init(_ value: Value) {
                self.value = value
            }
        }
        final class SharedSurfaceLODStreamingState: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var firstError: Error?

            func shouldAbort() -> Bool {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.firstError != nil
            }

            func recordError(_ error: Error) {
                self.lock.lock()
                if self.firstError == nil {
                    self.firstError = error
                }
                self.lock.unlock()
            }
        }

        let generatorBox = UnsafeSendableBox(self)
        let configBox = UnsafeSendableBox(config)
        let streamingState = SharedSurfaceLODStreamingState()
        let directPointFunctions = try self.validatedDirectPointSamplingDensityFunctions(for: "Surface LOD streaming")
        let statelessDirectPointFunctionsBox = UnsafeSendableBox(directPointFunctions.cacheless)
        let needsCachedDirectPointFunctions = includeBiomes
        let roundedSurfaceHeight: @Sendable (Double, Int32) -> Int32 = { surfaceLevel, ratio in
            let rounded = Int64((surfaceLevel / Double(ratio)).rounded()) * Int64(ratio)
            let clampedUpperBound = Int64(worldMaxYExclusive) - 1
            return clampToInt32(min(max(Int64(worldMinY), rounded), clampedUpperBound))
        }
        let scannedSurfaceY: @Sendable (any DensityFunction, Int32, Int32, Int32) -> Int32? = { density, x, z, step in
            var y = worldMaxYExclusive - 1
            while y >= worldMinY {
                if density.sample(at: PosInt3D(x: x, y: y, z: z)) > 0.0 {
                    return y
                }

                let nextY = Int64(y) - Int64(step)
                if nextY < Int64(Int32.min) {
                    break
                }
                y = Int32(nextY)
            }
            return nil
        }

        @Sendable func materializedCell(
            from request: CellRequest,
            finalTerrainDensity: any DensityFunction,
            preliminarySurfaceLevel: (any DensityFunction)?,
            initialDensityWithoutJaggedness: (any DensityFunction)?,
            biomeChunk: ProtoChunk?
        ) -> TerrainSurfaceLODCell {
            let surfaceY: Int32?
            if request.cellSize == 1 {
                surfaceY = scannedSurfaceY(finalTerrainDensity, request.sampleX, request.sampleZ, 1)
            } else if let preliminarySurfaceLevel {
                let sampledSurfaceLevel = preliminarySurfaceLevel.sample(
                    at: PosInt3D(x: request.sampleX, y: 0, z: request.sampleZ)
                )
                surfaceY = roundedSurfaceHeight(sampledSurfaceLevel, request.cellSize)
            } else if let initialDensityWithoutJaggedness,
                let approximateSurfaceY = scannedSurfaceY(
                    initialDensityWithoutJaggedness,
                    request.sampleX,
                    request.sampleZ,
                    request.cellSize
                )
            {
                surfaceY = roundedSurfaceHeight(Double(approximateSurfaceY), request.cellSize)
            } else {
                surfaceY = nil
            }

            let surfaceBiome: RegistryKey<Biome>?
            if let biomeChunk, let surfaceY {
                let chunkOriginX = request.chunkKey.x * Int32(ProtoChunk.sideLength)
                let chunkOriginZ = request.chunkKey.z * Int32(ProtoChunk.sideLength)
                surfaceBiome = biomeChunk.biome(
                    atLocal: PosInt3D(
                        x: request.sampleX - chunkOriginX,
                        y: surfaceY - worldMinY,
                        z: request.sampleZ - chunkOriginZ
                    )
                )
            } else {
                surfaceBiome = nil
            }

            return TerrainSurfaceLODCell(
                x: request.x,
                z: request.z,
                cellSize: request.cellSize,
                surfaceY: surfaceY,
                surfaceBiome: surfaceBiome
            )
        }

        if workerCount == 1 {
            let cachedDirectPointFunctions = needsCachedDirectPointFunctions ? directPointFunctions.cached : nil
            for (chunkKey, chunkRequests) in chunkPlans {
                let biomeChunk = includeBiomes ? try self.generateLODBiomeChunk(
                    at: PosInt2D(x: chunkKey.x, z: chunkKey.z),
                    using: config,
                    with: cachedDirectPointFunctions?.biomeDensityFunctions ?? statelessDirectPointFunctionsBox.value.biomeDensityFunctions
                ) : nil
                let terrainChunk = TerrainSurfaceLODChunk(
                    key: chunkKey,
                    cells: chunkRequests.map {
                        materializedCell(
                            from: $0,
                            finalTerrainDensity: statelessDirectPointFunctionsBox.value.finalDensity,
                            preliminarySurfaceLevel: statelessDirectPointFunctionsBox.value.preliminarySurfaceLevel,
                            initialDensityWithoutJaggedness: statelessDirectPointFunctionsBox.value.initialDensityWithoutJaggedness,
                            biomeChunk: biomeChunk
                        )
                    }
                )
                streamer(terrainChunk, worldMinY, worldMaxYExclusive)
                progressReporter.reportCompletedChunk(chunkKey, sampleCount: chunkRequests.count)
            }
        } else {
            performConcurrentIterations(iterations: workerCount) { workerIndex in
                let cachedDirectPointFunctions: DirectPointSamplingDensityFunctionVariant?
                do {
                    cachedDirectPointFunctions = needsCachedDirectPointFunctions
                        ? try generatorBox.value.makeDirectPointSamplingDensityFunctionVariant(
                            from: configBox.value,
                            cacheMode: .preserveWorldScaleCaches
                        )
                        : nil
                } catch {
                    streamingState.recordError(error)
                    return
                }

                for planIndex in stride(from: workerIndex, to: chunkPlans.count, by: workerCount) {
                    if streamingState.shouldAbort() {
                        break
                    }

                    let plan = chunkPlans[planIndex]
                    do {
                        let biomeChunk = includeBiomes ? try generatorBox.value.generateLODBiomeChunk(
                            at: PosInt2D(x: plan.0.x, z: plan.0.z),
                            using: configBox.value,
                            with: cachedDirectPointFunctions?.biomeDensityFunctions
                                ?? statelessDirectPointFunctionsBox.value.biomeDensityFunctions
                        ) : nil
                        let terrainChunk = TerrainSurfaceLODChunk(
                            key: plan.0,
                            cells: plan.1.map {
                                materializedCell(
                                    from: $0,
                                    finalTerrainDensity: statelessDirectPointFunctionsBox.value.finalDensity,
                                    preliminarySurfaceLevel: statelessDirectPointFunctionsBox.value.preliminarySurfaceLevel,
                                    initialDensityWithoutJaggedness: statelessDirectPointFunctionsBox.value.initialDensityWithoutJaggedness,
                                    biomeChunk: biomeChunk
                                )
                            }
                        )
                        streamer(terrainChunk, worldMinY, worldMaxYExclusive)
                        progressReporter.reportCompletedChunk(plan.0, sampleCount: plan.1.count)
                    } catch {
                        streamingState.recordError(error)
                        break
                    }
                }
            }
        }

        if let firstError = streamingState.firstError {
            throw firstError
        }
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
        return self.voronoiAccess3D(pos)
    }

    // Currently visible for testing only.
    func getDensityFunctionOrThrow(at key: RegistryKey<DensityFunction>) throws -> DensityFunction {
        guard let ret = self.registries.densityFunctionRegistry.get(key) else {
            throw WorldGenerationErrors.densityFunctionNotPresent(key.name)
        }
        return ret
    }

    /// Returns a compiled biome search program for a dimension.
    /// When it matches this generator's configured backend, the program compiled during initialisation is reused.
    public func getCompiledBiomeSearchTree(
        forTarget target: CompilationBackend,
        inDimension dimension: RegistryKey<Dimension>
    ) throws -> CompiledBiomeSearchTree {
        if target == self.compilationBackend, let compiled = self.compiledSearchTrees[dimension] {
            return compiled
        }
        guard let searchTree = self.searchTrees[dimension] else {
            throw WorldGenerationErrors.biomeSearchTreeNotPresent(dimension.name)
        }
        return try compile(
            biomeSearchTree: searchTree,
            strategy: target,
            useAlternativeNode: self.useBiomeSearchAlternative,
            runtime: self.wasmRuntime
        )
    }
}

/// The six climate density values used to select a biome.
public struct NoisePoint: Sendable, Equatable {
    public let temperature: Double
    public let humidity: Double
    public let continentalness: Double
    public let erosion: Double
    public let weirdness: Double
    public let depth: Double

    public init(
        temperature: Double,
        humidity: Double,
        continentalness: Double,
        erosion: Double,
        weirdness: Double,
        depth: Double
    ) {
        self.temperature = temperature
        self.humidity = humidity
        self.continentalness = continentalness
        self.erosion = erosion
        self.weirdness = weirdness
        self.depth = depth
    }
}

enum WorldGenerationErrors: Error {
    case densityFunctionNotPresent(String)
    case noiseNotPresent(String)
    case noiseSettingsNotPresent(String)
    case noBiomesOrPresetsInMultiNoiseBiomeSource(String)
    case invalidMultiNoiseBiomeSourceParameterList(String)
    case noSurfaceDensityInNoiseRouter
    case fromPosGreaterThanToPos
    case invalidScale
    case invalidProtoChunkHeight(Int)
    case biomeSearchTreeNotPresent(String)
}
