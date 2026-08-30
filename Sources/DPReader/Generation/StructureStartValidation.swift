import Foundation

/// Heightmaps used while locating a structure's generation point.
public enum StructureStartHeightmap: Sendable {
    /// The first free block above any non-air block, including fluids.
    case worldSurfaceWG
    /// The first free block above terrain, ignoring water and lava.
    case oceanFloorWG
}

/// Inputs needed to reproduce the checks performed before a structure start is created.
///
/// Biomes are sampled at quart-aligned noise-biome coordinates, before Voronoi block-biome
/// sampling. The `heightmapSampler` returns the first free Y coordinate, matching vanilla
/// heightmap values.
public struct StructureStartValidationContext {
    public let dimension: RegistryKey<Dimension>
    public let seaLevel: Int32
    public let minimumWorldY: Int32
    public let maximumWorldY: Int32
    /// Whether every `WORLD_SURFACE_WG` height is guaranteed to be at least `seaLevel`.
    public let worldSurfaceIsAtLeastSeaLevel: Bool
    /// Whether generated height sampling is preferred to a conservative full vertical biome scan.
    /// The exact biome is still checked at the eventual generation position.
    public let prefersHeightBeforeBiomeValidation: Bool

    private let heightmapSampler: (StructureStartHeightmap, Int32, Int32) throws -> Int32
    private let biomeSampler: (PosInt3D) throws -> RegistryKey<Biome>?

    public init(
        dimension: RegistryKey<Dimension>,
        seaLevel: Int32,
        minimumWorldY: Int32,
        maximumWorldY: Int32,
        worldSurfaceIsAtLeastSeaLevel: Bool = false,
        prefersHeightBeforeBiomeValidation: Bool = false,
        heightmapSampler: @escaping (StructureStartHeightmap, Int32, Int32) throws -> Int32,
        biomeSampler: @escaping (PosInt3D) throws -> RegistryKey<Biome>?
    ) {
        precondition(maximumWorldY >= minimumWorldY, "maximumWorldY must not be below minimumWorldY")
        self.dimension = dimension
        self.seaLevel = seaLevel
        self.minimumWorldY = minimumWorldY
        self.maximumWorldY = maximumWorldY
        self.worldSurfaceIsAtLeastSeaLevel = worldSurfaceIsAtLeastSeaLevel
        self.prefersHeightBeforeBiomeValidation = prefersHeightBeforeBiomeValidation
        self.heightmapSampler = heightmapSampler
        self.biomeSampler = biomeSampler
    }

    /// Builds a validation context from a block sampler. This is convenient when the caller has
    /// already generated terrain for structure generation.
    public init(
        dimension: RegistryKey<Dimension>,
        maximumWorldY: Int32,
        generationContext: StructureGenerationContext,
        biomeSampler: @escaping (PosInt3D) throws -> RegistryKey<Biome>?
    ) {
        self.init(
            dimension: dimension,
            seaLevel: generationContext.seaLevel,
            minimumWorldY: generationContext.minimumWorldY,
            maximumWorldY: maximumWorldY,
            heightmapSampler: { heightmap, x, z in
                for y in stride(from: maximumWorldY, through: generationContext.minimumWorldY, by: -1) {
                    let block = generationContext.blockSampler(PosInt3D(x: x, y: y, z: z))
                    guard !block.isAir else { continue }
                    if heightmap == .oceanFloorWG && block.isStructureValidationFluid {
                        continue
                    }
                    return y &+ 1
                }
                return generationContext.minimumWorldY
            },
            biomeSampler: biomeSampler
        )
    }

    /// Builds a context backed directly by generated noise terrain and noise-biome sampling.
    /// The world generator must be configured with the noise settings used by `dimension`.
    public init(
        dimension: RegistryKey<Dimension>,
        seaLevel: Int32,
        worldGenerator: WorldGenerator
    ) throws {
        let settings = try worldGenerator.terrainSettingsForTesting()
        let minimumWorldY = Int32(settings.minY)
        let maximumWorldY = minimumWorldY &+ Int32(settings.height) &- 1
        let terrain = GeneratedStructureHeightmapSampler(
            worldGenerator: worldGenerator,
            seaLevel: seaLevel,
            minimumWorldY: minimumWorldY,
            maximumWorldY: maximumWorldY,
            dimension: dimension
        )
        self.init(
            dimension: dimension,
            seaLevel: seaLevel,
            minimumWorldY: minimumWorldY,
            maximumWorldY: maximumWorldY,
            worldSurfaceIsAtLeastSeaLevel:
                dimension.name != "minecraft:end" && dimension.name != "minecraft:the_end",
            prefersHeightBeforeBiomeValidation: true,
            heightmapSampler: terrain.height,
            biomeSampler: { position in
                try worldGenerator.sampleBiome(at: position, in: dimension)
            }
        )
    }

    func height(_ heightmap: StructureStartHeightmap, x: Int32, z: Int32) throws -> Int32 {
        try self.heightmapSampler(heightmap, x, z)
    }

    func biome(at position: PosInt3D) throws -> RegistryKey<Biome>? {
        let quartAlignedPosition = PosInt3D(
            x: floorDiv(position.x, by: 4) &* 4,
            y: floorDiv(position.y, by: 4) &* 4,
            z: floorDiv(position.z, by: 4) &* 4
        )
        return try self.biomeSampler(quartAlignedPosition)
    }
}

/// The generation point and biome which made a candidate structure start valid.
public struct ValidatedStructureStart {
    public let structureKey: RegistryKey<Structure>
    public let chunkPos: PosInt2D
    public let generationPosition: PosInt3D
    public let biome: RegistryKey<Biome>
}

extension Structure {
    /// Resolves the generation point and validates its biome and terrain. Cheap biome checks are
    /// performed before heightmap sampling whenever the eventual Y is terrain-dependent.
    func generatePosition(
        structureKey: RegistryKey<Structure>,
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        allowedBiomeNames: Set<String>,
        monumentSurroundingBiomeNames: Set<String>?,
        context: StructureStartValidationContext
    ) throws -> ValidatedStructureStart? {
        let startX = startChunk.x &* 16
        let startZ = startChunk.z &* 16
        let centerX = startX &+ 8
        let centerZ = startZ &+ 8

        func makeValidatedStart(
            at position: PosInt3D,
            knownBiome: RegistryKey<Biome>? = nil
        ) throws -> ValidatedStructureStart? {
            let biome = try knownBiome ?? context.biome(at: position)
            guard let biome, allowedBiomeNames.contains(biome.name) else { return nil }
            return ValidatedStructureStart(
                structureKey: structureKey,
                chunkPos: startChunk,
                generationPosition: position,
                biome: biome
            )
        }

        // A heightmap can only select a Y in this interval. Scanning its biome column is cheap
        // and gives a safe early rejection without assuming that biomes are two-dimensional.
        func biomeColumnCanMatch(
            x: Int32,
            z: Int32,
            minimumY: Int32 = context.minimumWorldY,
            maximumY: Int32 = context.maximumWorldY &+ 1,
            preferredY: Int32 = context.seaLevel
        ) throws -> Bool {
            let preferredQuartY = floorDiv(preferredY, by: 4)
            if let biome = try context.biome(at: PosInt3D(x: x, y: preferredQuartY &* 4, z: z)),
               allowedBiomeNames.contains(biome.name) {
                return true
            }
            let minimumQuartY = floorDiv(minimumY, by: 4)
            let maximumQuartY = floorDiv(maximumY, by: 4)
            guard minimumQuartY <= maximumQuartY else { return false }
            for quartY in minimumQuartY...maximumQuartY where quartY != preferredQuartY {
                if let biome = try context.biome(at: PosInt3D(x: x, y: quartY &* 4, z: z)),
                   allowedBiomeNames.contains(biome.name) {
                    return true
                }
            }
            return false
        }

        switch self.type {
        case "minecraft:desert_pyramid":
            if !context.prefersHeightBeforeBiomeValidation {
                guard try biomeColumnCanMatch(x: centerX, z: centerZ) else { return nil }
            }
            let y = try context.height(.worldSurfaceWG, x: centerX, z: centerZ)
            let position = PosInt3D(x: centerX, y: y, z: centerZ)
            guard let biome = try context.biome(at: position), allowedBiomeNames.contains(biome.name) else {
                return nil
            }
            if !context.worldSurfaceIsAtLeastSeaLevel {
                guard try context.height(.worldSurfaceWG, x: startX, z: startZ) >= context.seaLevel else { return nil }
                guard try context.height(.worldSurfaceWG, x: startX &+ 20, z: startZ) >= context.seaLevel else { return nil }
                guard try context.height(.worldSurfaceWG, x: startX, z: startZ &+ 20) >= context.seaLevel else { return nil }
                guard try context.height(.worldSurfaceWG, x: startX &+ 20, z: startZ &+ 20) >= context.seaLevel else { return nil }
            }
            return try makeValidatedStart(at: position, knownBiome: biome)

        case "minecraft:jungle_temple":
            if !context.prefersHeightBeforeBiomeValidation {
                guard try biomeColumnCanMatch(x: centerX, z: centerZ) else { return nil }
            }
            let y = try context.height(.worldSurfaceWG, x: centerX, z: centerZ)
            let position = PosInt3D(x: centerX, y: y, z: centerZ)
            guard let biome = try context.biome(at: position), allowedBiomeNames.contains(biome.name) else {
                return nil
            }
            if !context.worldSurfaceIsAtLeastSeaLevel {
                guard try context.height(.worldSurfaceWG, x: startX, z: startZ) >= context.seaLevel else { return nil }
                guard try context.height(.worldSurfaceWG, x: startX &+ 11, z: startZ) >= context.seaLevel else { return nil }
                guard try context.height(.worldSurfaceWG, x: startX, z: startZ &+ 14) >= context.seaLevel else { return nil }
                guard try context.height(.worldSurfaceWG, x: startX &+ 11, z: startZ &+ 14) >= context.seaLevel else { return nil }
            }
            return try makeValidatedStart(at: position, knownBiome: biome)

        case "minecraft:woodland_mansion":
            let anchorX = startX &+ 7
            let anchorZ = startZ &+ 7
            if !context.prefersHeightBeforeBiomeValidation {
                guard try biomeColumnCanMatch(x: anchorX, z: anchorZ) else { return nil }
            }
            var random = checkedRandomForChunkGeneration(
                worldSeed: worldSeed,
                chunkX: startChunk.x,
                chunkZ: startChunk.z
            )
            let offsets = Self.cornerOffsets(forQuarterTurns: Int(random.next(bound: 4)))
            let y = try min(
                context.height(.worldSurfaceWG, x: anchorX, z: anchorZ),
                context.height(.worldSurfaceWG, x: anchorX &+ offsets.x, z: anchorZ),
                context.height(.worldSurfaceWG, x: anchorX, z: anchorZ &+ offsets.z),
                context.height(.worldSurfaceWG, x: anchorX &+ offsets.x, z: anchorZ &+ offsets.z)
            )
            guard y >= 60 else { return nil }
            return try makeValidatedStart(at: PosInt3D(x: anchorX, y: y, z: anchorZ))

        case "minecraft:end_city":
            if !context.prefersHeightBeforeBiomeValidation {
                guard try biomeColumnCanMatch(x: centerX, z: centerZ) else { return nil }
            }
            var random = checkedRandomForChunkGeneration(
                worldSeed: worldSeed,
                chunkX: startChunk.x,
                chunkZ: startChunk.z
            )
            let offsets = Self.endCityCornerOffsets(forQuarterTurns: Int(random.next(bound: 4)))
            let anchorX = startX &+ 7
            let anchorZ = startZ &+ 7
            let y = try min(
                context.height(.oceanFloorWG, x: anchorX, z: anchorZ),
                context.height(.oceanFloorWG, x: anchorX &+ offsets.x, z: anchorZ),
                context.height(.oceanFloorWG, x: anchorX, z: anchorZ &+ offsets.z),
                context.height(.oceanFloorWG, x: anchorX &+ offsets.x, z: anchorZ &+ offsets.z)
            )
            guard y >= 60 else { return nil }
            return try makeValidatedStart(at: PosInt3D(x: centerX, y: y, z: centerZ))

        case "minecraft:ocean_monument":
            guard let surroundingBiomeNames = monumentSurroundingBiomeNames else { return nil }
            let checkX = startX &+ 9
            let checkZ = startZ &+ 9
            let radius: Int32 = 29
            for quartY in floorDiv(context.seaLevel &- radius, by: 4)...floorDiv(context.seaLevel &+ radius, by: 4) {
                for quartZ in floorDiv(checkZ &- radius, by: 4)...floorDiv(checkZ &+ radius, by: 4) {
                    for quartX in floorDiv(checkX &- radius, by: 4)...floorDiv(checkX &+ radius, by: 4) {
                        guard let biome = try context.biome(
                            at: PosInt3D(x: quartX &* 4, y: quartY &* 4, z: quartZ &* 4)
                        ), surroundingBiomeNames.contains(biome.name) else {
                            return nil
                        }
                    }
                }
            }
            if !context.prefersHeightBeforeBiomeValidation {
                guard try biomeColumnCanMatch(x: centerX, z: centerZ) else { return nil }
            }
            let y = try context.height(.oceanFloorWG, x: centerX, z: centerZ)
            return try makeValidatedStart(at: PosInt3D(x: centerX, y: y, z: centerZ))

        case "minecraft:ocean_ruin", "minecraft:buried_treasure":
            if !context.prefersHeightBeforeBiomeValidation {
                guard try biomeColumnCanMatch(x: centerX, z: centerZ) else { return nil }
            }
            let y = try context.height(.oceanFloorWG, x: centerX, z: centerZ)
            return try makeValidatedStart(at: PosInt3D(x: centerX, y: y, z: centerZ))

        case "minecraft:shipwreck":
            if !context.prefersHeightBeforeBiomeValidation {
                guard try biomeColumnCanMatch(x: centerX, z: centerZ) else { return nil }
            }
            let heightmap: StructureStartHeightmap = structureKey.name.hasSuffix("_beached")
                ? .worldSurfaceWG
                : .oceanFloorWG
            let y = try context.height(heightmap, x: centerX, z: centerZ)
            return try makeValidatedStart(at: PosInt3D(x: centerX, y: y, z: centerZ))

        case "minecraft:igloo", "minecraft:swamp_hut", "minecraft:ruined_portal":
            if !context.prefersHeightBeforeBiomeValidation {
                guard try biomeColumnCanMatch(x: centerX, z: centerZ) else { return nil }
            }
            let y = try context.height(.worldSurfaceWG, x: centerX, z: centerZ)
            return try makeValidatedStart(at: PosInt3D(x: centerX, y: y, z: centerZ))

        case "minecraft:jigsaw":
            guard case .jigsaw(let settings) = self.settings else { return nil }
            var random = checkedRandomForChunkGeneration(
                worldSeed: worldSeed,
                chunkX: startChunk.x,
                chunkZ: startChunk.z
            )
            var y = settings.startHeight.sample(
                random: &random,
                minimumWorldY: context.minimumWorldY,
                maximumWorldY: context.maximumWorldY
            )
            let horizontalPosition = Self.jigsawHorizontalPosition(
                structureKey: structureKey,
                startX: startX,
                startZ: startZ,
                random: &random
            )
            if settings.projectStartToHeightmap != nil {
                if !context.prefersHeightBeforeBiomeValidation {
                    guard try biomeColumnCanMatch(
                        x: horizontalPosition.x,
                        z: horizontalPosition.z,
                        minimumY: y &+ context.minimumWorldY,
                        maximumY: y &+ context.maximumWorldY &+ 1,
                        preferredY: y &+ context.seaLevel
                    ) else { return nil }
                }
                y &+= try context.height(.worldSurfaceWG, x: startX, z: startZ)
            }
            return try makeValidatedStart(
                at: PosInt3D(x: horizontalPosition.x, y: y, z: horizontalPosition.z)
            )

        case "minecraft:nether_fossil":
            guard case .netherFossil(let settings) = self.settings else { return nil }
            var random = checkedRandomForChunkGeneration(
                worldSeed: worldSeed,
                chunkX: startChunk.x,
                chunkZ: startChunk.z
            )
            let y = settings.height.sample(
                random: &random,
                minimumWorldY: context.minimumWorldY,
                maximumWorldY: context.maximumWorldY
            )
            return try makeValidatedStart(at: PosInt3D(x: centerX, y: y, z: centerZ))

        case "minecraft:mineshaft":
            return try makeValidatedStart(at: PosInt3D(x: centerX, y: 50, z: centerZ))

        case "minecraft:stronghold", "minecraft:fortress":
            return try makeValidatedStart(at: PosInt3D(x: centerX, y: 0, z: centerZ))

        default:
            return try makeValidatedStart(at: PosInt3D(x: centerX, y: 0, z: centerZ))
        }
    }

    private static func cornerOffsets(forQuarterTurns rotation: Int) -> (x: Int32, z: Int32) {
        switch rotation & 3 {
        case 0: return (-5, 5)
        case 1: return (-5, -5)
        case 2: return (5, -5)
        default: return (5, 5)
        }
    }

    private static func endCityCornerOffsets(forQuarterTurns rotation: Int) -> (x: Int32, z: Int32) {
        switch rotation & 3 {
        case 0: return (5, 5)
        case 1: return (-5, 5)
        case 2: return (-5, -5)
        default: return (5, -5)
        }
    }

    private static func jigsawHorizontalPosition<R: Random>(
        structureKey: RegistryKey<Structure>,
        startX: Int32,
        startZ: Int32,
        random: inout R
    ) -> PosInt2D {
        let key = structureKey.name
        if key == "minecraft:pillager_outpost" {
            let rotation = Int(random.next(bound: 4))
            return self.rotatedTemplateCenter(
                startX: startX,
                startZ: startZ,
                width: 15,
                depth: 15,
                rotation: rotation
            )
        }

        if key == "minecraft:trial_chambers" {
            let rotation = Int(random.next(bound: 4))
            _ = random.next(bound: 2)
            return self.rotatedTemplateCenter(
                startX: startX,
                startZ: startZ,
                width: 19,
                depth: 19,
                rotation: rotation
            )
        }

        if key == "minecraft:ancient_city" {
            let rotation = Int(random.next(bound: 4))
            _ = random.next(bound: 3)
            return self.ancientCityTemplateCenter(startX: startX, startZ: startZ, rotation: rotation)
        }

        if key == "minecraft:bastion_remnant" {
            let rotation = Int(random.next(bound: 4))
            let dimensions: (Int32, Int32)
            switch random.next(bound: 4) {
            case 0: dimensions = (46, 46)
            case 1: dimensions = (30, 48)
            case 2: dimensions = (38, 38)
            default: dimensions = (16, 32)
            }
            return self.rotatedTemplateCenter(
                startX: startX,
                startZ: startZ,
                width: dimensions.0,
                depth: dimensions.1,
                rotation: rotation
            )
        }

        if key.hasPrefix("minecraft:village_") {
            let rotation = Int(random.next(bound: 4))
            let dimensions = self.villageStartDimensions(structureKey: key, random: &random)
            return self.rotatedTemplateCenter(
                startX: startX,
                startZ: startZ,
                width: dimensions.0,
                depth: dimensions.1,
                rotation: rotation
            )
        }

        return PosInt2D(x: startX &+ 8, z: startZ &+ 8)
    }

    private static func villageStartDimensions<R: Random>(
        structureKey: String,
        random: inout R
    ) -> (Int32, Int32) {
        switch structureKey {
        case "minecraft:village_plains":
            switch random.next(bound: 204) {
            case 0..<50, 200: return (9, 9)
            case 50..<100, 201: return (10, 10)
            case 100..<150, 202: return (8, 15)
            default: return (11, 11)
            }
        case "minecraft:village_desert":
            switch random.next(bound: 250) {
            case 0..<98, 245..<247: return (17, 9)
            case 98..<196, 247..<249: return (12, 12)
            default: return (15, 15)
            }
        case "minecraft:village_savanna":
            switch random.next(bound: 459) {
            case 0..<100, 450..<452: return (14, 12)
            case 100..<150, 452: return (11, 11)
            case 150..<300, 453..<456: return (9, 11)
            default: return (9, 9)
            }
        case "minecraft:village_taiga":
            switch random.next(bound: 100) {
            case 0..<49, 98: return (22, 18)
            default: return (9, 9)
            }
        case "minecraft:village_snowy":
            switch random.next(bound: 306) {
            case 0..<100, 300..<302: return (12, 8)
            case 100..<150, 302: return (11, 9)
            default: return (7, 7)
            }
        default:
            return (1, 1)
        }
    }

    private static func rotatedTemplateCenter(
        startX: Int32,
        startZ: Int32,
        width: Int32,
        depth: Int32,
        rotation: Int
    ) -> PosInt2D {
        let originX: Int32
        let originZ: Int32
        let rotatedWidth: Int32
        let rotatedDepth: Int32
        switch rotation & 3 {
        case 0:
            (originX, originZ, rotatedWidth, rotatedDepth) = (0, 0, width, depth)
        case 1:
            (originX, originZ, rotatedWidth, rotatedDepth) = (1 &- depth, 0, depth, width)
        case 2:
            (originX, originZ, rotatedWidth, rotatedDepth) = (1 &- width, 1 &- depth, width, depth)
        default:
            (originX, originZ, rotatedWidth, rotatedDepth) = (0, 1 &- width, depth, width)
        }
        return PosInt2D(
            x: startX &+ floorDiv(originX &* 2 &+ rotatedWidth &- 1, by: 2),
            z: startZ &+ floorDiv(originZ &* 2 &+ rotatedDepth &- 1, by: 2)
        )
    }

    private static func ancientCityTemplateCenter(startX: Int32, startZ: Int32, rotation: Int) -> PosInt2D {
        let positiveXOffset: Int32 = startX > 0 ? -1 : 0
        let negativeXOffset: Int32 = startX < 0 ? 1 : 0
        let positiveZOffset: Int32 = startZ > 0 ? -1 : 0
        let negativeZOffset: Int32 = startZ < 0 ? 1 : 0
        let originX: Int32
        let originZ: Int32
        let width: Int32
        let depth: Int32
        switch rotation & 3 {
        case 0:
            (originX, originZ, width, depth) = (positiveXOffset &- 13, positiveZOffset &- 20, 18, 41)
        case 1:
            (originX, originZ, width, depth) = (negativeXOffset &- 41 &+ 20, positiveZOffset &- 13, 41, 18)
        case 2:
            (originX, originZ, width, depth) = (negativeXOffset &- 18 &+ 13, negativeZOffset &- 41 &+ 20, 18, 41)
        default:
            (originX, originZ, width, depth) = (positiveXOffset &- 20, negativeZOffset &- 18 &+ 13, 41, 18)
        }
        return PosInt2D(
            x: startX &+ floorDiv(originX &* 2 &+ width &- 1, by: 2),
            z: startZ &+ floorDiv(originZ &* 2 &+ depth &- 1, by: 2)
        )
    }
}

extension StructureHeightProvider {
    func sample<R: Random>(
        random: inout R,
        minimumWorldY: Int32,
        maximumWorldY: Int32
    ) -> Int32 {
        switch self {
        case .constant(let anchor):
            return anchor.resolve(minimumWorldY: minimumWorldY, maximumWorldY: maximumWorldY)
        case .uniform(let minInclusive, let maxInclusive):
            let lower = minInclusive.resolve(minimumWorldY: minimumWorldY, maximumWorldY: maximumWorldY)
            let upper = maxInclusive.resolve(minimumWorldY: minimumWorldY, maximumWorldY: maximumWorldY)
            precondition(upper >= lower, "Invalid structure height provider range")
            return lower &+ Int32(random.next(bound: UInt32(upper &- lower &+ 1)))
        }
    }
}

extension VerticalAnchor {
    func resolve(minimumWorldY: Int32, maximumWorldY: Int32) -> Int32 {
        switch self {
        case .absolute(let value): return Int32(value)
        case .aboveBottom(let value): return minimumWorldY &+ Int32(value)
        case .belowTop(let value): return maximumWorldY &- Int32(value)
        }
    }
}

private extension BlockState {
    var isStructureValidationFluid: Bool {
        self.id == "minecraft:water" || self.id == "minecraft:lava"
    }
}

public final class GeneratedStructureHeightmapSampler {
    private struct ColumnKey: Hashable {
        let x: Int32
        let z: Int32
    }

    private struct ChunkKey: Hashable {
        let x: Int32
        let z: Int32
    }

    private struct CachedChunkSampler {
        let sampler: StructureStartTerrainChunkSampler
        var lastUse: UInt64
    }

    private let worldGenerator: WorldGenerator
    private let seaLevel: Int32
    private let minimumWorldY: Int32
    private let maximumWorldY: Int32
    private let hasSeaLevelFluid: Bool
    private var terrainHeights: [ColumnKey: Int32] = [:]
    private var worldSurfaceHeights: [ColumnKey: Int32] = [:]
    private var chunkSamplers: [ChunkKey: CachedChunkSampler] = [:]
    private var chunkSamplerUse: UInt64 = 0
    private let maximumCachedChunkSamplers = 16
    #if DEBUG && !(os(WASI) || arch(wasm32))
    public private(set) var terrainDensityColumnEvaluationCount = 0
    public private(set) var terrainChunkSamplerConstructionNanos: UInt64 = 0
    public private(set) var terrainInterpolationNanos: UInt64 = 0
    public private(set) var terrainHeightCacheHits = 0
    public private(set) var terrainHeightCacheMisses = 0
    #endif

    public init(
        worldGenerator: WorldGenerator,
        seaLevel: Int32,
        minimumWorldY: Int32,
        maximumWorldY: Int32,
        dimension: RegistryKey<Dimension>
    ) {
        self.worldGenerator = worldGenerator
        self.seaLevel = seaLevel
        self.minimumWorldY = minimumWorldY
        self.maximumWorldY = maximumWorldY
        self.hasSeaLevelFluid = dimension.name != "minecraft:end" && dimension.name != "minecraft:the_end"
    }

    public func height(_ heightmap: StructureStartHeightmap, _ x: Int32, _ z: Int32) throws -> Int32 {
        let key = ColumnKey(x: x, z: z)
        if heightmap == .worldSurfaceWG, self.hasSeaLevelFluid {
            if let cached = self.terrainHeights[key] {
                #if DEBUG && !(os(WASI) || arch(wasm32))
                self.terrainHeightCacheHits += 1
                #endif
                return max(cached, self.seaLevel)
            }
            if let cached = self.worldSurfaceHeights[key] {
                #if DEBUG && !(os(WASI) || arch(wasm32))
                self.terrainHeightCacheHits += 1
                #endif
                return cached
            }

            #if DEBUG && !(os(WASI) || arch(wasm32))
            self.terrainHeightCacheMisses += 1
            #endif
            let chunkSampler = try self.chunkSampler(for: x, z: z)
            #if DEBUG && !(os(WASI) || arch(wasm32))
            let previousEvaluationCount = chunkSampler.densityColumnEvaluationCount
            #endif
            #if DEBUG && !(os(WASI) || arch(wasm32))
            let interpolationStart = DispatchTime.now().uptimeNanoseconds
            #endif
            if let terrainHeight = chunkSampler.height(
                atX: x,
                z: z,
                minimumTerrainY: self.seaLevel - 1
            ) {
                #if DEBUG && !(os(WASI) || arch(wasm32))
                self.terrainInterpolationNanos += DispatchTime.now().uptimeNanoseconds - interpolationStart
                self.terrainDensityColumnEvaluationCount +=
                    chunkSampler.densityColumnEvaluationCount - previousEvaluationCount
                #endif
                self.terrainHeights[key] = terrainHeight
                return terrainHeight
            }
            #if DEBUG && !(os(WASI) || arch(wasm32))
            self.terrainInterpolationNanos += DispatchTime.now().uptimeNanoseconds - interpolationStart
            self.terrainDensityColumnEvaluationCount +=
                chunkSampler.densityColumnEvaluationCount - previousEvaluationCount
            #endif
            self.worldSurfaceHeights[key] = self.seaLevel
            return self.seaLevel
        }
        let terrainHeight: Int32
        if let cached = self.terrainHeights[key] {
            #if DEBUG && !(os(WASI) || arch(wasm32))
            self.terrainHeightCacheHits += 1
            #endif
            terrainHeight = cached
        } else {
            #if DEBUG && !(os(WASI) || arch(wasm32))
            self.terrainHeightCacheMisses += 1
            #endif
            let chunkSampler = try self.chunkSampler(for: x, z: z)
            #if DEBUG && !(os(WASI) || arch(wasm32))
            let previousEvaluationCount = chunkSampler.densityColumnEvaluationCount
            #endif
            #if DEBUG && !(os(WASI) || arch(wasm32))
            let interpolationStart = DispatchTime.now().uptimeNanoseconds
            #endif
            guard let sampledHeight = chunkSampler.height(atX: x, z: z) else {
                preconditionFailure("An unbounded terrain-height query must return a height")
            }
            terrainHeight = sampledHeight
            #if DEBUG && !(os(WASI) || arch(wasm32))
            self.terrainInterpolationNanos += DispatchTime.now().uptimeNanoseconds - interpolationStart
            self.terrainDensityColumnEvaluationCount +=
                chunkSampler.densityColumnEvaluationCount - previousEvaluationCount
            #endif
            self.terrainHeights[key] = terrainHeight
        }

        if heightmap == .worldSurfaceWG && self.hasSeaLevelFluid {
            return max(terrainHeight, self.seaLevel)
        }
        return terrainHeight
    }

    private func chunkSampler(for x: Int32, z: Int32) throws -> StructureStartTerrainChunkSampler {
        let chunkKey = ChunkKey(x: floorDiv(x, by: 16), z: floorDiv(z, by: 16))
        self.chunkSamplerUse &+= 1
        if var cached = self.chunkSamplers[chunkKey] {
            cached.lastUse = self.chunkSamplerUse
            self.chunkSamplers[chunkKey] = cached
            return cached.sampler
        }
        if self.chunkSamplers.count >= self.maximumCachedChunkSamplers,
           let oldest = self.chunkSamplers.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            self.chunkSamplers.removeValue(forKey: oldest.key)
        }
        #if DEBUG && !(os(WASI) || arch(wasm32))
        let constructionStart = DispatchTime.now().uptimeNanoseconds
        #endif
        let sampler = try self.worldGenerator.terrainHeightSamplerForStructureStartValidation(
            at: PosInt2D(x: chunkKey.x, z: chunkKey.z)
        )
        #if DEBUG && !(os(WASI) || arch(wasm32))
        self.terrainChunkSamplerConstructionNanos += DispatchTime.now().uptimeNanoseconds - constructionStart
        #endif
        self.chunkSamplers[chunkKey] = CachedChunkSampler(sampler: sampler, lastUse: self.chunkSamplerUse)
        return sampler
    }
}
