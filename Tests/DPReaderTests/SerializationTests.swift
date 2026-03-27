import Foundation
import Testing
@testable import DPReader

fileprivate enum Errors: Error {
    case dimensionWrongType(String)
    case structureWrongType(String)
    case structurePlacementWrongType(String)
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

@Test func testStructureCoding() async throws {
    let json = """
        {
            "type": "minecraft:jigsaw",
            "biomes": "#test:has_structure/trial_chambers",
            "dimension_padding": 10,
            "liquid_settings": "ignore_waterlogging",
            "max_distance_from_center": 116,
            "pool_aliases": [
                {
                    "type": "minecraft:random_group",
                    "groups": [
                        {
                            "data": [
                                {
                                    "type": "minecraft:direct",
                                    "alias": "test:spawner/contents/ranged",
                                    "target": "test:spawner/ranged/skeleton"
                                }
                            ],
                            "weight": 1
                        }
                    ]
                },
                {
                    "type": "minecraft:random",
                    "alias": "test:spawner/contents/melee",
                    "targets": [
                        {
                            "data": "test:spawner/melee/zombie",
                            "weight": 1
                        },
                        {
                            "data": "test:spawner/melee/husk",
                            "weight": 1
                        }
                    ]
                }
            ],
            "size": 20,
            "spawn_overrides": {
                "monster": {
                    "bounding_box": "piece",
                    "spawns": []
                }
            },
            "start_height": {
                "type": "minecraft:uniform",
                "max_inclusive": {
                    "absolute": -20
                },
                "min_inclusive": {
                    "absolute": -40
                }
            },
            "start_pool": "test:trial_chambers/chamber/end",
            "step": "underground_structures",
            "terrain_adaptation": "encapsulate",
            "use_expansion_hack": false
        }
    """.data(using: String.Encoding.utf8)!
    let decoder = JSONDecoder()
    let structure = try decoder.decode(Structure.self, from: json)

    #expect(structure.type == "minecraft:jigsaw")
    #expect(structure.biomes == .tagID("test:has_structure/trial_chambers"))
    #expect(structure.terrainAdaptation == .encapsulate)
    guard case .jigsaw(let settings) = structure.settings else {
        throw Errors.structureWrongType("JigsawStructureSettings")
    }
    #expect(settings.dimensionPadding == 10)
    #expect(settings.liquidSettings == "ignore_waterlogging")
    #expect(settings.startPool == "test:trial_chambers/chamber/end")
    #expect(settings.startHeight == .uniform(minInclusive: .absolute(-40), maxInclusive: .absolute(-20)))
    #expect(settings.poolAliases?.count == 2)

    let encoder = JSONEncoder()
    let roundTripData = try encoder.encode(structure)
    let roundTrip = try decoder.decode(Structure.self, from: roundTripData)
    #expect(roundTrip.type == "minecraft:jigsaw")
    #expect(roundTrip.biomes == .tagID("test:has_structure/trial_chambers"))
    guard case .jigsaw(let roundTripSettings) = roundTrip.settings else {
        throw Errors.structureWrongType("JigsawStructureSettings")
    }
    #expect(roundTripSettings.startPool == "test:trial_chambers/chamber/end")
    #expect(roundTripSettings.poolAliases?.count == 2)
}

@Test func testStructureSetCoding() async throws {
    let randomSpreadJson = """
        {
            "placement": {
                "type": "minecraft:random_spread",
                "exclusion_zone": {
                    "chunk_count": 10,
                    "other_set": "test:villages"
                },
                "frequency": 0.2,
                "frequency_reduction_method": "legacy_type_1",
                "locate_offset": [9, 0, 9],
                "salt": 165745296,
                "separation": 8,
                "spacing": 32
            },
            "structures": [
                {
                    "structure": "test:pillager_outpost",
                    "weight": 1
                }
            ]
        }
    """.data(using: String.Encoding.utf8)!
    let concentricRingsJson = """
        {
            "placement": {
                "type": "minecraft:concentric_rings",
                "count": 128,
                "distance": 32,
                "preferred_biomes": "#test:stronghold_biased_to",
                "salt": 0,
                "spread": 3
            },
            "structures": [
                {
                    "structure": "test:stronghold",
                    "weight": 1
                }
            ]
        }
    """.data(using: String.Encoding.utf8)!
    let decoder = JSONDecoder()

    let randomSpread = try decoder.decode(StructureSet.self, from: randomSpreadJson)
    guard case .randomSpread(let randomPlacement) = randomSpread.placement else {
        throw Errors.structurePlacementWrongType("RandomSpreadStructurePlacement")
    }
    #expect(randomPlacement.frequency == 0.2)
    #expect(randomPlacement.frequencyReductionMethod == .legacyType1)
    #expect(randomPlacement.locateOffset == PosInt3D(x: 9, y: 0, z: 9))
    #expect(randomPlacement.exclusionZone?.otherSet == "test:villages")
    #expect(randomSpread.structures.first?.structure == "test:pillager_outpost")

    let concentricRings = try decoder.decode(StructureSet.self, from: concentricRingsJson)
    guard case .concentricRings(let ringsPlacement) = concentricRings.placement else {
        throw Errors.structurePlacementWrongType("ConcentricRingsStructurePlacement")
    }
    #expect(ringsPlacement.count == 128)
    #expect(ringsPlacement.preferredBiomes == .tagID("test:stronghold_biased_to"))

    let encoder = JSONEncoder()
    let roundTrip = try decoder.decode(StructureSet.self, from: encoder.encode(concentricRings))
    guard case .concentricRings(let roundTripPlacement) = roundTrip.placement else {
        throw Errors.structurePlacementWrongType("ConcentricRingsStructurePlacement")
    }
    #expect(roundTripPlacement.distance == 32)
    #expect(roundTrip.structures.first?.structure == "test:stronghold")
}
