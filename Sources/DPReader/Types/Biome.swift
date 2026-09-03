/// A biome definition decoded from `worldgen/biome` data-pack JSON.
public final class Biome: Codable {
    let hasPrecipitation: Bool
    let temperature: Double
    let temperatureModifier: TemperatureModifier
    let downfall: Double

    let carvers: [String]
    let features: [[String]]
    let creatureSpawnProbability: Double?
    let spawners: [String: [BiomeSpawnerEntry]]
    let spawnCosts: [String: BiomeSpawnCost]

    let effects: JSONValue

    public init(
        hasPrecipitation: Bool,
        temperature: Double,
        temperatureModifier: TemperatureModifier = .none,
        downfall: Double,
        carvers: [String],
        features: [[String]],
        creatureSpawnProbability: Double? = nil,
        spawners: [String: [BiomeSpawnerEntry]],
        spawnCosts: [String: BiomeSpawnCost],
        effects: JSONValue = .object([:])
    ) {
        self.hasPrecipitation = hasPrecipitation
        self.temperature = temperature
        self.temperatureModifier = temperatureModifier
        self.downfall = downfall
        self.carvers = carvers
        self.features = features
        self.creatureSpawnProbability = creatureSpawnProbability
        self.spawners = spawners
        self.spawnCosts = spawnCosts
        self.effects = effects
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hasPrecipitation = try container.decode(Bool.self, forKey: .hasPrecipitation)
        self.temperature = try container.decode(Double.self, forKey: .temperature)
        if container.contains(.temperatureModifier) {
            self.temperatureModifier = try container.decode(TemperatureModifier.self, forKey: .temperatureModifier)
        } else {
            self.temperatureModifier = .none
        }
        self.downfall = try container.decode(Double.self, forKey: .downfall)
        self.carvers = (try? container.decode([String].self, forKey: .carvers)) ?? []
        self.features = (try? container.decode([[String]].self, forKey: .features)) ?? []
        self.creatureSpawnProbability = try? container.decode(Double.self, forKey: .creatureSpawnProbability)
        self.spawners = (try? container.decode([String: [BiomeSpawnerEntry]].self, forKey: .spawners)) ?? [:]
        self.spawnCosts = (try? container.decode([String: BiomeSpawnCost].self, forKey: .spawnCosts)) ?? [:]
        self.effects = try container.decodeIfPresent(JSONValue.self, forKey: .effects) ?? .object([:])
        try Self.validateEffects(effects, packFormat: decoder.dpReaderPackFormat, codingPath: decoder.codingPath + [CodingKeys.effects])
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.hasPrecipitation, forKey: .hasPrecipitation)
        try container.encode(self.temperature, forKey: .temperature)
        try container.encode(self.temperatureModifier, forKey: .temperatureModifier)
        try container.encode(self.downfall, forKey: .downfall)
        try container.encode(self.carvers, forKey: .carvers)
        try container.encode(self.features, forKey: .features)
        try container.encodeIfPresent(self.creatureSpawnProbability, forKey: .creatureSpawnProbability)
        try container.encode(self.spawners, forKey: .spawners)
        try container.encode(self.spawnCosts, forKey: .spawnCosts)
        try container.encode(self.effects, forKey: .effects)
    }

    private enum CodingKeys: String, CodingKey {
        case hasPrecipitation = "has_precipitation"
        case temperature = "temperature"
        case temperatureModifier = "temperature_modifier"
        case downfall = "downfall"
        case carvers = "carvers"
        case features = "features"
        case creatureSpawnProbability = "creature_spawn_probability"
        case spawners = "spawners"
        case spawnCosts = "spawn_costs"
        case effects = "effects"
    }

    private static func validateEffects(_ effects: JSONValue, packFormat: Version, codingPath: [CodingKey]) throws {
        guard case .object(let object) = effects else {
            throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Biome effects must be an object"))
        }
        if packFormat < Version(major: 68, minor: 0), object["dry_foliage_color"] != nil {
            throw DecodingError.dataCorrupted(
                .init(codingPath: codingPath, debugDescription: "dry_foliage_color requires pack format 68.0 or newer")
            )
        }
        for key in ["water_color", "water_fog_color", "fog_color", "sky_color", "foliage_color", "dry_foliage_color", "grass_color"] {
            guard let color = object[key] else { continue }
            if packFormat < Version(major: 92, minor: 0) {
                guard color.intValue != nil else {
                    throw DecodingError.dataCorrupted(
                        .init(codingPath: codingPath, debugDescription: "Biome effect \(key) must be an integer before pack format 92.0")
                    )
                }
            } else {
                let valid: Bool
                switch color {
                case .integer:
                    valid = true
                case .string(let value):
                    valid = value.count == 7 && value.first == "#" && value.dropFirst().allSatisfy(\.isHexDigit)
                case .array(let values):
                    valid = values.count == 3 && values.allSatisfy { value in
                        guard let component = value.doubleValue else { return false }
                        return component >= 0 && component <= 1
                    }
                default:
                    valid = false
                }
                guard valid else {
                    throw DecodingError.dataCorrupted(
                        .init(codingPath: codingPath, debugDescription: "Biome effect \(key) must be an RGB integer, #rrggbb string, or three-component float array")
                    )
                }
            }
        }
    }
}

/// An optional transformation applied to a biome's base temperature.
public enum TemperatureModifier: String, Codable {
    case none = "none"
    case frozen = "frozen"
}

/// A weighted mob-spawn entry in a biome definition.
public struct BiomeSpawnerEntry: Codable {
    let type: String
    let weight: Int
    let minCount: Int
    let maxCount: Int

    private enum CodingKeys: String, CodingKey {
        case type = "type"
        case weight = "weight"
        case minCount = "minCount"
        case maxCount = "maxCount"
    }
}

/// The spawn-density budget and charge assigned to one entity type in a biome.
public struct BiomeSpawnCost: Codable {
    let energyBudget: Double
    let charge: Double

    private enum CodingKeys: String, CodingKey {
        case energyBudget = "energy_budget"
        case charge = "charge"
    }
}
