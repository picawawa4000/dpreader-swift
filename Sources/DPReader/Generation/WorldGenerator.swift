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
    private var initialisedFunctionIds = Set<RegistryKey<DensityFunction>>()

    init(withSeed seed: WorldSeed, registries: WorldGenerationRegistries) {
        self.seed = seed
        self.registries = registries
    }

    func bake(noise: any DensityFunctionNoise) throws -> BakedNoise {
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
        // TODO: implementation
        // this will store the cache markers somewhere so that they can be quickly baked
        #warning("Unimplemented function FullDensityFunctionBaker.bake(cacheMarker:)!")
        return cacheMarker
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
        /// TODO: this is not correct unless using legacy random (see NoiseConfig)
        var random: any Random = CheckedRandom(seed: self.seed)
        return noise.copy(withRandom: &random)
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

/// A chunk implementation for world generation.
public final class ProtoChunk {
    private let storage = PalettedChunkBlockStorage(filledWith: BlockState(type: Blocks.AIR))
    
    public func setBlock(_ state: BlockState, at pos: PosInt3D) {
        self.storage.setBlock(state, at: pos)
    }

    public func getBlock(at pos: PosInt3D) -> BlockState {
        return self.storage.getBlock(at: pos)
    }
}

/*
final class ProtoChunkFlatCache: DensityFunction {
    private let parent: ProtoChunk

    init(withParent parent: ProtoChunk) {
        self.parent = parent
    }

    func sample(at: PosInt3D) -> Double {
        
    }

    func bake(withBaker: any DensityFunctionBaker) throws -> any DensityFunction {
        
    }
}
*/

/// The thing that actually generates worlds.
public final class WorldGenerator {
    private let worldSeed: WorldSeed
    private var config: NoiseSettings?
    private var registries = WorldGenerationRegistries()
    private var searchTrees: [RegistryKey<Dimension>: BiomeSearchTree] = [:]

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
        let baker = FullDensityFunctionBaker(withSeed: self.worldSeed, registries: self.registries)
        try self.registries.densityFunctionRegistry.forEach { (key: RegistryKey<any DensityFunction>, value: any DensityFunction) in
            if baker.hasBeenBaked(atKey: key) { return }
            baker.registries.densityFunctionRegistry.register(try value.bake(withBaker: baker), forKey: key)
        }

        if self.config != nil {
            self.config = self.config!.with(noiseRouter: try self.config!.noiseRouter.bakeAll(withBaker: baker))
        }
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

    public func generateBiomesInSquare(from fromPos: PosInt2D, to toPos: PosInt2D, atY y: Int32, in dim: RegistryKey<Dimension>) throws -> [RegistryKey<Biome>]? {
        if fromPos.x > toPos.x || fromPos.z > toPos.z {
            throw WorldGenerationErrors.fromPosGreaterThanToPos
        }
        if fromPos == toPos {
            let biome = try self.sampleBiome(at: PosInt3D(x: fromPos.x, y: y, z: fromPos.z), in: dim)
            guard biome != nil else {
                return nil
            }
            return [biome!]
        }

        // if the generation area is small, don't bake the functions
        // if it's large, use a custom cache baker to speed up the process
        fatalError("Unimplemented function WorldGenerator.generateBiomesInSquare(from:to:atY:in:)!")
        return nil
    }

    /*
    Currently shelved along with the chunk protocol.

    /// Generate the chunk at this position and store it in the passed-in chunk.
    /// - Parameters:
    ///   - chunk: The chunk to generate into.
    ///   - chunkPos: The position to generate the chunk at.
    public func generateInto<C: Chunk>(_ chunk: inout C, at chunkPos: PosInt2D) {
        fatalError("Unimplemented function WorldGenerator.generateInto(_:at:)!")
        #warning("Unimplemented function WorldGenerator.generateInto(_:at:)!")
    }
    */

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
}
