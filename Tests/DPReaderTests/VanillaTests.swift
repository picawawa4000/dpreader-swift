import Foundation
import Testing
@testable import DPReader

// Cubiomes uses ints that represent doubles times 10,000, so we need a different function to compare them.
private func checkDoubleCubiomes(_ actual: Double, _ expected: Int) -> Bool {
    // add some tolerance because I'm lazy
    let roundedUpActualValue = Int((actual * 10_000).rounded(FloatingPointRoundingRule.up))
    let roundedDownActualValue = Int((actual * 10_000).rounded(FloatingPointRoundingRule.down))
    guard expected == roundedUpActualValue || expected == roundedDownActualValue else {
        let roundedActualValue = Int((actual * 10_000).rounded(FloatingPointRoundingRule.toNearestOrEven))
        print("Error in checkDouble: expected value", expected, "did not match actual value", actual, "(rounded to", roundedActualValue, ")!")
        return false
    }
    return true
}

@Test func testVanilla() async throws {
    // janky but functional
    let vanillaDataPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vanilla/1.21.11")
    print(vanillaDataPath.path)
    if !FileManager.default.fileExists(atPath: vanillaDataPath.path) {
        throw Errors.noVanillaDataFound
    }

    let pack = try DataPack(fromRootPath: vanillaDataPath)
    
    print("Noises in vanilla 1.21.11:")
    pack.noiseRegistry.forEach { (key: RegistryKey<NoiseDefinition>, value: NoiseDefinition) in
        print(key.name)
    }

    print("Density Functions in vanilla 1.21.11:")
    pack.densityFunctionRegistry.forEach { (key: RegistryKey<any DensityFunction>, value: any DensityFunction) in
        print(key.name)
    }

    print("Noise Settings in vanilla 1.21.11:")
    pack.noiseSettingsRegistry.forEach { (key: RegistryKey<NoiseSettings>, value: NoiseSettings) in
        print(key.name)
    }

    print("Testing WorldGenerator instantiation with seed 50123537021...")
    let worldGenerator = try WorldGenerator(
        withWorldSeed: 50123537021,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: "minecraft:overworld")
    )
    let noisePos = worldGenerator.sampleNoisePoint(at: PosInt3D(x: 0, y: 0, z: 0))
    print("NoisePos: temperature \(noisePos.temperature), humidity \(noisePos.humidity), continentalness \(noisePos.continentalness), erosion \(noisePos.erosion), weirdness \(noisePos.weirdness), depth \(noisePos.depth)")
    // temperature: 4975, humidity: 1032, continentalness:2575, erosion: -2158, depth: 5912, weirdness: 1340 (according to Cubiomes)
    #expect(checkDoubleCubiomes(noisePos.temperature, 4975))
    #expect(checkDoubleCubiomes(noisePos.humidity, 1032))
    #expect(checkDoubleCubiomes(noisePos.continentalness, 2575))
    #expect(checkDoubleCubiomes(noisePos.erosion, -2158))
    #expect(checkDoubleCubiomes(noisePos.depth, 5912))
    #expect(checkDoubleCubiomes(noisePos.weirdness, 1340))

    let biome = try worldGenerator.sampleBiome(at: PosInt3D(x: 0, y: 0, z: 0), in: RegistryKey(referencing: "minecraft:overworld"))
    #expect(biome == RegistryKey<Biome>(referencing: "minecraft:sparse_jungle"))
}

@Test func testVanillaBatchGeneration() async throws {
    let vanillaDataPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vanilla/1.21.11")
    print(vanillaDataPath.path)
    if !FileManager.default.fileExists(atPath: vanillaDataPath.path) {
        throw Errors.noVanillaDataFound
    }

    let pack = try DataPack(fromRootPath: vanillaDataPath)

    let worldGenerator = try WorldGenerator(
        withWorldSeed: 503815372,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: "minecraft:overworld")
    )

    // This format is more efficient + I can't be bothered to convert it
    let cubiomesNumberToKeyMap = [
        7: RegistryKey<Biome>(referencing: "minecraft:river"),
        21: RegistryKey<Biome>(referencing: "minecraft:jungle"),
        23: RegistryKey<Biome>(referencing: "minecraft:sparse_jungle"),
        163: RegistryKey<Biome>(referencing: "minecraft:windswept_savanna"),
        184: RegistryKey<Biome>(referencing: "minecraft:mangrove_swamp")
    ]
    let cubiomesData = [
        23,   23,   23,  184,  184,  184,  184,  184,  184,  184,  184,  163,  163,  163,  163,  163,   23,   23,  163,   23,   23,   23,   23,   23,   23,   23,  184,  184,  184,  184,  184,  184,
        23,   23,   23,  184,  184,  184,  184,  184,  184,  184,  184,  184,  163,  163,  163,  163,  163,  163,  163,  163,   23,   23,   23,   23,   23,   23,   23,   23,   23,   23,  184,  184,
        23,  184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  163,  163,  163,  163,  163,  163,  163,  163,  163,   23,   23,   23,   23,   23,   23,   23,   23,   23,   23,   23,
        23,  184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,   23,   23,   23,   23,   23,   23,   23,   23,   23,   23,
        184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,   23,   23,   23,   23,   23,   23,   23,   23,
        184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,   23,   23,   23,   23,   23,   23,   23,
        184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,   23,   23,   23,   23,   23,   23,   23,
        184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,   23,   23,   23,   23,   23,   23,   23,
        184,  184,  184,  184,  184,  184,  184,  184,  184,  184,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,   23,   23,   23,   23,   23,   23,   23,
        184,  184,  184,  184,  184,  184,  184,  184,  184,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,   23,   23,   23,   23,   23,   23,   23,
        184,  184,  184,  184,  184,  184,  184,  184,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,   23,   23,   23,   23,   23,   23,   23,
        184,  184,  184,  184,  184,  184,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,   23,   23,   23,   23,   23,   23,   23,
        184,  184,  184,  184,  184,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,   23,   23,   23,   23,   23,   23,   23,   23,
        184,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,   23,   23,   23,   23,   23,   23,   23,   23,   23,
        184,    7,    7,    7,    7,    7,    7,    7,    7,    7,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,   23,   23,   23,   23,   23,   23,   23,   23,   23,
        184,    7,    7,    7,   21,    7,    7,    7,    7,    7,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,   23,   23,   23,   23,   23,   23,   23,   23,   23,   23,   23,
        7,    7,    7,   21,   21,   21,   21,    7,    7,    7,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,   23,   23,   23,   23,   23,   23,   23,   23,   23,   23,   23,
        7,    7,    7,   21,   21,   21,   21,    7,    7,    7,    7,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,   23,   23,   23,   23,   23,   23,   23,   23,   23,   23,
        7,   21,   21,   21,   21,   21,    7,    7,    7,    7,    7,  163,  163,  163,  163,  163,  163,  163,  163,  163,  163,   23,   23,   23,   23,   23,   23,   23,   23,   23,   23,   23,
        21,   21,   21,   21,   21,   21,    7,    7,    7,    7,  163,  163,  163,  163,  163,    7,    7,  163,  163,  163,  163,   23,   23,   23,  163,   23,   23,   23,   23,   23,   23,   23,
        21,   21,   21,   21,   21,   21,   21,    7,    7,    7,    7,    7,  163,  163,    7,    7,    7,    7,    7,    7,  163,   23,   23,   23,   23,   23,   23,   23,    7,   23,   23,   23,
        21,   21,   21,   21,   21,   21,   21,    7,    7,    7,    7,    7,    7,    7,    7,    7,    7,    7,    7,    7,    7,    7,   23,   23,   23,   23,   23,   23,    7,   23,   23,   23,
        21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,    7,    7,    7,    7,    7,    7,    7,    7,    7,    7,    7,    7,   23,   23,   23,    7,    7,    7,    7,   23,   23,
        21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,    7,    7,    7,    7,    7,   23,    7,    7,    7,    7,   23,   23,
        21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,    7,    7,    7,    7,    7,    7,    7,    7,    7,    7,    7,
        21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,    7,    7,    7,    7,    7,    7,    7,    7,    7,
        21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,    7,   21,   21,   21,   21,    7,    7,
        21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,    7,
        21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,
        21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,
        21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,
        21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,   21,
    ]

    let noisePoint = worldGenerator.sampleNoisePoint(at: PosInt3D(x: 0, y: 256, z: 40))
    print(noisePoint)
    #expect(checkDoubleCubiomes(noisePoint.temperature, 5072))
    #expect(checkDoubleCubiomes(noisePoint.humidity, 2329))
    #expect(checkDoubleCubiomes(noisePoint.continentalness, -30))
    #expect(checkDoubleCubiomes(noisePoint.erosion, 5575))
    //#expect(checkDoubleCubiomes(noisePoint.depth, -75135))
    #expect(checkDoubleCubiomes(noisePoint.weirdness, 2434))

    for x: Int32 in 0..<32 {
        for z: Int32 in 0..<32 {
            if x == 11 && z == 7 {
                print("x 11 z 7")
            }

            let result = try worldGenerator.sampleBiome(at: PosInt3D(x: x * 4, y: 256, z: z * 4), in: RegistryKey(referencing: "minecraft:overworld"))!
            let cbResult = cubiomesData[Int(z*32+x)]
            let cbResultKey = cubiomesNumberToKeyMap[cbResult]!
            if result != cbResultKey {
                print("\(x*4), \(z*4): DPReader result \(result.name) diverges from Cubiomes result \(cbResultKey.name)!")
                #expect(Bool(false))
            }
        }
    }
}

fileprivate enum Errors: Error {
    case noVanillaDataFound
}