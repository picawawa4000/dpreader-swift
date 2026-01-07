/// Stores all of the registries needed for world generation.
final class WorldGenerationRegistries {
    var densityFunctionRegistry = Registry<DensityFunction>()
    var bakedNoiseRegistry = Registry<DoublePerlinNoise>()
}

/// A density function baker that does all baking steps except for resolving references.
final class NoiseDensityFunctionBaker: DensityFunctionBaker {
    private let registries: WorldGenerationRegistries

    init(registries: WorldGenerationRegistries) {
        self.registries = registries
    }

    func bake(noise: any DensityFunctionNoise) throws -> BakedNoise {
        guard let sampler = self.registries.bakedNoiseRegistry.get(noise.key.convertType()) else {
            throw BakingErrors.noNoiseAtKey(noise.key.name)
        }
        return BakedNoise(fromKey: noise.key, withSampler: sampler)
    }

    func bake(referenceDensityFunction: ReferenceDensityFunction) throws -> any DensityFunction {
        return referenceDensityFunction
    }
}

/// A density function baker that only resolves registry references.
final class ReferenceResolvingDensityFunctionBaker: DensityFunctionBaker {
    private let densityFunctionRegistry: Registry<DensityFunction>

    init(usingDensityFunctionRegistry registry: Registry<DensityFunction>) {
        self.densityFunctionRegistry = registry
    }

    func bake(noise: any DensityFunctionNoise) throws -> BakedNoise {
        if noise is BakedNoise { return noise as! BakedNoise }
        throw BakingErrors.noiseUnbakedDuringReferenceResolution(noise.key.name)
    }

    func bake(referenceDensityFunction reference: ReferenceDensityFunction) throws -> any DensityFunction {
        // Unwrap the reference.
        guard let returnFunction = self.densityFunctionRegistry.get(reference.targetKey) else {
            throw BakingErrors.noDensityFunctionAtKey(reference.targetKey.name)
        }
        // Also bake the referenced function (which might lead to some functions being baked multiple times, but it's fine).
        return try returnFunction.bake(withBaker: self)
    }
}

private enum BakingErrors: Error {
    case noDensityFunctionAtKey(String)
    case noNoiseAtKey(String)
    case noiseUnbakedDuringReferenceResolution(String)
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
        // To fix this issue, there are two main options.
        // The first option is to separate the baking process into two stages, such that references are resolved
        // before (or after) all other baking occurs. This will ensure that the full tree is walked, although with
        // a performance overhead since the tree has to be walked multiple times.
        // The second option is to only bake density functions that are required by the world's noise settings.
        // While this has the advantage of performance, it is technically challenging to implement for a number of reasons
        // and so is left unimplemented here.
        // This function is an implementation of the first option with the reference resolution stage occurring after
        // the main baking stage.

        let noiseBaker = NoiseDensityFunctionBaker(registries: self.registries)
        try self.registries.densityFunctionRegistry.map { (key: RegistryKey<any DensityFunction>, value: any DensityFunction) in
            return try value.bake(withBaker: noiseBaker)
        }

        let refBaker = ReferenceResolvingDensityFunctionBaker(usingDensityFunctionRegistry: self.registries.densityFunctionRegistry)
        try self.registries.densityFunctionRegistry.map { (key: RegistryKey<any DensityFunction>, value: any DensityFunction) in
            return try value.bake(withBaker: refBaker)
        }
    }
}