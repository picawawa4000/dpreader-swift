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

    // let effects: BiomeEffects

    public init(
        hasPrecipitation: Bool,
        temperature: Double,
        temperatureModifier: TemperatureModifier = .none,
        downfall: Double,
        carvers: [String],
        features: [[String]],
        creatureSpawnProbability: Double? = nil,
        spawners: [String: [BiomeSpawnerEntry]],
        spawnCosts: [String: BiomeSpawnCost]
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
    }
}

public enum TemperatureModifier: String, Codable {
    case none = "none"
    case frozen = "frozen"
}

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

public struct BiomeSpawnCost: Codable {
    let energyBudget: Double
    let charge: Double

    private enum CodingKeys: String, CodingKey {
        case energyBudget = "energy_budget"
        case charge = "charge"
    }
}
