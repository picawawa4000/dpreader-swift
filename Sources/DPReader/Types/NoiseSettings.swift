public final class NoiseSettings: Codable {
    // let seaLevel: Int
    // let disableMobGeneration: Bool
    // let oreVeinsEnabled: Bool
    // let aquifersEnabled: Bool
    let legacyRandomSource: Bool
    // let defaultBlock: BlockState
    // let defaultFluid: BlockState
    // let spawnTarget: [NoiseParameter]
    let minY: Int, height: Int, sizeHorizontal: Int, sizeVertical: Int
    let noiseRouter: NoiseRouter
    let surfaceRule: SurfaceRule

    public init(
        legacyRandomSource: Bool,
        minY: Int,
        height: Int,
        sizeHorizontal: Int,
        sizeVertical: Int,
        noiseRouter: NoiseRouter,
        surfaceRule: SurfaceRule
    ) {
        self.legacyRandomSource = legacyRandomSource
        self.minY = minY
        self.height = height
        self.sizeHorizontal = sizeHorizontal
        self.sizeVertical = sizeVertical
        self.noiseRouter = noiseRouter
        self.surfaceRule = surfaceRule
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.legacyRandomSource = try container.decode(Bool.self, forKey: .legacyRandomSource)
        self.noiseRouter = try container.decode(NoiseRouter.self, forKey: .noiseRouter)
        self.surfaceRule = try container.decode(SurfaceRuleInitializer.self, forKey: .surfaceRule).value

        let noiseContainer = try container.nestedContainer(keyedBy: NoiseCodingKeys.self, forKey: .noise)
        self.minY = try noiseContainer.decode(Int.self, forKey: .minY)
        self.height = try noiseContainer.decode(Int.self, forKey: .height)
        self.sizeHorizontal = try noiseContainer.decode(Int.self, forKey: .sizeHorizontal)
        self.sizeVertical = try noiseContainer.decode(Int.self, forKey: .sizeVertical)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.legacyRandomSource, forKey: .legacyRandomSource)
        try container.encode(self.noiseRouter, forKey: .noiseRouter)
        try container.encode(SurfaceRuleEncoder(value: self.surfaceRule), forKey: .surfaceRule)
        var noiseContainer = container.nestedContainer(keyedBy: NoiseCodingKeys.self, forKey: .noise)
        try noiseContainer.encode(self.minY, forKey: .minY)
        try noiseContainer.encode(self.height, forKey: .height)
        try noiseContainer.encode(self.sizeHorizontal, forKey: .sizeHorizontal)
        try noiseContainer.encode(self.sizeVertical, forKey: .sizeVertical)
    }

    private enum CodingKeys: String, CodingKey {
        case noise = "noise"
        case legacyRandomSource = "legacy_random_source"
        case noiseRouter = "noise_router"
        case surfaceRule = "surface_rule"
    }

    private enum NoiseCodingKeys: String, CodingKey {
        case minY = "min_y"
        case height = "height"
        case sizeHorizontal = "size_horizontal"
        case sizeVertical = "size_vertical"
    }
}

// Several density functions that together create the world.
// See the wiki's page on noise routers in datapacks for an explanation of what exactly these do.
public final class NoiseRouter: Codable {
    /// TERRAIN

    // Used by surface rules and aquifers. Generally represents the beginning of the stone layer.
    public let preliminarySurfaceLevel: any DensityFunction
    // If this returns >0 for a given block position, that position is solid. Otherwise, it's air.
    public let finalDensity: any DensityFunction

    /// AQUIFERS

    // Controls the barriers between aquifers and caves.
    public let barrier: any DensityFunction
    // Controls how common aquifers are. Higher values lead to higher probabilities.
    public let fluidLevelFloodedness: any DensityFunction
    // Controls the height of the fluid level for each 2D position.
    public let fluidLevelSpread: any DensityFunction
    // Any value greater than 0.3 results in an aquifer using lava instead of water.
    public let lava: any DensityFunction

    /// ORE VEINS
    
    // Affects ore vein generation in a rather complicated way. (See the wiki for exact details.)
    public let veinToggle: any DensityFunction
    // Determines where ore veins are.
    public let veinRidged: any DensityFunction
    // Determines which blocks in a vein are ore blocks.
    public let veinGap: any DensityFunction

    /// BIOMES
    
    // One of the biome placement functions.
    public let temperature: any DensityFunction
    // One of the biome placement functions (called "vegetation" in-game).
    public let humidity: any DensityFunction
    // One of the biome placement functions. Does not affect terrain shape.
    public let continents: any DensityFunction
    // One of the biome placement functions. Also affects aquifers, but not terrain shape.
    public let erosion: any DensityFunction
    // One of the biome placement functions. Also affects aquifers, but not terrain shape.
    public let depth: any DensityFunction
    // One of the biome placement functions (called "ridges" in-game). Does not affect terrain shape.
    public let weirdness: any DensityFunction

    public init(
        preliminarySurfaceLevel: DensityFunction,
        finalDensity: DensityFunction,
        barrier: DensityFunction,
        fluidLevelFloodedness: DensityFunction,
        fluidLevelSpread: DensityFunction,
        lava: DensityFunction,
        veinToggle: DensityFunction,
        veinRidged: DensityFunction,
        veinGap: DensityFunction,
        temperature: DensityFunction,
        humidity: DensityFunction,
        continents: DensityFunction,
        erosion: DensityFunction,
        depth: DensityFunction,
        weirdness: DensityFunction
    ) {
        self.preliminarySurfaceLevel = preliminarySurfaceLevel
        self.finalDensity = finalDensity
        self.barrier = barrier
        self.fluidLevelFloodedness = fluidLevelFloodedness
        self.fluidLevelSpread = fluidLevelSpread
        self.lava = lava
        self.veinToggle = veinToggle
        self.veinRidged = veinRidged
        self.veinGap = veinGap
        self.temperature = temperature
        self.humidity = humidity
        self.continents = continents
        self.erosion = erosion
        self.depth = depth
        self.weirdness = weirdness
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.preliminarySurfaceLevel = try container.decode(DensityFunctionInitializer.self, forKey: .preliminarySurfaceLevel).value
        self.finalDensity = try container.decode(DensityFunctionInitializer.self, forKey: .finalDensity).value
        self.barrier = try container.decode(DensityFunctionInitializer.self, forKey: .barrier).value
        self.fluidLevelFloodedness = try container.decode(DensityFunctionInitializer.self, forKey: .fluidLevelFloodedness).value
        self.fluidLevelSpread = try container.decode(DensityFunctionInitializer.self, forKey: .fluidLevelSpread).value
        self.lava = try container.decode(DensityFunctionInitializer.self, forKey: .lava).value
        self.veinToggle = try container.decode(DensityFunctionInitializer.self, forKey: .veinToggle).value
        self.veinRidged = try container.decode(DensityFunctionInitializer.self, forKey: .veinRidged).value
        self.veinGap = try container.decode(DensityFunctionInitializer.self, forKey: .veinGap).value
        self.temperature = try container.decode(DensityFunctionInitializer.self, forKey: .temperature).value
        self.humidity = try container.decode(DensityFunctionInitializer.self, forKey: .humidity).value
        self.continents = try container.decode(DensityFunctionInitializer.self, forKey: .continents).value
        self.erosion = try container.decode(DensityFunctionInitializer.self, forKey: .erosion).value
        self.depth = try container.decode(DensityFunctionInitializer.self, forKey: .depth).value
        self.weirdness = try container.decode(DensityFunctionInitializer.self, forKey: .weirdness).value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(DensityFunctionEncoder(value: preliminarySurfaceLevel), forKey: .preliminarySurfaceLevel)
        try container.encode(DensityFunctionEncoder(value: finalDensity), forKey: .finalDensity)
        try container.encode(DensityFunctionEncoder(value: barrier), forKey: .barrier)
        try container.encode(DensityFunctionEncoder(value: fluidLevelFloodedness), forKey: .fluidLevelFloodedness)
        try container.encode(DensityFunctionEncoder(value: fluidLevelSpread), forKey: .fluidLevelSpread)
        try container.encode(DensityFunctionEncoder(value: lava), forKey: .lava)
        try container.encode(DensityFunctionEncoder(value: veinToggle), forKey: .veinToggle)
        try container.encode(DensityFunctionEncoder(value: veinRidged), forKey: .veinRidged)
        try container.encode(DensityFunctionEncoder(value: veinGap), forKey: .veinGap)
        try container.encode(DensityFunctionEncoder(value: temperature), forKey: .temperature)
        try container.encode(DensityFunctionEncoder(value: humidity), forKey: .humidity)
        try container.encode(DensityFunctionEncoder(value: continents), forKey: .continents)
        try container.encode(DensityFunctionEncoder(value: erosion), forKey: .erosion)
        try container.encode(DensityFunctionEncoder(value: depth), forKey: .depth)
        try container.encode(DensityFunctionEncoder(value: weirdness), forKey: .weirdness)
    }

    private enum CodingKeys: String, CodingKey {
        case preliminarySurfaceLevel = "preliminary_surface_level"
        case finalDensity = "final_density"
        case barrier = "barrier"
        case fluidLevelFloodedness = "fluid_level_floodedness"
        case fluidLevelSpread = "fluid_level_spread"
        case lava = "lava"
        case veinToggle = "vein_toggle"
        case veinRidged = "vein_ridged"
        case veinGap = "vein_gap"
        case temperature = "temperature"
        case humidity = "vegetation"
        case continents = "continents"
        case erosion = "erosion"
        case depth = "depth"
        case weirdness = "ridges"
    }
}

private struct DensityFunctionEncoder: Encodable {
    let value: any DensityFunction

    func encode(to encoder: Encoder) throws {
        try (value as Encodable).encode(to: encoder)
    }
}

public struct BlockStateDefinition: Codable {
    public let name: String
    public let properties: [String: String]?

    public init(name: String, properties: [String: String]? = nil) {
        self.name = name
        self.properties = properties
    }

    private enum CodingKeys: String, CodingKey {
        case name = "Name"
        case properties = "Properties"
    }
}

public enum VerticalAnchor: Codable, Equatable {
    case absolute(Int)
    case aboveBottom(Int)
    case belowTop(Int)

    public init(from decoder: Decoder) throws {
        let singleValue = try decoder.singleValueContainer()
        if let value = try? singleValue.decode(Int.self) {
            self = .absolute(value)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try container.decodeIfPresent(Int.self, forKey: .absolute) {
            self = .absolute(value)
            return
        }
        if let value = try container.decodeIfPresent(Int.self, forKey: .aboveBottom) {
            self = .aboveBottom(value)
            return
        }
        if let value = try container.decodeIfPresent(Int.self, forKey: .belowTop) {
            self = .belowTop(value)
            return
        }

        throw DecodingError.dataCorruptedError(
            forKey: .absolute,
            in: container,
            debugDescription: "Unrecognized vertical anchor"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .absolute(let value):
            try container.encode(value, forKey: .absolute)
        case .aboveBottom(let value):
            try container.encode(value, forKey: .aboveBottom)
        case .belowTop(let value):
            try container.encode(value, forKey: .belowTop)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case absolute = "absolute"
        case aboveBottom = "above_bottom"
        case belowTop = "below_top"
    }
}

public protocol SurfaceRule: Encodable {}

public struct SurfaceRuleSequence: SurfaceRule, Codable {
    public let sequence: [SurfaceRule]

    public init(sequence: [SurfaceRule]) {
        self.sequence = sequence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let initializers = try container.decode([SurfaceRuleInitializer].self, forKey: .sequence)
        self.sequence = initializers.map { $0.value }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:sequence", forKey: .type)
        try container.encode(sequence.map { SurfaceRuleEncoder(value: $0) }, forKey: .sequence)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case sequence = "sequence"
    }
}

public struct SurfaceRuleConditionRule: SurfaceRule, Codable {
    public let ifTrue: SurfaceRuleCondition
    public let thenRun: SurfaceRule

    public init(ifTrue: SurfaceRuleCondition, thenRun: SurfaceRule) {
        self.ifTrue = ifTrue
        self.thenRun = thenRun
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.ifTrue = try container.decode(SurfaceRuleConditionInitializer.self, forKey: .ifTrue).value
        self.thenRun = try container.decode(SurfaceRuleInitializer.self, forKey: .thenRun).value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:condition", forKey: .type)
        try container.encode(SurfaceRuleConditionEncoder(value: ifTrue), forKey: .ifTrue)
        try container.encode(SurfaceRuleEncoder(value: thenRun), forKey: .thenRun)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case ifTrue = "if_true"
        case thenRun = "then_run"
    }
}

public struct SurfaceRuleBlock: SurfaceRule, Codable {
    public let resultState: BlockStateDefinition

    public init(resultState: BlockStateDefinition) {
        self.resultState = resultState
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.resultState = try container.decode(BlockStateDefinition.self, forKey: .resultState)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:block", forKey: .type)
        try container.encode(resultState, forKey: .resultState)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case resultState = "result_state"
    }
}

public struct SurfaceRuleBandlands: SurfaceRule, Codable {
    public init() {}

    public init(from decoder: Decoder) throws {
        _ = decoder
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:bandlands", forKey: .type)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
    }
}

public protocol SurfaceRuleCondition: Encodable {}

public struct SurfaceRuleAbovePreliminarySurface: SurfaceRuleCondition, Codable {
    public init() {}

    public init(from decoder: Decoder) throws {
        _ = decoder
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:above_preliminary_surface", forKey: .type)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
    }
}

public struct SurfaceRuleBiomeCondition: SurfaceRuleCondition, Codable {
    public let biomeIs: [String]

    public init(biomeIs: [String]) {
        self.biomeIs = biomeIs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let biomes = try? container.decode([String].self, forKey: .biomeIs) {
            self.biomeIs = biomes
        } else {
            self.biomeIs = [try container.decode(String.self, forKey: .biomeIs)]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:biome", forKey: .type)
        try container.encode(biomeIs, forKey: .biomeIs)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case biomeIs = "biome_is"
    }
}

public struct SurfaceRuleHoleCondition: SurfaceRuleCondition, Codable {
    public init() {}

    public init(from decoder: Decoder) throws {
        _ = decoder
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:hole", forKey: .type)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
    }
}

public struct SurfaceRuleNoiseThresholdCondition: SurfaceRuleCondition, Codable {
    public let noise: String
    public let minThreshold: Double
    public let maxThreshold: Double

    public init(noise: String, minThreshold: Double, maxThreshold: Double) {
        self.noise = noise
        self.minThreshold = minThreshold
        self.maxThreshold = maxThreshold
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.noise = try container.decode(String.self, forKey: .noise)
        self.minThreshold = try container.decode(Double.self, forKey: .minThreshold)
        self.maxThreshold = try container.decode(Double.self, forKey: .maxThreshold)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case noise = "noise"
        case minThreshold = "min_threshold"
        case maxThreshold = "max_threshold"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:noise_threshold", forKey: .type)
        try container.encode(noise, forKey: .noise)
        try container.encode(minThreshold, forKey: .minThreshold)
        try container.encode(maxThreshold, forKey: .maxThreshold)
    }
}

public struct SurfaceRuleNotCondition: SurfaceRuleCondition, Codable {
    public let invert: SurfaceRuleCondition

    public init(invert: SurfaceRuleCondition) {
        self.invert = invert
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.invert = try container.decode(SurfaceRuleConditionInitializer.self, forKey: .invert).value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:not", forKey: .type)
        try container.encode(SurfaceRuleConditionEncoder(value: invert), forKey: .invert)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case invert = "invert"
    }
}

public struct SurfaceRuleSteepCondition: SurfaceRuleCondition, Codable {
    public init() {}

    public init(from decoder: Decoder) throws {
        _ = decoder
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:steep", forKey: .type)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
    }
}

public enum SurfaceRuleStoneDepthSurfaceType: String, Codable {
    case floor = "floor"
    case ceiling = "ceiling"
}

public struct SurfaceRuleStoneDepthCondition: SurfaceRuleCondition, Codable {
    public let offset: Int
    public let surfaceType: SurfaceRuleStoneDepthSurfaceType
    public let addSurfaceDepth: Bool
    public let secondaryDepthRange: Int?

    public init(offset: Int, surfaceType: SurfaceRuleStoneDepthSurfaceType, addSurfaceDepth: Bool, secondaryDepthRange: Int? = nil) {
        self.offset = offset
        self.surfaceType = surfaceType
        self.addSurfaceDepth = addSurfaceDepth
        self.secondaryDepthRange = secondaryDepthRange
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.offset = try container.decode(Int.self, forKey: .offset)
        self.surfaceType = try container.decode(SurfaceRuleStoneDepthSurfaceType.self, forKey: .surfaceType)
        self.addSurfaceDepth = try container.decode(Bool.self, forKey: .addSurfaceDepth)
        self.secondaryDepthRange = try container.decodeIfPresent(Int.self, forKey: .secondaryDepthRange)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case offset = "offset"
        case surfaceType = "surface_type"
        case addSurfaceDepth = "add_surface_depth"
        case secondaryDepthRange = "secondary_depth_range"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:stone_depth", forKey: .type)
        try container.encode(offset, forKey: .offset)
        try container.encode(surfaceType, forKey: .surfaceType)
        try container.encode(addSurfaceDepth, forKey: .addSurfaceDepth)
        try container.encodeIfPresent(secondaryDepthRange, forKey: .secondaryDepthRange)
    }
}

public struct SurfaceRuleTemperatureCondition: SurfaceRuleCondition, Codable {
    public init() {}

    public init(from decoder: Decoder) throws {
        _ = decoder
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:temperature", forKey: .type)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
    }
}

public struct SurfaceRuleVerticalGradientCondition: SurfaceRuleCondition, Codable {
    public let randomName: String
    public let trueAtAndBelow: VerticalAnchor
    public let falseAtAndAbove: VerticalAnchor

    public init(randomName: String, trueAtAndBelow: VerticalAnchor, falseAtAndAbove: VerticalAnchor) {
        self.randomName = randomName
        self.trueAtAndBelow = trueAtAndBelow
        self.falseAtAndAbove = falseAtAndAbove
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.randomName = try container.decode(String.self, forKey: .randomName)
        self.trueAtAndBelow = try container.decode(VerticalAnchor.self, forKey: .trueAtAndBelow)
        self.falseAtAndAbove = try container.decode(VerticalAnchor.self, forKey: .falseAtAndAbove)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case randomName = "random_name"
        case trueAtAndBelow = "true_at_and_below"
        case falseAtAndAbove = "false_at_and_above"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:vertical_gradient", forKey: .type)
        try container.encode(randomName, forKey: .randomName)
        try container.encode(trueAtAndBelow, forKey: .trueAtAndBelow)
        try container.encode(falseAtAndAbove, forKey: .falseAtAndAbove)
    }
}

public struct SurfaceRuleWaterCondition: SurfaceRuleCondition, Codable {
    public let offset: Int
    public let surfaceDepthMultiplier: Int
    public let addStoneDepth: Bool

    public init(offset: Int, surfaceDepthMultiplier: Int, addStoneDepth: Bool) {
        self.offset = offset
        self.surfaceDepthMultiplier = surfaceDepthMultiplier
        self.addStoneDepth = addStoneDepth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.offset = try container.decode(Int.self, forKey: .offset)
        self.surfaceDepthMultiplier = try container.decode(Int.self, forKey: .surfaceDepthMultiplier)
        self.addStoneDepth = try container.decode(Bool.self, forKey: .addStoneDepth)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case offset = "offset"
        case surfaceDepthMultiplier = "surface_depth_multiplier"
        case addStoneDepth = "add_stone_depth"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:water", forKey: .type)
        try container.encode(offset, forKey: .offset)
        try container.encode(surfaceDepthMultiplier, forKey: .surfaceDepthMultiplier)
        try container.encode(addStoneDepth, forKey: .addStoneDepth)
    }
}

public struct SurfaceRuleYAboveCondition: SurfaceRuleCondition, Codable {
    public let anchor: VerticalAnchor
    public let surfaceDepthMultiplier: Int
    public let addStoneDepth: Bool

    public init(anchor: VerticalAnchor, surfaceDepthMultiplier: Int, addStoneDepth: Bool) {
        self.anchor = anchor
        self.surfaceDepthMultiplier = surfaceDepthMultiplier
        self.addStoneDepth = addStoneDepth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.anchor = try container.decode(VerticalAnchor.self, forKey: .anchor)
        self.surfaceDepthMultiplier = try container.decode(Int.self, forKey: .surfaceDepthMultiplier)
        self.addStoneDepth = try container.decode(Bool.self, forKey: .addStoneDepth)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case anchor = "anchor"
        case surfaceDepthMultiplier = "surface_depth_multiplier"
        case addStoneDepth = "add_stone_depth"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:y_above", forKey: .type)
        try container.encode(anchor, forKey: .anchor)
        try container.encode(surfaceDepthMultiplier, forKey: .surfaceDepthMultiplier)
        try container.encode(addStoneDepth, forKey: .addStoneDepth)
    }
}

public struct SurfaceRuleConditionInitializer: Decodable {
    let value: SurfaceRuleCondition

    public init(from decoder: Decoder) throws {
        self.value = try decodeSurfaceRuleCondition(from: decoder)
    }
}

public struct SurfaceRuleInitializer: Decodable {
    let value: SurfaceRule

    public init(from decoder: Decoder) throws {
        self.value = try decodeSurfaceRule(from: decoder)
    }
}

private struct SurfaceRuleEncoder: Encodable {
    let value: SurfaceRule

    func encode(to encoder: Encoder) throws {
        try (value as Encodable).encode(to: encoder)
    }
}

private struct SurfaceRuleConditionEncoder: Encodable {
    let value: SurfaceRuleCondition

    func encode(to encoder: Encoder) throws {
        try (value as Encodable).encode(to: encoder)
    }
}

private enum SurfaceRuleDecodingError: Error {
    case unknownRuleType(String)
    case unknownConditionType(String)
}

private func decodeSurfaceRule(from decoder: Decoder) throws -> SurfaceRule {
    let container = try decoder.container(keyedBy: SurfaceRuleTypeCodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "minecraft:sequence":
        return try SurfaceRuleSequence(from: decoder)
    case "minecraft:condition":
        return try SurfaceRuleConditionRule(from: decoder)
    case "minecraft:block":
        return try SurfaceRuleBlock(from: decoder)
    case "minecraft:bandlands":
        return SurfaceRuleBandlands()
    case "minecraft:badlands":
        print("WARNING: Read surface rule of type \"minecraft:badlands\" (resolved to \"minecraft:bandlands\"). This is not accepted by Minecraft as of 1.21.11.")
        return SurfaceRuleBandlands()
    default:
        throw SurfaceRuleDecodingError.unknownRuleType(type)
    }
}

private func decodeSurfaceRuleCondition(from decoder: Decoder) throws -> SurfaceRuleCondition {
    let container = try decoder.container(keyedBy: SurfaceRuleTypeCodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "minecraft:above_preliminary_surface":
        return SurfaceRuleAbovePreliminarySurface()
    case "minecraft:biome":
        return try SurfaceRuleBiomeCondition(from: decoder)
    case "minecraft:hole":
        return SurfaceRuleHoleCondition()
    case "minecraft:noise_threshold":
        return try SurfaceRuleNoiseThresholdCondition(from: decoder)
    case "minecraft:not":
        return try SurfaceRuleNotCondition(from: decoder)
    case "minecraft:steep":
        return SurfaceRuleSteepCondition()
    case "minecraft:stone_depth":
        return try SurfaceRuleStoneDepthCondition(from: decoder)
    case "minecraft:temperature":
        return SurfaceRuleTemperatureCondition()
    case "minecraft:vertical_gradient":
        return try SurfaceRuleVerticalGradientCondition(from: decoder)
    case "minecraft:water":
        return try SurfaceRuleWaterCondition(from: decoder)
    case "minecraft:y_above":
        return try SurfaceRuleYAboveCondition(from: decoder)
    default:
        throw SurfaceRuleDecodingError.unknownConditionType(type)
    }
}

private enum SurfaceRuleTypeCodingKeys: String, CodingKey {
    case type = "type"
}
