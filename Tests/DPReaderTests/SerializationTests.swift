import Foundation
import Testing
@testable import DPReader

fileprivate enum Errors: Error {
    case dimensionWrongType(String)
}

@Test func testNoiseDefinition() async throws {
    let json = """
        {
            "amplitudes": [1.5, 1.0],
            "firstOctave": -10
        }
    """.data(using: String.Encoding.utf8)!
    let decoder = JSONDecoder()
    let value = try decoder.decode(NoiseDefinition.self, from: json)
    #expect(value.testingAttributes.amplitudes == [1.5, 1.0] && value.testingAttributes.firstOctave == -10)
}

@Test func testBiomeCoding() async throws {
    let json = """
        {
            "has_precipitation": true,
            "temperature": 0.8,
            "temperature_modifier": "none",
            "downfall": 0.4,
            "carvers": [
                "minecraft:cave",
                "minecraft:canyon"
            ],
            "features": [
                ["minecraft:lake_water"],
                ["minecraft:forest_rock"]
            ],
            "creature_spawn_probability": 0.07,
            "spawners": {
                "creature": [
                    {
                        "type": "minecraft:sheep",
                        "weight": 12,
                        "minCount": 2,
                        "maxCount": 4
                    }
                ]
            },
            "spawn_costs": {
                "minecraft:sheep": {
                    "energy_budget": 1.0,
                    "charge": 0.2
                }
            }
        }
    """.data(using: String.Encoding.utf8)!
    let decoder = JSONDecoder()
    let biome = try decoder.decode(Biome.self, from: json)

    #expect(biome.hasPrecipitation == true)
    #expect(biome.temperature == 0.8)
    #expect(biome.temperatureModifier == .none)
    #expect(biome.downfall == 0.4)
    #expect(biome.carvers[0] == "minecraft:cave")
    #expect(biome.carvers[1] == "minecraft:canyon")
    #expect(biome.features.count == 2)
    #expect(biome.features[0] == ["minecraft:lake_water"])
    #expect(biome.creatureSpawnProbability == 0.07)
    #expect(biome.spawners["creature"]?.first?.type == "minecraft:sheep")
    #expect(biome.spawnCosts["minecraft:sheep"]?.energyBudget == 1.0)

    let encoder = JSONEncoder()
    let roundTrip = try decoder.decode(Biome.self, from: encoder.encode(biome))
    #expect(roundTrip.temperature == 0.8)
    #expect(roundTrip.features[1] == ["minecraft:forest_rock"])
}

@Test func testDimensionCoding() async throws {
    let json = """
        {
            "type": "minecraft:overworld",
            "generator": {
                "type": "minecraft:noise",
                "settings": "minecraft:overworld",
                "biome_source": {
                    "type": "minecraft:multi_noise",
                    "preset": "minecraft:overworld"
                }
            }
        }
    """.data(using: String.Encoding.utf8)!
    let decoder = JSONDecoder()
    let dimension = try decoder.decode(Dimension.self, from: json)

    #expect(dimension.type == "minecraft:overworld")
    guard let generator = dimension.generator as? NoiseDimensionGenerator else {
        throw Errors.dimensionWrongType("NoiseDimensionGenerator")
    }
    #expect(generator.settings == "minecraft:overworld")
    guard let biomeSource = generator.biomeSource as? MultiNoiseBiomeSource else {
        throw Errors.dimensionWrongType("MultiNoiseBiomeSource")
    }
    #expect(biomeSource.preset == "minecraft:overworld")

    let encoder = JSONEncoder()
    let roundTrip = try decoder.decode(Dimension.self, from: encoder.encode(dimension))
    #expect(roundTrip.type == "minecraft:overworld")
    #expect((roundTrip.generator as? NoiseDimensionGenerator)?.settings == "minecraft:overworld")
}
