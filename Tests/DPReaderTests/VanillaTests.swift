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

fileprivate enum Errors: Error {
    case noVanillaDataFound
}