/// Stores all of the registries needed for world generation.
final class WorldGenerationRegistries {
    var densityFunctionRegistry = Registry<DensityFunction>()
    var bakedNoiseRegistry = Registry<DoublePerlinNoise>()
}

/// A density function baker that does all baking steps.
final class FullDensityFunctionBaker: DensityFunctionBaker {
    private let registries: WorldGenerationRegistries
    private var initialisedFunctionIds = Set<RegistryKey<DensityFunction>>()

    init(registries: WorldGenerationRegistries) {
        self.registries = registries
    }

    func bake(noise: any DensityFunctionNoise) throws -> BakedNoise {
        guard let sampler = self.registries.bakedNoiseRegistry.get(noise.key.convertType()) else {
            throw BakingErrors.noNoiseAtKey(noise.key.name)
        }
        return BakedNoise(fromKey: noise.key, withSampler: sampler)
    }

    func bake(referenceDensityFunction reference: ReferenceDensityFunction) throws -> any DensityFunction {
        guard let referencedFunction = self.registries.densityFunctionRegistry.get(reference.targetKey) else {
            throw BakingErrors.noDensityFunctionAtKey(reference.targetKey.name)
        }

        // The referenced function has already been baked
        if self.hasBeenBaked(atKey: reference.targetKey) { return referencedFunction }

        // Bake the function and insert the baked verson
        let bakedDensityFunction = try referencedFunction.bake(withBaker: self)
        self.registries.densityFunctionRegistry.register(bakedDensityFunction, forKey: reference.targetKey)
        return bakedDensityFunction
    }

    func hasBeenBaked(atKey key: RegistryKey<DensityFunction>) -> Bool {
        return self.initialisedFunctionIds.contains(key)
    }
}

private enum BakingErrors: Error {
    case noDensityFunctionAtKey(String)
    case noNoiseAtKey(String)
}

/// The thing that actually generates worlds.
public final class WorldGenerator {
    private let worldSeed: WorldSeed
    private let noiseSplitter: any RandomSplitter
    private var registries = WorldGenerationRegistries()

    /// Initialise this world generator.
    /// This function bakes all datapacks supplied to it, which is why it is impossible to add datapacks to an
    /// already-created world generator.
    /// - Parameters:
    ///   - seed: 
    ///   - datapacks: 
    public init(withWorldSeed seed: WorldSeed, usingDataPacks datapacks: [DataPack]) throws {
        self.worldSeed = seed
        var random = XoroshiroRandom(seed: seed)
        self.noiseSplitter = random.nextSplitter()

        for datapack in datapacks {
            self.registries.densityFunctionRegistry.mergeDown(with: datapack.densityFunctionRegistry)

            datapack.noiseRegistry.forEach() { (key, value) in
                var random = self.noiseSplitter.split(usingString: key.name)
                let low = random.nextLong()
                let high = random.nextLong()
                let noise = value.instantiate(seedLo: low, seedHi: high)
                self.registries.bakedNoiseRegistry.register(noise, forKey: key.convertType())
            }
        }

        try self.bakeDensityFunctions()
    }

    /// Convert the density functions to a usable format.
    /// Datapacks should not be added after this call.
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

        let baker = FullDensityFunctionBaker(registries: self.registries)
        try self.registries.densityFunctionRegistry.map { (key: RegistryKey<any DensityFunction>, value: any DensityFunction) in
            if baker.hasBeenBaked(atKey: key) { return value }
            return try value.bake(withBaker: baker)
        }
    }
}