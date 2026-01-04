import TestVisible

/// Represents a definition of a noise.
@TestVisible(property: "testingAttributes") final class NoiseDefinition: Codable {
    private let amplitudes: [Double]
    private let firstOctave: Int
    private var hashLow: UInt64? = nil, hashHigh: UInt64? = nil
    private var samplingSeed: WorldSeed? = nil

    init(firstOctave: Int, amplitudes: [Double], forID id: RegistryKey<NoiseDefinition>) {
        // check that firstOctave < 0

        self.amplitudes = amplitudes
        self.firstOctave = firstOctave
        
        self.initHashes(forID: id)
    }

    @inlinable func initHashes(forID id: RegistryKey<NoiseDefinition>) {
        let hashBytes = id.name.bytes.md5()
        self.hashLow = hashBytes[0..<8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        self.hashHigh = hashBytes[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    @inlinable func setSeed(to seed: WorldSeed) {
        self.samplingSeed = seed
    }

    /// Samples the noise. Prefer to use `instantiate()` if you have to sample the noise more than once.
    /// - Parameters:
    ///   - x: The x-coordinate to sample at.
    ///   - y: The y-coordinate to sample at.
    ///   - z: The z-coordinate to sample at.
    /// - Returns: The return value of `DoublePerlinNoise.sample(x:y:z:)` with the given coordinates, using this configuration.
    func sample(x: Double, y: Double, z: Double) throws -> Double {
        return try self.instantiate().sample(x: x, y: y, z: z)
    }

    /// Instantiates a new `DoublePerlinNoise` using this configuration and whatever seed was last passed to `setSeed`.
    /// - Returns: A `DoublePerlinNoise` with this configuration.
    func instantiate() throws -> DoublePerlinNoise {
        guard let seed = self.samplingSeed else {
            throw Errors.noSeed
        }
        return try self.instantiate(forSeed: seed)
    }

    /// Instantiates a new `DoublePerlinNoise` using this seed.
    /// - Parameter seed: The seed to use when instantiating this noise.
    /// - Throws: 
    /// - Returns: 
    func instantiate(forSeed seed: WorldSeed) throws -> DoublePerlinNoise {
        var random = XoroshiroRandom(seed: seed)
        let lo = random.nextLong()
        let hi = random.nextLong()
        return self.instantiate(seedLo: lo, seedHi: hi)
    }

    /// Instantiate a new `DoublePerlinNoise` based on precomputed low and high scrambling bits.
    /// If you don't know what that means, use `instantiate(forSeed:)` instead.
    /// - Parameters:
    ///   - seedLo: The low scrambling bits. Should be the result of the first call to `XoroshiroRandom`.
    ///   - seedHi: The high scrambling bits. Should be the result of the second call to `XoroshiroRandom`.
    /// - Returns: A new `DoublePerlinNoise` instantiated based on the given scrambling bits.
    func instantiate(seedLo: UInt64, seedHi: UInt64) -> DoublePerlinNoise {
        if (self.hashLow == nil) || (self.hashHigh == nil) {
            print("WARNING: Uninitialised hashes in NoiseDefinition. Treating them as 0.")
        }
        let lo = seedLo ^ (self.hashLow ?? 0)
        let hi = seedHi ^ (self.hashHigh ?? 0)
        var random = XoroshiroRandom(seedLo: lo, seedHi: hi)
        return DoublePerlinNoise(random: &random, firstOctave: self.firstOctave, amplitudes: self.amplitudes, useModernInitialization: true)
    }

    func instantiateLegacy() throws -> DoublePerlinNoise {
        guard let seed = self.samplingSeed else {
            throw Errors.noSeed
        }
        return try self.instantiateLegacy(forSeed: seed)
    }

    /// Instantiates a new `DoublePerlinNoise` using this seed, using a legacy method.
    /// - Parameter seed: The seed to use when instantiating this noise.
    /// - Throws: 
    /// - Returns: 
    func instantiateLegacy(forSeed seed: WorldSeed) throws -> DoublePerlinNoise {
        fatalError("Unimplemented function NoiseDefinition::instantiateLegacy!")
        unreachable()
    }

    private enum CodingKeys: String, CodingKey {
        case amplitudes = "amplitudes"
        case firstOctave = "firstOctave"
    }

    private enum Errors: Error {
        /// No hash was found (most likely because `initHashes(forId:)` was never called).
        case noHash
        /// No sampling seed was found (most likely because `setSeed(to:)` was never called).
        case noSeed
    }
}
