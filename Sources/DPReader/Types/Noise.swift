import Foundation
import TestVisible

/// Represents a definition of a noise.
@TestVisible(property: "testingAttributes") public final class NoiseDefinition: Codable {
    private let amplitudes: [Double]
    private let firstOctave: Int
    private var hashLow: UInt64? = nil, hashHigh: UInt64? = nil
    private var samplingSeed: WorldSeed? = nil

    public init(firstOctave: Int, amplitudes: [Double], forID id: RegistryKey<NoiseDefinition>) {
        // check that firstOctave < 0

        self.amplitudes = amplitudes
        self.firstOctave = firstOctave
        
        self.initHashes(forID: id)
    }

    public func initHashes(forID id: RegistryKey<NoiseDefinition>) {
        let hashBytes = id.name.bytes.md5()
        self.hashLow = hashBytes[0..<8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        self.hashHigh = hashBytes[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// Set this instance's sampling seed. Somewhat deprecated.
    /// - Parameter seed: The seed to use when calling `sample()` or `instantiate()`
    public func setSeed(to seed: WorldSeed) {
        self.samplingSeed = seed
    }

    /// Samples the noise. Prefer to use `instantiate()` if you have to sample the noise more than once.
    /// - Parameters:
    ///   - x: The x-coordinate to sample at.
    ///   - y: The y-coordinate to sample at.
    ///   - z: The z-coordinate to sample at.
    /// - Throws: If `setSeed(to:)` has not been called on this instance yet.
    /// - Returns: The return value of `DoublePerlinNoise.sample(x:y:z:)` with the given coordinates, using this configuration.
    public func sample(x: Double, y: Double, z: Double) throws -> Double {
        return try self.instantiate().sample(x: x, y: y, z: z)
    }

    /// Instantiates a new `DoublePerlinNoise` using this configuration and whatever seed was last passed to `setSeed`.
    /// - Throws: If `setSeed(to:)` has not been called on this instance yet.
    /// - Returns: A `DoublePerlinNoise` with this configuration.
    public func instantiate() throws -> DoublePerlinNoise {
        guard let seed = self.samplingSeed else {
            throw Errors.noSeed
        }
        return self.instantiate(forSeed: seed)
    }

    /// Instantiates a new `DoublePerlinNoise` using this seed.
    /// It is recommended to call `initHashes(forID:)` on this instance first
    /// (note that this is done by the data pack loader automatically).
    /// - Parameter seed: The seed to use when instantiating this noise.
    /// - Returns: A `DoublePerlinNoise` instance using the given seed.
    public func instantiate(forSeed seed: WorldSeed) -> DoublePerlinNoise {
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
    public func instantiate(seedLo: UInt64, seedHi: UInt64) -> DoublePerlinNoise {
        if (self.hashLow == nil) || (self.hashHigh == nil) {
            print("WARNING: Uninitialised hashes in NoiseDefinition. Treating them as 0.")
        }
        let lo = seedLo ^ (self.hashLow ?? 0)
        let hi = seedHi ^ (self.hashHigh ?? 0)
        var random = XoroshiroRandom(seedLo: lo, seedHi: hi)
        return DoublePerlinNoise(random: &random, firstOctave: self.firstOctave, amplitudes: self.amplitudes, useModernInitialization: true)
    }

    public func instantiateLegacy() throws -> DoublePerlinNoise {
        guard let seed = self.samplingSeed else {
            throw Errors.noSeed
        }
        return try self.instantiateLegacy(forSeed: seed)
    }

    /// Instantiates a new `DoublePerlinNoise` using this seed, using a legacy method.
    /// - Parameter seed: The seed to use when instantiating this noise.
    /// - Throws: 
    /// - Returns: 
    public func instantiateLegacy(forSeed seed: WorldSeed) throws -> DoublePerlinNoise {
        fatalError("Unimplemented function NoiseDefinition.instantiateLegacy(forSeed:)!")
        #warning("Unimplemented function NoiseDefinition.instantiateLegacy(forSeed:)!")
    }

    private enum CodingKeys: String, CodingKey {
        case amplitudes = "amplitudes"
        case firstOctave = "firstOctave"
        case amplitudeModifiers = "amplitude_modifiers"
        case baseOctave = "base_octave"
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if decoder.dpReaderPackFormat >= Version(major: 113, minor: 0) {
            self.amplitudes = try container.decode([Double].self, forKey: .amplitudeModifiers)
            self.firstOctave = try container.decode(Int.self, forKey: .baseOctave)
        } else {
            self.amplitudes = try container.decode([Double].self, forKey: .amplitudes)
            self.firstOctave = try container.decode(Int.self, forKey: .firstOctave)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if encoder.dpReaderPackFormat >= Version(major: 113, minor: 0) {
            try container.encode(amplitudes, forKey: .amplitudeModifiers)
            try container.encode(firstOctave, forKey: .baseOctave)
        } else {
            try container.encode(amplitudes, forKey: .amplitudes)
            try container.encode(firstOctave, forKey: .firstOctave)
        }
    }

    private enum Errors: Error {
        /// No hash was found (most likely because `initHashes(forId:)` was never called).
        case noHash
        /// No sampling seed was found (most likely because `setSeed(to:)` was never called).
        case noSeed
    }
}

/// ----- Noise (post 113.0) -----

/// Represents a definition of a noise.
@TestVisible(property: "testingAttributes") public final class ModernNoiseDefinition: Codable {
    private let octaves: [ModernDoublePerlinNoise.OctaveInfo]
    private let firstOctave, octaveCount: Int
    private let baseAmplitude: Double
    private let amplitudes: [Double]
    private let normalizationFactor: Double
    private let min, max: Double
    private var hashLow: UInt64? = nil, hashHigh: UInt64? = nil

    public init(firstOctave: Int, baseAmplitude: Double = 1.0, octaveCount: Int = 1, normalization: ModernNoiseNormalization = .enabled, amplitudes: [Double] = [], forID id: RegistryKey<NoiseDefinition>? = nil) {        
        self.firstOctave = firstOctave
        self.octaveCount = octaveCount
        self.baseAmplitude = baseAmplitude
        self.amplitudes = amplitudes

        var frequency = pow(2.0, Double(firstOctave))
        var amplitude = baseAmplitude
        if (normalization != .disabled) {
            amplitude = baseAmplitude * pow(0.5, Double(1 - octaveCount)) / pow(0.5, Double(-octaveCount) - 1.0)
        }
        var octaves = [ModernDoublePerlinNoise.OctaveInfo](repeating: ModernDoublePerlinNoise.OctaveInfo(index: Int.min, frequency: Double.nan, amplitude: Double.nan), count: octaveCount)
        var amplitudeSum = 0.0
        var variance = 0.0
        for i in 0..<octaveCount {
            let amplitudeModifier = amplitudes.isEmpty ? 1.0 : amplitudes[i]
            if amplitudeModifier != 0.0 {
                let realAmplitude = amplitudeModifier * amplitude
                octaves[i] = ModernDoublePerlinNoise.OctaveInfo(index: firstOctave + i, frequency: frequency, amplitude: realAmplitude)
                let absAmplitude = abs(realAmplitude)
                amplitudeSum += absAmplitude
                variance += absAmplitude * absAmplitude * 0.27022478 * 0.27022478
            }
            frequency *= 2.0
            amplitude *= 0.5
        }
        self.octaves = octaves
        variance = sqrt(variance) * sqrt(2.0)
        var normalizationFactor = amplitudeSum * 0.33333334 / variance
        if normalization == .legacy {
            var minOctave = Int.max
            var maxOctave = Int.min
            for i in 0..<octaveCount {
                if amplitudes[i] != 0.0 {
                    minOctave = minOctave > i ? i : minOctave
                    maxOctave = maxOctave < i ? i : maxOctave
                }
            }
            let baseFactor = baseAmplitude * 0.5 * 0.33333334
            let octaveGap = maxOctave - minOctave
            let factor = baseFactor / (0.1 * (1.0 + 1.0 / Double(octaveGap)))
            amplitudeSum *= factor / normalizationFactor
            normalizationFactor = factor
        }
        self.normalizationFactor = normalizationFactor
        self.min = -amplitudeSum * 0.33333334 * 6.0
        self.max = amplitudeSum * 0.33333334 * 6.0

        if let realId = id {
            self.initHashes(forID: realId)
        }
    }

    public func initHashes(forID id: RegistryKey<NoiseDefinition>) {
        let hashBytes = id.name.bytes.md5()
        self.hashLow = hashBytes[0..<8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        self.hashHigh = hashBytes[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// Instantiates a new `DoublePerlinNoise` using this seed.
    /// It is recommended to call `initHashes(forID:)` on this instance first
    /// (note that this is done by the data pack loader automatically).
    /// - Parameter seed: The seed to use when instantiating this noise.
    /// - Returns: A `DoublePerlinNoise` instance using the given seed.
    public func instantiate(forSeed seed: WorldSeed) -> ModernDoublePerlinNoise {
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
    public func instantiate(seedLo: UInt64, seedHi: UInt64) -> ModernDoublePerlinNoise {
        if (self.hashLow == nil) || (self.hashHigh == nil) {
            print("WARNING: Uninitialised hashes in NoiseDefinition. Treating them as 0.")
        }
        let lo = seedLo ^ (self.hashLow ?? 0)
        let hi = seedHi ^ (self.hashHigh ?? 0)
        var random: any Random = XoroshiroRandom(seedLo: lo, seedHi: hi)
        return ModernDoublePerlinNoise(fromRandom: &random, withOctaves: self.octaves, normalizationFactor: self.normalizationFactor)
    }

    /// Instantiate a new `ModernDoublePerlinNoise` set up for Nether generation
    /// (or for any dimension where `legacy_noise_settings` is set to `true`).
    /// - Parameter fromRandom: The RNG to use for generation.
    public func instantiateLegacy(fromRandom random: inout any Random) -> ModernDoublePerlinNoise {
        return ModernDoublePerlinNoise(fromRandom: &random, withLegacyAmplitudes: self.amplitudes, octaveCount: self.octaveCount, firstOctave: self.firstOctave, baseAmplitude: self.baseAmplitude, normalizationFactor: self.normalizationFactor)
    }

    private enum CodingKeys: String, CodingKey {
        case amplitudes = "amplitudes"
        case firstOctave = "firstOctave"
        case amplitudeModifiers = "amplitude_modifiers"
        case baseOctave = "base_octave"
        case baseAmplitude = "base_amplitude"
        case octaveCount = "octave_count"
        case normalize = "normalize"
    }

    public required convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        var amplitudes: [Double] = []
        var firstOctave: Int
        var octaveCount = 1
        var baseAmplitude: Double = 1.0
        var normalization: ModernNoiseNormalization = .enabled

        if decoder.dpReaderPackFormat >= Version(major: 113, minor: 0) {
            if container.contains(.amplitudeModifiers) { amplitudes = try container.decode([Double].self, forKey: .amplitudeModifiers) }
            firstOctave = try container.decode(Int.self, forKey: .baseOctave)
            if container.contains(.octaveCount) { octaveCount = try container.decode(Int.self, forKey: .octaveCount) }
            if container.contains(.baseAmplitude) { baseAmplitude = try container.decode(Double.self, forKey: .baseAmplitude) }
            if container.contains(.normalize) { normalization = try container.decode(ModernNoiseNormalization.self, forKey: .normalize) }
        } else {
            amplitudes = try container.decode([Double].self, forKey: .amplitudes)
            firstOctave = try container.decode(Int.self, forKey: .firstOctave)
            normalization = .legacy
        }
        
        self.init(firstOctave: firstOctave, baseAmplitude: baseAmplitude, octaveCount: octaveCount, normalization: normalization, amplitudes: amplitudes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if encoder.dpReaderPackFormat >= Version(major: 113, minor: 0) {
            try container.encode(self.amplitudes, forKey: .amplitudeModifiers)
            try container.encode(self.firstOctave, forKey: .baseOctave)
            try container.encode(self.octaveCount, forKey: .octaveCount)
            try container.encode(self.baseAmplitude, forKey: .baseAmplitude)
            try container.encode(self.amplitudes, forKey: .amplitudes)
        } else {
            try container.encode(self.amplitudes, forKey: .amplitudes)
            try container.encode(self.firstOctave, forKey: .firstOctave)
        }
    }

    private enum Errors: Error {
        /// No hash was found (most likely because `initHashes(forId:)` was never called).
        case noHash
        /// No sampling seed was found (most likely because `setSeed(to:)` was never called).
        case noSeed
    }
}

