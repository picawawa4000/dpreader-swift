/// Stores all of the registries needed for world generation.
internal final class WorldGenerationRegistries {
    var densityFunctionRegistry = Registry<DensityFunction>()
    var bakedNoiseRegistry = Registry<DoublePerlinNoise>()
}

/// A density function baker that resolves registry references.
final class ReferenceResolvingDensityFunctionBaker: DensityFunctionBaker {
    private let registries: WorldGenerationRegistries

    init(usingRegistries registries: WorldGenerationRegistries) {
        self.registries = registries
    }

    func bake(noise: any DensityFunctionNoise) throws -> BakedNoise {
        // Set the sampler up.
        guard let sampler = self.registries.bakedNoiseRegistry.get(noise.key.convertType()) else {
            throw BakingErrors.noNoiseAtKey(noise.key.name)
        }
        return BakedNoise(fromKey: noise.key, withSampler: sampler)
    }

    func bake(referenceDensityFunction reference: ReferenceDensityFunction) throws -> any DensityFunction {
        // Unwrap the reference.
        guard let returnFunction = self.registries.densityFunctionRegistry.get(reference.targetKey) else {
            throw BakingErrors.noDensityFunctionAtKey(reference.targetKey.name)
        }
        // Also bake the referenced function (which might lead to some functions being baked multiple times, but it's fine).
        return try returnFunction.bake(withBaker: self)
    }

    private enum BakingErrors: Error {
        case noDensityFunctionAtKey(String)
        case noNoiseAtKey(String)
    }
}

/// The thing that actually generates worlds.
final class WorldGenerator {
    private let worldSeed: WorldSeed
    private let noiseSplitter: any RandomSplitter
    private var registries = WorldGenerationRegistries()

    init(withWorldSeed seed: WorldSeed) {
        self.worldSeed = seed
        var random = XoroshiroRandom(seed: seed)
        self.noiseSplitter = random.nextSplitter()
    }

    /// Add a data pack to this world generator.
    /// - Parameter datapack: The datapack to add. Cannot be removed without resetting the entire world generator.
    func addDataPack(_ datapack: DataPack) {
        self.registries.densityFunctionRegistry.mergeDown(with: datapack.densityFunctionRegistry)

        datapack.noiseRegistry.map() { (key, value) in
            var random = self.noiseSplitter.split(usingString: key.name)
            let low = random.nextLong()
            let high = random.nextLong()
            let noise = value.instantiate(seedLo: low, seedHi: high)
            self.registries.bakedNoiseRegistry.register(noise, forKey: key.convertType())
        }
    }

    /// Convert the density functions to a usable format.
    /// Datapacks should not be added after this call.
    func bakeDensityFunctions() {
        // The trick here is that, if every density function in the registries is baked in an arbitrary order,
        // some references may be resolved before the function they refer to has been baked, which will result
        // in an unbaked function in the hierarchy.
        // To fix this issue, there are two main options.
        // The first option is to separate the baking process into two stages, such that references are resolved
        // before all other baking occurs. This will ensure that the full tree is walked, although with a performance
        // overhead since the tree has to be walked multiple times.
        // The second option is to only bake density functions that are required by the world's noise settings.
        // While this has the advantage of performance, it is technically challenging to implement for a number of reasons
        // and so is left unimplemented here.
    }
}