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
    // let surfaceRule: SurfaceRule

    public init(
        legacyRandomSource: Bool,
        minY: Int,
        height: Int,
        sizeHorizontal: Int,
        sizeVertical: Int,
        noiseRouter: NoiseRouter
    ) {
        self.legacyRandomSource = legacyRandomSource
        self.minY = minY
        self.height = height
        self.sizeHorizontal = sizeHorizontal
        self.sizeVertical = sizeVertical
        self.noiseRouter = noiseRouter
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.legacyRandomSource = try container.decode(Bool.self, forKey: .legacyRandomSource)
        self.noiseRouter = try container.decode(NoiseRouter.self, forKey: .noiseRouter)

        let noiseContainer = try container.nestedContainer(keyedBy: NoiseCodingKeys.self, forKey: .noise)
        self.minY = try noiseContainer.decode(Int.self, forKey: .minY)
        self.height = try noiseContainer.decode(Int.self, forKey: .height)
        self.sizeHorizontal = try noiseContainer.decode(Int.self, forKey: .sizeHorizontal)
        self.sizeVertical = try noiseContainer.decode(Int.self, forKey: .sizeVertical)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(legacyRandomSource, forKey: .legacyRandomSource)
        try container.encode(noiseRouter, forKey: .noiseRouter)
        var noiseContainer = container.nestedContainer(keyedBy: NoiseCodingKeys.self, forKey: .noise)
        try noiseContainer.encode(minY, forKey: .minY)
        try noiseContainer.encode(height, forKey: .height)
        try noiseContainer.encode(sizeHorizontal, forKey: .sizeHorizontal)
        try noiseContainer.encode(sizeVertical, forKey: .sizeVertical)
    }

    private enum CodingKeys: String, CodingKey {
        case noise = "noise"
        case legacyRandomSource = "legacy_random_source"
        case noiseRouter = "noise_router"
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
