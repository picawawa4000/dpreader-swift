import Foundation
import Testing
@testable import DPReader

@Test func testEncodingForNoiseRouter() async throws {
    let noiseRouter = NoiseRouter(
        preliminarySurfaceLevel: ConstantDensityFunction(value: 1.0),
        finalDensity: ConstantDensityFunction(value: 2.0),
        barrier: ConstantDensityFunction(value: 3.0),
        fluidLevelFloodedness: ConstantDensityFunction(value: 4.0),
        fluidLevelSpread: ConstantDensityFunction(value: 5.0),
        lava: ConstantDensityFunction(value: 6.0),
        veinToggle: ConstantDensityFunction(value: 7.0),
        veinRidged: ConstantDensityFunction(value: 8.0),
        veinGap: ConstantDensityFunction(value: 9.0),
        temperature: ConstantDensityFunction(value: 10.0),
        humidity: ConstantDensityFunction(value: 11.0),
        continents: ConstantDensityFunction(value: 12.0),
        erosion: ConstantDensityFunction(value: 13.0),
        depth: ConstantDensityFunction(value: 14.0),
        weirdness: ConstantDensityFunction(value: 15.0)
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(noiseRouter)
    #expect(try checkJSON(data, [
        "preliminary_surface_level": 1.0,
        "final_density": 2.0,
        "barrier": 3.0,
        "fluid_level_floodedness": 4.0,
        "fluid_level_spread": 5.0,
        "lava": 6.0,
        "vein_toggle": 7.0,
        "vein_ridged": 8.0,
        "vein_gap": 9.0,
        "temperature": 10.0,
        "vegetation": 11.0,
        "continents": 12.0,
        "erosion": 13.0,
        "depth": 14.0,
        "ridges": 15.0
    ]))
}

@Test func testDecodingForNoiseRouter() async throws {
    let data = """
    {
        "preliminary_surface_level": 1.0,
        "final_density": "minecraft:final_density",
        "barrier": 3.0,
        "fluid_level_floodedness": 4.0,
        "fluid_level_spread": 5.0,
        "lava": 6.0,
        "vein_toggle": 7.0,
        "vein_ridged": 8.0,
        "vein_gap": 9.0,
        "temperature": 10.0,
        "vegetation": 11.0,
        "continents": 12.0,
        "erosion": 13.0,
        "depth": 14.0,
        "ridges": 15.0
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    let noiseRouter = try decoder.decode(NoiseRouter.self, from: data)
    #expect(noiseRouter.finalDensity is ReferenceDensityFunction)
    let finalDensity = noiseRouter.finalDensity as! ReferenceDensityFunction
    #expect(finalDensity.targetKey.name == "minecraft:final_density")
    let preliminary = noiseRouter.preliminarySurfaceLevel as! ConstantDensityFunction
    #expect(preliminary.testingAttributes.value == 1.0)
    let weirdness = noiseRouter.weirdness as! ConstantDensityFunction
    #expect(weirdness.testingAttributes.value == 15.0)
}

@Test func testEncodingForNoiseSettings() async throws {
    let noiseRouter = NoiseRouter(
        preliminarySurfaceLevel: ConstantDensityFunction(value: 1.0),
        finalDensity: ConstantDensityFunction(value: 2.0),
        barrier: ConstantDensityFunction(value: 3.0),
        fluidLevelFloodedness: ConstantDensityFunction(value: 4.0),
        fluidLevelSpread: ConstantDensityFunction(value: 5.0),
        lava: ConstantDensityFunction(value: 6.0),
        veinToggle: ConstantDensityFunction(value: 7.0),
        veinRidged: ConstantDensityFunction(value: 8.0),
        veinGap: ConstantDensityFunction(value: 9.0),
        temperature: ConstantDensityFunction(value: 10.0),
        humidity: ConstantDensityFunction(value: 11.0),
        continents: ConstantDensityFunction(value: 12.0),
        erosion: ConstantDensityFunction(value: 13.0),
        depth: ConstantDensityFunction(value: 14.0),
        weirdness: ConstantDensityFunction(value: 15.0)
    )

    let noiseSettings = NoiseSettings(
        legacyRandomSource: true,
        minY: -64,
        height: 384,
        sizeHorizontal: 1,
        sizeVertical: 2,
        noiseRouter: noiseRouter
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(noiseSettings)
    #expect(try checkJSON(data, [
        "legacy_random_source": true,
        "noise": [
            "min_y": -64,
            "height": 384,
            "size_horizontal": 1,
            "size_vertical": 2
        ],
        "noise_router": [
            "preliminary_surface_level": 1.0,
            "final_density": 2.0,
            "barrier": 3.0,
            "fluid_level_floodedness": 4.0,
            "fluid_level_spread": 5.0,
            "lava": 6.0,
            "vein_toggle": 7.0,
            "vein_ridged": 8.0,
            "vein_gap": 9.0,
            "temperature": 10.0,
            "vegetation": 11.0,
            "continents": 12.0,
            "erosion": 13.0,
            "depth": 14.0,
            "ridges": 15.0
        ]
    ]))
}

@Test func testDecodingForNoiseSettings() async throws {
    let data = """
    {
        "legacy_random_source": false,
        "noise": {
            "min_y": -32,
            "height": 256,
            "size_horizontal": 2,
            "size_vertical": 4
        },
        "noise_router": {
            "preliminary_surface_level": 0.25,
            "final_density": 0.5,
            "barrier": 0.75,
            "fluid_level_floodedness": 1.0,
            "fluid_level_spread": 1.25,
            "lava": 1.5,
            "vein_toggle": 1.75,
            "vein_ridged": 2.0,
            "vein_gap": 2.25,
            "temperature": 2.5,
            "vegetation": 2.75,
            "continents": 3.0,
            "erosion": 3.25,
            "depth": 3.5,
            "ridges": 3.75
        }
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    let noiseSettings = try decoder.decode(NoiseSettings.self, from: data)
    #expect(noiseSettings.legacyRandomSource == false)
    #expect(noiseSettings.minY == -32)
    #expect(noiseSettings.height == 256)
    #expect(noiseSettings.sizeHorizontal == 2)
    #expect(noiseSettings.sizeVertical == 4)
    let humidity = noiseSettings.noiseRouter.humidity as! ConstantDensityFunction
    #expect(humidity.testingAttributes.value == 2.75)
}
