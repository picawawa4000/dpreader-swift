/// The type-specific output of complete structure block generation.
public enum StructureGeneratedResult {
    case desertPyramid(DesertPyramidGenerationResult)
    case jungleTemple(JungleTempleGenerationResult)
    case oceanMonument(OceanMonumentGenerationResult)
    case stronghold(StrongholdGenerationResult)
    case woodlandMansion(WoodlandMansionGenerationResult)
}

/// Errors raised when a structure type or required template cannot be generated.
public enum StructureGenerationError: Error, Equatable {
    case unsupportedStructureType(String)
    case missingStructureTemplate(String)
    case missingStructureDecorationParameters(String)
}

/// A structure registry entry decoded from `worldgen/structure` JSON.
public final class Structure: Codable {
    let type: String
    let biomes: Identifiers
    let spawnOverrides: [String: StructureSpawnOverride]
    let step: String
    let terrainAdaptation: StructureTerrainAdaptation?
    let settings: StructureSettings

    init(
        type: String,
        biomes: Identifiers,
        spawnOverrides: [String: StructureSpawnOverride],
        step: String,
        terrainAdaptation: StructureTerrainAdaptation? = nil,
        settings: StructureSettings = .empty
    ) {
        self.type = addDefaultNamespace(type)
        self.biomes = biomes
        self.spawnOverrides = spawnOverrides
        self.step = step
        self.terrainAdaptation = terrainAdaptation
        self.settings = settings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = addDefaultNamespace(try container.decode(String.self, forKey: .type))
        self.biomes = try container.decode(Identifiers.self, forKey: .biomes)
        self.spawnOverrides = (try? container.decode([String: StructureSpawnOverride].self, forKey: .spawnOverrides)) ?? [:]
        self.step = try container.decode(String.self, forKey: .step)
        if let terrainAdaptationRawValue = try container.decodeIfPresent(String.self, forKey: .terrainAdaptation) {
            let normalizedTerrainAdaptation = terrainAdaptationRawValue.replacingOccurrences(of: "minecraft:", with: "")
            if normalizedTerrainAdaptation == "none" {
                self.terrainAdaptation = nil
            } else if let terrainAdaptation = StructureTerrainAdaptation(rawValue: normalizedTerrainAdaptation) {
                self.terrainAdaptation = terrainAdaptation
            } else {
                throw DecodingError.dataCorruptedError(
                    forKey: .terrainAdaptation,
                    in: container,
                    debugDescription: "Unknown structure terrain adaptation: \(terrainAdaptationRawValue)"
                )
            }
        } else {
            self.terrainAdaptation = nil
        }
        self.settings = try Structure.decodeSettings(forType: self.type, from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.type, forKey: .type)
        try container.encode(self.biomes, forKey: .biomes)
        try container.encode(self.spawnOverrides, forKey: .spawnOverrides)
        try container.encode(self.step, forKey: .step)
        try container.encodeIfPresent(self.terrainAdaptation, forKey: .terrainAdaptation)
        try self.settings.encodeAdditionalFields(to: encoder)
    }

    private static func decodeSettings(forType type: String, from decoder: Decoder) throws -> StructureSettings {
        switch type {
        case "minecraft:jigsaw":
            return .jigsaw(try JigsawStructureSettings(from: decoder))
        case "minecraft:mineshaft":
            return .mineshaft(try MineshaftStructureSettings(from: decoder))
        case "minecraft:nether_fossil":
            return .netherFossil(try NetherFossilStructureSettings(from: decoder))
        case "minecraft:ocean_ruin":
            return .oceanRuin(try OceanRuinStructureSettings(from: decoder))
        case "minecraft:ruined_portal":
            return .ruinedPortal(try RuinedPortalStructureSettings(from: decoder))
        case
            "minecraft:buried_treasure",
            "minecraft:desert_pyramid",
            "minecraft:end_city",
            "minecraft:fortress",
            "minecraft:igloo",
            "minecraft:jungle_temple",
            "minecraft:ocean_monument",
            "minecraft:shipwreck",
            "minecraft:stronghold",
            "minecraft:swamp_hut",
            "minecraft:woodland_mansion":
            return .empty
        default:
            let container = try decoder.container(keyedBy: CodingKeys.self)
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown structure type: \(type)")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case biomes
        case spawnOverrides = "spawn_overrides"
        case step
        case terrainAdaptation = "terrain_adaptation"
    }

    /// Selects and positions the structure's pieces without placing their blocks.
    ///
    /// - Returns: The piece graph, or `nil` when terrain rejects the structure start.
    public func generatePieceGraph(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) throws -> PieceGraph? {
        switch self.type {
        case "minecraft:desert_pyramid":
            return DesertPyramid.generatePieceGraph(
                worldSeed: worldSeed,
                startChunk: startChunk,
                context: context
            )
        case "minecraft:jungle_temple":
            return JungleTemple.generatePieceGraph(
                worldSeed: worldSeed,
                startChunk: startChunk,
                context: context
            )
        case "minecraft:ocean_monument":
            return OceanMonument.generatePieceGraph(worldSeed: worldSeed, startChunk: startChunk)
        case "minecraft:stronghold":
            return Stronghold.generatePieceGraph(
                worldSeed: worldSeed,
                startChunk: startChunk,
                context: context
            )
        case "minecraft:woodland_mansion":
            return try WoodlandMansion.generatePieceGraph(
                worldSeed: worldSeed,
                startChunk: startChunk,
                context: context
            )
        default:
            throw StructureGenerationError.unsupportedStructureType(self.type)
        }
    }

    /// Generates the complete supported structure, including its sparse block volume and markers.
    ///
    /// - Returns: Type-specific generation output, or `nil` when terrain rejects the structure start.
    public func generate(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) throws -> StructureGeneratedResult? {
        switch self.type {
        case "minecraft:desert_pyramid":
            guard let result = DesertPyramid.generate(
                worldSeed: worldSeed,
                startChunk: startChunk,
                context: context
            ) else {
                return nil
            }
            return .desertPyramid(result)
        case "minecraft:ocean_monument":
            return .oceanMonument(
                OceanMonument.generate(worldSeed: worldSeed, startChunk: startChunk, context: context)
            )
        case "minecraft:jungle_temple":
            guard let result = JungleTemple.generate(
                worldSeed: worldSeed,
                startChunk: startChunk,
                context: context
            ) else { return nil }
            return .jungleTemple(result)
        case "minecraft:stronghold":
            return .stronghold(
                Stronghold.generate(worldSeed: worldSeed, startChunk: startChunk, context: context)
            )
        case "minecraft:woodland_mansion":
            guard let decoration = context.structureDecorationParameters(forStructureID: "minecraft:mansion") else {
                throw StructureGenerationError.missingStructureDecorationParameters("minecraft:mansion")
            }
            guard let result = try WoodlandMansion.generate(
                worldSeed: worldSeed,
                startChunk: startChunk,
                context: context,
                decoration: decoration
            ) else {
                return nil
            }
            return .woodlandMansion(result)
        default:
            throw StructureGenerationError.unsupportedStructureType(self.type)
        }
    }

    /// Generates only the structure state needed to locate its loot containers.
    public func generateLoot(
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) throws -> [StructureLootContainer]? {
        switch self.type {
        case "minecraft:desert_pyramid":
            return DesertPyramid.generateLoot(
                worldSeed: worldSeed,
                startChunk: startChunk,
                context: context
            )
        case "minecraft:jungle_temple":
            return JungleTemple.generateLoot(
                worldSeed: worldSeed,
                startChunk: startChunk,
                context: context
            )
        case "minecraft:ocean_monument":
            return OceanMonument.generateLoot(
                worldSeed: worldSeed,
                startChunk: startChunk,
                context: context
            )
        case "minecraft:stronghold":
            return Stronghold.generateLoot(
                worldSeed: worldSeed,
                startChunk: startChunk,
                context: context
            )
        case "minecraft:woodland_mansion":
            guard let decoration = context.structureDecorationParameters(forStructureID: "minecraft:mansion") else {
                throw StructureGenerationError.missingStructureDecorationParameters("minecraft:mansion")
            }
            return try WoodlandMansion.generateLoot(
                worldSeed: worldSeed,
                startChunk: startChunk,
                context: context,
                decoration: decoration
            )
        default:
            throw StructureGenerationError.unsupportedStructureType(self.type)
        }
    }
}

enum StructureSettings {
    case empty
    case jigsaw(JigsawStructureSettings)
    case mineshaft(MineshaftStructureSettings)
    case netherFossil(NetherFossilStructureSettings)
    case oceanRuin(OceanRuinStructureSettings)
    case ruinedPortal(RuinedPortalStructureSettings)

    fileprivate func encodeAdditionalFields(to encoder: Encoder) throws {
        switch self {
        case .empty:
            return
        case .jigsaw(let value):
            try value.encode(to: encoder)
        case .mineshaft(let value):
            try value.encode(to: encoder)
        case .netherFossil(let value):
            try value.encode(to: encoder)
        case .oceanRuin(let value):
            try value.encode(to: encoder)
        case .ruinedPortal(let value):
            try value.encode(to: encoder)
        }
    }
}

/// Mob-spawn settings that replace biome spawns inside a structure.
public struct StructureSpawnOverride: Codable {
    let boundingBox: StructureSpawnBoundingBox
    let spawns: [BiomeSpawnerEntry]

    private enum CodingKeys: String, CodingKey {
        case boundingBox = "bounding_box"
        case spawns
    }
}

/// Whether a spawn override applies to the full structure or individual pieces.
public enum StructureSpawnBoundingBox: String, Codable {
    case full
    case piece
}

/// The terrain-blending shape applied around a generated structure.
public enum StructureTerrainAdaptation: String, Codable {
    case bury
    case beardThin = "beard_thin"
    case beardBox = "beard_box"
    case encapsulate
}

/// Generation settings for a pool-based jigsaw structure.
public struct JigsawStructureSettings: Codable {
    let maxDistanceFromCenter: Int
    let size: Int
    let startHeight: StructureHeightProvider
    let startJigsawName: String?
    let startPool: String
    let useExpansionHack: Bool
    let projectStartToHeightmap: String?
    let poolAliases: [StructurePoolAlias]?
    let dimensionPadding: Int?
    let liquidSettings: String?

    public init(
        maxDistanceFromCenter: Int,
        size: Int,
        startHeight: StructureHeightProvider,
        startJigsawName: String? = nil,
        startPool: String,
        useExpansionHack: Bool = false,
        projectStartToHeightmap: String? = nil,
        poolAliases: [StructurePoolAlias]? = nil,
        dimensionPadding: Int? = nil,
        liquidSettings: String? = nil
    ) {
        self.maxDistanceFromCenter = maxDistanceFromCenter
        self.size = size
        self.startHeight = startHeight
        self.startJigsawName = startJigsawName.map(addDefaultNamespace)
        self.startPool = addDefaultNamespace(startPool)
        self.useExpansionHack = useExpansionHack
        self.projectStartToHeightmap = projectStartToHeightmap
        self.poolAliases = poolAliases
        self.dimensionPadding = dimensionPadding
        self.liquidSettings = liquidSettings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.maxDistanceFromCenter = try container.decode(Int.self, forKey: .maxDistanceFromCenter)
        self.size = try container.decode(Int.self, forKey: .size)
        self.startHeight = try container.decode(StructureHeightProvider.self, forKey: .startHeight)
        self.startJigsawName = try container.decodeIfPresent(String.self, forKey: .startJigsawName).map(addDefaultNamespace)
        self.startPool = addDefaultNamespace(try container.decode(String.self, forKey: .startPool))
        self.useExpansionHack = try container.decodeIfPresent(Bool.self, forKey: .useExpansionHack) ?? false
        self.projectStartToHeightmap = try container.decodeIfPresent(String.self, forKey: .projectStartToHeightmap)
        self.poolAliases = try container.decodeIfPresent([StructurePoolAlias].self, forKey: .poolAliases)
        self.dimensionPadding = try container.decodeIfPresent(Int.self, forKey: .dimensionPadding)
        self.liquidSettings = try container.decodeIfPresent(String.self, forKey: .liquidSettings)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.maxDistanceFromCenter, forKey: .maxDistanceFromCenter)
        try container.encode(self.size, forKey: .size)
        try container.encode(self.startHeight, forKey: .startHeight)
        try container.encodeIfPresent(self.startJigsawName, forKey: .startJigsawName)
        try container.encode(self.startPool, forKey: .startPool)
        try container.encode(self.useExpansionHack, forKey: .useExpansionHack)
        try container.encodeIfPresent(self.projectStartToHeightmap, forKey: .projectStartToHeightmap)
        try container.encodeIfPresent(self.poolAliases, forKey: .poolAliases)
        try container.encodeIfPresent(self.dimensionPadding, forKey: .dimensionPadding)
        try container.encodeIfPresent(self.liquidSettings, forKey: .liquidSettings)
    }

    private enum CodingKeys: String, CodingKey {
        case maxDistanceFromCenter = "max_distance_from_center"
        case size
        case startHeight = "start_height"
        case startJigsawName = "start_jigsaw_name"
        case startPool = "start_pool"
        case useExpansionHack = "use_expansion_hack"
        case projectStartToHeightmap = "project_start_to_heightmap"
        case poolAliases = "pool_aliases"
        case dimensionPadding = "dimension_padding"
        case liquidSettings = "liquid_settings"
    }
}

/// Generation settings specific to mineshaft structures.
public struct MineshaftStructureSettings: Codable {
    let mineshaftType: MineshaftType

    private enum CodingKeys: String, CodingKey {
        case mineshaftType = "mineshaft_type"
    }
}

/// The visual and placement variant of a mineshaft.
public enum MineshaftType: String, Codable {
    case normal
    case mesa
}

/// Height selection settings for a Nether fossil.
public struct NetherFossilStructureSettings: Codable {
    let height: StructureHeightProvider
}

/// Temperature, size, and integrity settings for an ocean ruin.
public struct OceanRuinStructureSettings: Codable {
    let biomeTemp: OceanRuinTemperature
    let clusterProbability: Double
    let largeProbability: Double

    private enum CodingKeys: String, CodingKey {
        case biomeTemp = "biome_temp"
        case clusterProbability = "cluster_probability"
        case largeProbability = "large_probability"
    }
}

/// The warm or cold template family used by an ocean ruin.
public enum OceanRuinTemperature: String, Codable {
    case warm
    case cold
}

/// Weighted setup alternatives for a ruined portal.
public struct RuinedPortalStructureSettings: Codable {
    let setups: [RuinedPortalSetup]
}

/// One weighted placement and transformation setup for a ruined portal.
public struct RuinedPortalSetup: Codable {
    let airPocketProbability: Double
    let canBeCold: Bool
    let mossiness: Double
    let overgrown: Bool
    let placement: RuinedPortalPlacement
    let replaceWithBlackstone: Bool
    let vines: Bool
    let weight: Double

    private enum CodingKeys: String, CodingKey {
        case airPocketProbability = "air_pocket_probability"
        case canBeCold = "can_be_cold"
        case mossiness
        case overgrown
        case placement
        case replaceWithBlackstone = "replace_with_blackstone"
        case vines
        case weight
    }
}

/// The terrain-relative location selected for a ruined portal.
public enum RuinedPortalPlacement: String, Codable {
    case partlyBuried = "partly_buried"
    case onLandSurface = "on_land_surface"
    case onOceanFloor = "on_ocean_floor"
    case inMountain = "in_mountain"
    case underground
    case inNether = "in_nether"
}

/// A constant or uniform distribution used to choose a structure's start height.
public enum StructureHeightProvider: Codable, Equatable {
    case constant(VerticalAnchor)
    case uniform(minInclusive: VerticalAnchor, maxInclusive: VerticalAnchor)

    public init(from decoder: any Decoder) throws {
        if let anchor = try? VerticalAnchor(from: decoder) {
            self = .constant(anchor)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = addDefaultNamespace(try container.decode(String.self, forKey: .type))
        switch type {
        case "minecraft:uniform":
            self = .uniform(
                minInclusive: try container.decode(VerticalAnchor.self, forKey: .minInclusive),
                maxInclusive: try container.decode(VerticalAnchor.self, forKey: .maxInclusive)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown structure height provider type: \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .constant(let anchor):
            try anchor.encode(to: encoder)
        case .uniform(let minInclusive, let maxInclusive):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode("minecraft:uniform", forKey: .type)
            try container.encode(minInclusive, forKey: .minInclusive)
            try container.encode(maxInclusive, forKey: .maxInclusive)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case minInclusive = "min_inclusive"
        case maxInclusive = "max_inclusive"
    }
}

private enum StructurePoolAliasTypeKey: String, CodingKey {
    case type
}

/// A polymorphic rule that redirects jigsaw structure-pool IDs.
public enum StructurePoolAlias: Codable {
    case direct(DirectStructurePoolAlias)
    case random(RandomStructurePoolAlias)
    case randomGroup(RandomGroupStructurePoolAlias)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: StructurePoolAliasTypeKey.self)
        let type = addDefaultNamespace(try container.decode(String.self, forKey: .type))
        switch type {
        case "minecraft:direct":
            self = .direct(try DirectStructurePoolAlias(from: decoder))
        case "minecraft:random":
            self = .random(try RandomStructurePoolAlias(from: decoder))
        case "minecraft:random_group":
            self = .randomGroup(try RandomGroupStructurePoolAlias(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown structure pool alias type: \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .direct(let value):
            try value.encode(to: encoder)
        case .random(let value):
            try value.encode(to: encoder)
        case .randomGroup(let value):
            try value.encode(to: encoder)
        }
    }
}

/// A pool alias that always replaces one pool ID with another.
public struct DirectStructurePoolAlias: Codable {
    let alias: String
    let target: String

    public init(alias: String, target: String) {
        self.alias = addDefaultNamespace(alias)
        self.target = addDefaultNamespace(target)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(String.self, forKey: .type)
        self.alias = addDefaultNamespace(try container.decode(String.self, forKey: .alias))
        self.target = addDefaultNamespace(try container.decode(String.self, forKey: .target))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:direct", forKey: .type)
        try container.encode(self.alias, forKey: .alias)
        try container.encode(self.target, forKey: .target)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case alias
        case target
    }
}

/// A pool alias that selects one weighted target pool.
public struct RandomStructurePoolAlias: Codable {
    let alias: String
    let targets: [WeightedStructurePoolAliasTarget]

    public init(alias: String, targets: [WeightedStructurePoolAliasTarget]) {
        self.alias = addDefaultNamespace(alias)
        self.targets = targets
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(String.self, forKey: .type)
        self.alias = addDefaultNamespace(try container.decode(String.self, forKey: .alias))
        self.targets = try container.decode([WeightedStructurePoolAliasTarget].self, forKey: .targets)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:random", forKey: .type)
        try container.encode(self.alias, forKey: .alias)
        try container.encode(self.targets, forKey: .targets)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case alias
        case targets
    }
}

/// One weighted target in a random pool alias.
public struct WeightedStructurePoolAliasTarget: Codable {
    let data: String
    let weight: Int

    public init(data: String, weight: Int) {
        self.data = addDefaultNamespace(data)
        self.weight = weight
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.data = addDefaultNamespace(try container.decode(String.self, forKey: .data))
        self.weight = try container.decode(Int.self, forKey: .weight)
    }
}

/// A pool alias that randomly selects a group of direct aliases.
public struct RandomGroupStructurePoolAlias: Codable {
    let groups: [WeightedDirectStructurePoolAliasGroup]

    public init(groups: [WeightedDirectStructurePoolAliasGroup]) {
        self.groups = groups
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(String.self, forKey: .type)
        self.groups = try container.decode([WeightedDirectStructurePoolAliasGroup].self, forKey: .groups)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:random_group", forKey: .type)
        try container.encode(self.groups, forKey: .groups)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case groups
    }
}

/// One weighted collection of direct aliases in a random-group alias.
public struct WeightedDirectStructurePoolAliasGroup: Codable {
    let data: [DirectStructurePoolAlias]
    let weight: Int
}

/// Weighted structures paired with the rule that places their candidate starts.
public struct StructureSet: Codable {
    let placement: StructurePlacement
    let structures: [WeightedStructure]
}

/// A structure registry ID and its selection weight within a structure set.
public struct WeightedStructure: Codable {
    let structure: String
    let weight: Int

    public init(structure: String, weight: Int) {
        self.structure = addDefaultNamespace(structure)
        self.weight = weight
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.structure = addDefaultNamespace(try container.decode(String.self, forKey: .structure))
        self.weight = try container.decode(Int.self, forKey: .weight)
    }
}

private enum StructurePlacementTypeKey: String, CodingKey {
    case type
}

/// A random-spread or concentric-rings structure placement rule.
public enum StructurePlacement: Codable {
    case randomSpread(RandomSpreadStructurePlacement)
    case concentricRings(ConcentricRingsStructurePlacement)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: StructurePlacementTypeKey.self)
        let type = addDefaultNamespace(try container.decode(String.self, forKey: .type))
        switch type {
        case "minecraft:random_spread":
            self = .randomSpread(try RandomSpreadStructurePlacement(from: decoder))
        case "minecraft:concentric_rings":
            self = .concentricRings(try ConcentricRingsStructurePlacement(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown structure placement type: \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .randomSpread(let value):
            try value.encode(to: encoder)
        case .concentricRings(let value):
            try value.encode(to: encoder)
        }
    }
}

/// A grid-based placement rule that selects at most one candidate per region.
public struct RandomSpreadStructurePlacement: Codable {
    let salt: Int
    let separation: Int
    let spacing: Int
    let spreadType: RandomSpreadStructurePlacementSpreadType
    let frequency: Double?
    let frequencyReductionMethod: RandomSpreadStructurePlacementFrequencyReductionMethod?
    let locateOffset: PosInt3D?
    let exclusionZone: StructurePlacementExclusionZone?

    public init(
        salt: Int,
        separation: Int,
        spacing: Int,
        spreadType: RandomSpreadStructurePlacementSpreadType = .linear,
        frequency: Double? = nil,
        frequencyReductionMethod: RandomSpreadStructurePlacementFrequencyReductionMethod? = nil,
        locateOffset: PosInt3D? = nil,
        exclusionZone: StructurePlacementExclusionZone? = nil
    ) {
        self.salt = salt
        self.separation = separation
        self.spacing = spacing
        self.spreadType = spreadType
        self.frequency = frequency
        self.frequencyReductionMethod = frequencyReductionMethod
        self.locateOffset = locateOffset
        self.exclusionZone = exclusionZone
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(String.self, forKey: .type)
        self.salt = try container.decode(Int.self, forKey: .salt)
        self.separation = try container.decode(Int.self, forKey: .separation)
        self.spacing = try container.decode(Int.self, forKey: .spacing)
        self.spreadType = try container.decodeIfPresent(RandomSpreadStructurePlacementSpreadType.self, forKey: .spreadType) ?? .linear
        self.frequency = try container.decodeIfPresent(Double.self, forKey: .frequency)
        self.frequencyReductionMethod = try container.decodeIfPresent(RandomSpreadStructurePlacementFrequencyReductionMethod.self, forKey: .frequencyReductionMethod)
        self.locateOffset = try container.decodeIfPresent(PosInt3D.self, forKey: .locateOffset)
        self.exclusionZone = try container.decodeIfPresent(StructurePlacementExclusionZone.self, forKey: .exclusionZone)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:random_spread", forKey: .type)
        try container.encode(self.salt, forKey: .salt)
        try container.encode(self.separation, forKey: .separation)
        try container.encode(self.spacing, forKey: .spacing)
        try container.encode(self.spreadType, forKey: .spreadType)
        try container.encodeIfPresent(self.frequency, forKey: .frequency)
        try container.encodeIfPresent(self.frequencyReductionMethod, forKey: .frequencyReductionMethod)
        try container.encodeIfPresent(self.locateOffset, forKey: .locateOffset)
        try container.encodeIfPresent(self.exclusionZone, forKey: .exclusionZone)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case salt
        case separation
        case spacing
        case spreadType = "spread_type"
        case frequency
        case frequencyReductionMethod = "frequency_reduction_method"
        case locateOffset = "locate_offset"
        case exclusionZone = "exclusion_zone"
    }
}

/// The distribution used to choose a candidate chunk within a placement region.
public enum RandomSpreadStructurePlacementSpreadType: String, Codable {
    case linear
    case triangular
}

/// The vanilla compatibility algorithm used to apply placement frequency.
public enum RandomSpreadStructurePlacementFrequencyReductionMethod: String, Codable {
    case `default` = "default"
    case legacyType1 = "legacy_type_1"
    case legacyType2 = "legacy_type_2"
    case legacyType3 = "legacy_type_3"
}

/// A rule that suppresses placements near another structure set.
public struct StructurePlacementExclusionZone: Codable {
    let chunkCount: Int
    let otherSet: String

    public init(chunkCount: Int, otherSet: String) {
        self.chunkCount = chunkCount
        self.otherSet = addDefaultNamespace(otherSet)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.chunkCount = try container.decode(Int.self, forKey: .chunkCount)
        self.otherSet = addDefaultNamespace(try container.decode(String.self, forKey: .otherSet))
    }

    private enum CodingKeys: String, CodingKey {
        case chunkCount = "chunk_count"
        case otherSet = "other_set"
    }
}

/// A placement rule that arranges candidate starts in rings around world spawn.
public struct ConcentricRingsStructurePlacement: Codable {
    let count: Int
    let distance: Int
    let preferredBiomes: Identifiers
    let salt: Int
    let spread: Int

    init(count: Int, distance: Int, preferredBiomes: Identifiers, salt: Int, spread: Int) {
        self.count = count
        self.distance = distance
        self.preferredBiomes = preferredBiomes
        self.salt = salt
        self.spread = spread
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(String.self, forKey: .type)
        self.count = try container.decode(Int.self, forKey: .count)
        self.distance = try container.decode(Int.self, forKey: .distance)
        self.preferredBiomes = try container.decode(Identifiers.self, forKey: .preferredBiomes)
        self.salt = try container.decode(Int.self, forKey: .salt)
        self.spread = try container.decode(Int.self, forKey: .spread)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:concentric_rings", forKey: .type)
        try container.encode(self.count, forKey: .count)
        try container.encode(self.distance, forKey: .distance)
        try container.encode(self.preferredBiomes, forKey: .preferredBiomes)
        try container.encode(self.salt, forKey: .salt)
        try container.encode(self.spread, forKey: .spread)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case count
        case distance
        case preferredBiomes = "preferred_biomes"
        case salt
        case spread
    }
}
