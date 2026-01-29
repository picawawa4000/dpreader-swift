import Testing
@testable import DPReader

@Test func testBiomeSearchTreeFindsNearestBiome() async throws {
    let registry = Registry<Biome>()
    let biomeA = Biome(
        hasPrecipitation: true,
        temperature: 0.2,
        downfall: 0.1,
        carvers: [],
        features: [],
        spawners: [:],
        spawnCosts: [:]
    )
    let biomeB = Biome(
        hasPrecipitation: false,
        temperature: 0.9,
        downfall: 0.0,
        carvers: [],
        features: [],
        spawners: [:],
        spawnCosts: [:]
    )
    registry.register(biomeA, forKey: RegistryKey(referencing: "test:a"))
    registry.register(biomeB, forKey: RegistryKey(referencing: "test:b"))

    let paramsA = MultiNoiseBiomeSourceParameters(
        temperature: BiomeParameterRange(min: 0.0, max: 0.2),
        humidity: BiomeParameterRange(min: 0.0, max: 0.2),
        continentalness: BiomeParameterRange(value: 0.0),
        erosion: BiomeParameterRange(value: 0.0),
        depth: BiomeParameterRange(value: 0.0),
        weirdness: BiomeParameterRange(value: 0.0),
        offset: BiomeParameterRange(value: 0.0)
    )
    let paramsB = MultiNoiseBiomeSourceParameters(
        temperature: BiomeParameterRange(min: 0.8, max: 1.0),
        humidity: BiomeParameterRange(min: 0.8, max: 1.0),
        continentalness: BiomeParameterRange(value: 0.0),
        erosion: BiomeParameterRange(value: 0.0),
        depth: BiomeParameterRange(value: 0.0),
        weirdness: BiomeParameterRange(value: 0.0),
        offset: BiomeParameterRange(value: 0.0)
    )

    let entries = [
        MultiNoiseBiomeSourceBiome(biome: "test:a", parameters: paramsA),
        MultiNoiseBiomeSourceBiome(biome: "test:b", parameters: paramsB)
    ]
    let tree = try buildBiomeSearchTree(from: registry, entries: entries)

    let pointA = NoisePoint(temperature: 0.1, humidity: 0.1, continentalness: 0.0, erosion: 0.0, weirdness: 0.0, depth: 0.0)
    let pointB = NoisePoint(temperature: 0.95, humidity: 0.9, continentalness: 0.0, erosion: 0.0, weirdness: 0.0, depth: 0.0)
    let pointC = NoisePoint(temperature: -0.5, humidity: 0.5, continentalness: 0.0, erosion: 0.0, weirdness: 0.0, depth: 0.0)

    let resultA = try tree.get(pointA)
    let resultB = try tree.get(pointB)
    let resultC = try tree.get(pointC)

    #expect(resultA === biomeA)
    #expect(resultB === biomeB)
    #expect(resultC === biomeA)
}

@Test func testBiomeSearchTreeMissingBiomeThrows() async {
    let registry = Registry<Biome>()
    let params = MultiNoiseBiomeSourceParameters(
        temperature: BiomeParameterRange(value: 0.0),
        humidity: BiomeParameterRange(value: 0.0),
        continentalness: BiomeParameterRange(value: 0.0),
        erosion: BiomeParameterRange(value: 0.0),
        depth: BiomeParameterRange(value: 0.0),
        weirdness: BiomeParameterRange(value: 0.0),
        offset: BiomeParameterRange(value: 0.0)
    )
    let entries = [MultiNoiseBiomeSourceBiome(biome: "test:missing", parameters: params)]

    do {
        _ = try buildBiomeSearchTree(from: registry, entries: entries)
        #expect(Bool(false))
    } catch let error as BiomeSearchTreeError {
        switch error {
        case .missingBiome(let name):
            #expect(name == "test:missing")
        default:
            #expect(Bool(false))
        }
    } catch {
        #expect(Bool(false))
    }
}
