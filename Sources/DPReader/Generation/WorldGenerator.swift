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

private enum ConfiguredBiomeSampler {
    case searchTree(BiomeSearchTree)
    case theEnd
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

@inline(__always) private func floorDiv(_ value: Int32, by divisor: Int32) -> Int32 {
    precondition(divisor > 0, "divisor must be positive")
    let quotient = value / divisor
    let remainder = value % divisor
    return remainder < 0 ? quotient - 1 : quotient
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

public struct TerrainLODSamplePayload: Equatable {
    public let biome: RegistryKey<Biome>?
    public let materialID: String?
}

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

public struct TerrainSurfaceLODCell: Equatable {
    public let x: Int32
    public let z: Int32
    public let cellSize: Int32
    public let surfaceY: Int32?
    public let surfaceBiome: RegistryKey<Biome>?
}

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

struct ChunkGenerationComponentBenchmark {
    let configureNanos: UInt64
    let samplerInitNanos: UInt64
    let sharedBakeNanos: UInt64
    let terrainOnlyNanos: UInt64
    let quartBiomesOnlyNanos: UInt64
    let blockBiomesOnlyNanos: UInt64
    let fullGenerateIntoNanos: UInt64
}

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
    private let worldSeed: WorldSeed
    private let biomeSubsampler = VoronoiBiomeSubsampler()
    private let voronoiSHA: UInt64
    private var config: NoiseSettings?
    private let configuredSettingsKeyName: String?
    private var configuredDimensionKey: RegistryKey<Dimension>?
    private var registries = WorldGenerationRegistries()
    private var searchTrees: [RegistryKey<Dimension>: BiomeSearchTree] = [:]
    private var endBiomeDimensions = Set<RegistryKey<Dimension>>()
    private var directPointSamplingDensityFunctions: DirectPointSamplingDensityFunctions?
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
        self.voronoiSHA = VoronoiBiomeSubsampler.makeVoronoiSHA(seed)
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
            self.searchTrees[RegistryKey(referencing: "minecraft:nether")] = try buildBiomeSearchTree(
                from: self.registries.biomeRegistry,
                entries: getPredefinedBiomeSearchTreeData(for: "nether")!
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
                return .searchTree(tree)
            }
        }
        if let configuredSettingsKeyName {
            let key = RegistryKey<Dimension>(referencing: configuredSettingsKeyName)
            if self.usesTheEndBiomeGetter(for: key) {
                return .theEnd
            }
            if let tree = self.searchTrees[key] {
                return .searchTree(tree)
            }
        }
        if let overworld = self.searchTrees[RegistryKey(referencing: "minecraft:overworld")] {
            return .searchTree(overworld)
        }
        if let nether = self.searchTrees[RegistryKey(referencing: "minecraft:nether")] {
            return .searchTree(nether)
        }
        if !self.endBiomeDimensions.isEmpty {
            return .theEnd
        }
        if let tree = self.searchTrees.first?.value {
            return .searchTree(tree)
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

    private func generateTerrainChunk(at chunkPos: PosInt2D, using config: NoiseSettings) throws -> ProtoChunk {
        let chunk = ProtoChunk()
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
        chunkSampler.generateTerrain(into: chunk, with: terrainDensity)
        return chunk
    }

    private func generateLODBiomeChunk(
        at chunkPos: PosInt2D,
        using config: NoiseSettings,
        with biomeDensityFunctions: ChunkBiomeDensityFunctions
    ) throws -> ProtoChunk {
        let chunk = ProtoChunk()
        let minY = Int32(config.minY)
        let height = Int32(config.height)
        try chunk.configure(minY: minY, height: height)

        if let biomeSampler = self.configuredChunkBiomeSampler() {
            switch biomeSampler {
            case .searchTree(let searchTree):
                self.generateBiomesIntoChunk(
                    chunk,
                    at: chunkPos,
                    minY: minY,
                    using: searchTree,
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
            return searchTree.getUnchecked(
                temperature: functions.temperature.sample(at: pos),
                humidity: functions.humidity.sample(at: pos),
                continentalness: functions.continentalness.sample(at: pos),
                erosion: functions.erosion.sample(at: pos),
                weirdness: functions.weirdness.sample(at: pos),
                depth: functions.depth.sample(at: pos),
                using: lookupState
            )
        }
    }

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
    /// - Throws: Any errors thrown by biome sampling or cache generation (if applied), or if `to` is less than `from`.
    /// - Returns: An X-major array of biomes (indexed by [Z*(to.x-from.x)+X]).
    public func generateBiomesInSquare(from fromPos: PosInt2D, to toPos: PosInt2D, atY y: Int32, in dim: RegistryKey<Dimension>, scale: Int32 = 4, forceNoBaking: Bool = false) throws -> [RegistryKey<Biome>]? {
        if scale <= 0 {
            throw WorldGenerationErrors.invalidScale
        }
        if fromPos.x >= toPos.x || fromPos.z >= toPos.z {
            throw WorldGenerationErrors.fromPosGreaterThanToPos
        }

        let isTheEnd = self.usesTheEndBiomeGetter(for: dim)
        let searchTree = self.searchTrees[dim]
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
                        if isTheEnd {
                            biome = self.sampleTheEndBiome(at: pos)
                        } else if let noiseRouter = directNoiseRouter {
                            biome = searchTree!.getUnchecked(
                                temperature: noiseRouter.temperature.sample(at: pos),
                                humidity: noiseRouter.humidity.sample(at: pos),
                                continentalness: noiseRouter.continents.sample(at: pos),
                                erosion: noiseRouter.erosion.sample(at: pos),
                                weirdness: noiseRouter.weirdness.sample(at: pos),
                                depth: noiseRouter.depth.sample(at: pos)
                            )
                        } else {
                            let point = self.sampleNoisePoint(at: pos)
                            biome = searchTree!.getUnchecked(point)
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
                        } else if let noiseRouter = directNoiseRouter {
                            biome = searchTree!.getUnchecked(
                                temperature: noiseRouter.temperature.sample(at: pos),
                                humidity: noiseRouter.humidity.sample(at: pos),
                                continentalness: noiseRouter.continents.sample(at: pos),
                                erosion: noiseRouter.erosion.sample(at: pos),
                                weirdness: noiseRouter.weirdness.sample(at: pos),
                                depth: noiseRouter.depth.sample(at: pos)
                            )
                        } else {
                            let point = self.sampleNoisePoint(at: pos)
                            biome = searchTree!.getUnchecked(point)
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
                        biome = searchTree!.getUnchecked(
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
                        biome = searchTree!.getUnchecked(
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
        try chunk.configure(minY: minY, height: height)

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
            case .searchTree(let searchTree):
                self.generateBiomesIntoChunk(
                    chunk,
                    at: chunkPos,
                    minY: minY,
                    using: searchTree,
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

        chunkSampler.generateTerrain(into: chunk, with: chunkGenerationFunctions.terrainDensity)
    }

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
            try chunk.configure(minY: minY, height: height)
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
            case .searchTree(let searchTree):
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
            case .searchTree(let searchTree):
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
            case .searchTree(let searchTree):
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

    // Currently visible for testing only.
    func sampleFinalDensity(at pos: PosInt3D) throws -> Double {
        return try self.validatedDirectPointSamplingDensityFunctions(
            for: "Final density sampling"
        ).cacheless.finalDensity.sample(at: pos)
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
            DispatchQueue.concurrentPerform(iterations: workerCount) { workerIndex in
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
            DispatchQueue.concurrentPerform(iterations: workerCount) { workerIndex in
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
    case noSurfaceDensityInNoiseRouter
    case fromPosGreaterThanToPos
    case invalidScale
    case invalidProtoChunkHeight(Int)
}
