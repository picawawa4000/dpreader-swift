public final class Dimension: Codable {
    let type: String
    let generator: DimensionGenerator

    public init(type: String, generator: DimensionGenerator) {
        self.type = type
        self.generator = generator
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.type = addDefaultNamespace(try container.decode(String.self, forKey: .type))
        self.generator = try container.decode(DimensionGeneratorInitializer.self, forKey: .generator).value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.type, forKey: .type)
        try container.encode(DimensionGeneratorInitializer(self.generator), forKey: .generator)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case generator = "generator"
    }
}

public protocol DimensionGenerator: Codable {
}

private enum DimensionGeneratorTypeKey: String, CodingKey {
    case type
}

public struct DimensionGeneratorInitializer: Codable {
    let value: DimensionGenerator

    public init(_ value: DimensionGenerator) { self.value = value }

    public init(from decoder: Decoder) throws {
        self.value = try decodeDimensionGenerator(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try encodeDimensionGenerator(value, to: encoder)
    }
}

private func decodeDimensionGenerator(from decoder: Decoder) throws -> DimensionGenerator {
    let container = try decoder.container(keyedBy: DimensionGeneratorTypeKey.self)
    let type = addDefaultNamespace(try container.decode(String.self, forKey: .type))
    switch type {
    case "minecraft:noise":
        return try NoiseDimensionGenerator(from: decoder)
    case "minecraft:flat":
        return try FlatDimensionGenerator(from: decoder)
    case "minecraft:debug":
        return DebugDimensionGenerator()
    case "minecraft:void":
        return try VoidDimensionGenerator(from: decoder)
    default:
        throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown dimension generator type: \(type)")
    }
}

private func encodeDimensionGenerator(_ generator: DimensionGenerator, to encoder: Encoder) throws {
    switch generator {
    case let value as NoiseDimensionGenerator:
        try value.encode(to: encoder)
    case let value as FlatDimensionGenerator:
        try value.encode(to: encoder)
    case let value as DebugDimensionGenerator:
        try value.encode(to: encoder)
    case let value as VoidDimensionGenerator:
        try value.encode(to: encoder)
    default:
        let context = EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported DimensionGenerator type")
        throw EncodingError.invalidValue(generator, context)
    }
}

public struct NoiseDimensionGenerator: DimensionGenerator {
    let biomeSource: BiomeSource
    let settings: String

    public init(biomeSource: BiomeSource, settings: String) {
        self.biomeSource = biomeSource
        self.settings = settings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(String.self, forKey: .type)
        self.settings = addDefaultNamespace(try container.decode(String.self, forKey: .settings))
        self.biomeSource = try container.decode(BiomeSourceInitializer.self, forKey: .biomeSource).value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:noise", forKey: .type)
        try container.encode(self.settings, forKey: .settings)
        try container.encode(BiomeSourceInitializer(self.biomeSource), forKey: .biomeSource)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case settings = "settings"
        case biomeSource = "biome_source"
    }
}

public struct FlatDimensionGenerator: DimensionGenerator {
    let settings: FlatGeneratorSettings

    public init(settings: FlatGeneratorSettings) {
        self.settings = settings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(String.self, forKey: .type)
        self.settings = try container.decode(FlatGeneratorSettings.self, forKey: .settings)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:flat", forKey: .type)
        try container.encode(self.settings, forKey: .settings)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case settings = "settings"
    }
}

public struct DebugDimensionGenerator: DimensionGenerator {
    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(String.self, forKey: .type)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:debug", forKey: .type)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
    }
}

public struct VoidDimensionGenerator: DimensionGenerator {
    let biomeSource: BiomeSource?

    public init(biomeSource: BiomeSource? = nil) {
        self.biomeSource = biomeSource
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(String.self, forKey: .type)
        self.biomeSource = try? container.decode(BiomeSourceInitializer.self, forKey: .biomeSource).value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:void", forKey: .type)
        if let biomeSource {
            try container.encode(BiomeSourceInitializer(biomeSource), forKey: .biomeSource)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case biomeSource = "biome_source"
    }
}

public struct FlatGeneratorSettings: Codable {
    let biome: String
    let layers: [FlatLayer]
    let features: Bool
    let lakes: Bool
    // let structures: FlatStructures

    public init(biome: String, layers: [FlatLayer], features: Bool = true, lakes: Bool = false) {
        self.biome = biome
        self.layers = layers
        self.features = features
        self.lakes = lakes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.biome = addDefaultNamespace(try container.decode(String.self, forKey: .biome))
        self.layers = try container.decode([FlatLayer].self, forKey: .layers)
        self.features = (try? container.decode(Bool.self, forKey: .features)) ?? true
        self.lakes = (try? container.decode(Bool.self, forKey: .lakes)) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.biome, forKey: .biome)
        try container.encode(self.layers, forKey: .layers)
        try container.encode(self.features, forKey: .features)
        try container.encode(self.lakes, forKey: .lakes)
    }

    private enum CodingKeys: String, CodingKey {
        case biome = "biome"
        case layers = "layers"
        case features = "features"
        case lakes = "lakes"
    }
}

public struct FlatLayer: Codable {
    let height: Int
    let block: String

    public init(height: Int, block: String) {
        self.height = height
        self.block = block
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.height = try container.decode(Int.self, forKey: .height)
        self.block = addDefaultNamespace(try container.decode(String.self, forKey: .block))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.height, forKey: .height)
        try container.encode(self.block, forKey: .block)
    }

    private enum CodingKeys: String, CodingKey {
        case height = "height"
        case block = "block"
    }
}

public protocol BiomeSource: Codable {
}

private enum BiomeSourceTypeKey: String, CodingKey {
    case type
}

public struct BiomeSourceInitializer: Codable {
    let value: BiomeSource

    public init(_ value: BiomeSource) { self.value = value }

    public init(from decoder: Decoder) throws {
        self.value = try decodeBiomeSource(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        try encodeBiomeSource(value, to: encoder)
    }
}

private func decodeBiomeSource(from decoder: Decoder) throws -> BiomeSource {
    let container = try decoder.container(keyedBy: BiomeSourceTypeKey.self)
    let type = addDefaultNamespace(try container.decode(String.self, forKey: .type))
    switch type {
    case "minecraft:fixed":
        return try FixedBiomeSource(from: decoder)
    case "minecraft:checkerboard":
        return try CheckerboardBiomeSource(from: decoder)
    case "minecraft:multi_noise":
        return try MultiNoiseBiomeSource(from: decoder)
    case "minecraft:the_end":
        return TheEndBiomeSource()
    default:
        throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown biome source type: \(type)")
    }
}

private func encodeBiomeSource(_ biomeSource: BiomeSource, to encoder: Encoder) throws {
    switch biomeSource {
    case let value as FixedBiomeSource:
        try value.encode(to: encoder)
    case let value as CheckerboardBiomeSource:
        try value.encode(to: encoder)
    case let value as MultiNoiseBiomeSource:
        try value.encode(to: encoder)
    case let value as TheEndBiomeSource:
        try value.encode(to: encoder)
    default:
        let context = EncodingError.Context(codingPath: encoder.codingPath, debugDescription: "Unsupported BiomeSource type")
        throw EncodingError.invalidValue(biomeSource, context)
    }
}

public struct FixedBiomeSource: BiomeSource {
    let biome: String

    public init(biome: String) { self.biome = biome }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(String.self, forKey: .type)
        self.biome = addDefaultNamespace(try container.decode(String.self, forKey: .biome))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:fixed", forKey: .type)
        try container.encode(self.biome, forKey: .biome)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case biome = "biome"
    }
}

public struct CheckerboardBiomeSource: BiomeSource {
    let biomes: [String]
    let scale: Int

    public init(biomes: [String], scale: Int = 2) {
        self.biomes = biomes
        self.scale = scale
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(String.self, forKey: .type)
        self.biomes = try container.decode([String].self, forKey: .biomes).map { addDefaultNamespace($0) }
        self.scale = (try? container.decode(Int.self, forKey: .scale)) ?? 2
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:checkerboard", forKey: .type)
        try container.encode(self.biomes, forKey: .biomes)
        try container.encode(self.scale, forKey: .scale)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case biomes = "biomes"
        case scale = "scale"
    }
}

public struct MultiNoiseBiomeSource: BiomeSource {
    let preset: String?
    let biomes: [MultiNoiseBiomeSourceBiome]?

    public init(preset: String) {
        self.preset = addDefaultNamespace(preset)
        self.biomes = nil
    }

    public init(biomes: [MultiNoiseBiomeSourceBiome]) {
        self.preset = nil
        self.biomes = biomes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(String.self, forKey: .type)
        self.preset = (try? container.decode(String.self, forKey: .preset)).map { addDefaultNamespace($0) }
        self.biomes = try? container.decode([MultiNoiseBiomeSourceBiome].self, forKey: .biomes)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:multi_noise", forKey: .type)
        if let preset {
            try container.encode(preset, forKey: .preset)
        }
        if let biomes {
            try container.encode(biomes, forKey: .biomes)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case preset = "preset"
        case biomes = "biomes"
    }
}

public struct TheEndBiomeSource: BiomeSource {
    public init() {}

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decode(String.self, forKey: .type)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("minecraft:the_end", forKey: .type)
    }

    private enum CodingKeys: String, CodingKey {
        case type = "type"
    }
}

public struct MultiNoiseBiomeSourceBiome: Codable {
    let biome: String
    let parameters: MultiNoiseBiomeSourceParameters

    public init(biome: String, parameters: MultiNoiseBiomeSourceParameters) {
        self.biome = biome
        self.parameters = parameters
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.biome = addDefaultNamespace(try container.decode(String.self, forKey: .biome))
        self.parameters = try container.decode(MultiNoiseBiomeSourceParameters.self, forKey: .parameters)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.biome, forKey: .biome)
        try container.encode(self.parameters, forKey: .parameters)
    }

    private enum CodingKeys: String, CodingKey {
        case biome = "biome"
        case parameters = "parameters"
    }
}

public struct MultiNoiseBiomeSourceParameters: Codable {
    let temperature: BiomeParameterRange
    let humidity: BiomeParameterRange
    let continentalness: BiomeParameterRange
    let erosion: BiomeParameterRange
    let depth: BiomeParameterRange
    let weirdness: BiomeParameterRange
    let offset: BiomeParameterRange

    public init(
        temperature: BiomeParameterRange,
        humidity: BiomeParameterRange,
        continentalness: BiomeParameterRange,
        erosion: BiomeParameterRange,
        depth: BiomeParameterRange,
        weirdness: BiomeParameterRange,
        offset: BiomeParameterRange
    ) {
        self.temperature = temperature
        self.humidity = humidity
        self.continentalness = continentalness
        self.erosion = erosion
        self.depth = depth
        self.weirdness = weirdness
        self.offset = offset
    }

    private enum CodingKeys: String, CodingKey {
        case temperature = "temperature"
        case humidity = "humidity"
        case continentalness = "continentalness"
        case erosion = "erosion"
        case depth = "depth"
        case weirdness = "weirdness"
        case offset = "offset"
    }
}

public struct BiomeParameterRange: Codable {
    let min: Double
    let max: Double

    public init(value: Double) {
        self.min = value
        self.max = value
    }

    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let value = try? single.decode(Double.self) {
            self.min = value
            self.max = value
            return
        }
        let container = try decoder.singleValueContainer()
        let range = try container.decode([Double].self)
        if range.count != 2 {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Expected a single value or two-element array for biome parameter range")
        }
        self.min = range[0]
        self.max = range[1]
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        if self.min == self.max {
            try container.encode(self.min)
        } else {
            try container.encode([self.min, self.max])
        }
    }
}
