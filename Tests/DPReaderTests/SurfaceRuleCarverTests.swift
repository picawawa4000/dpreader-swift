import Foundation
import Testing
@testable import DPReader

private func surfaceCarverTestRouter() -> NoiseRouter {
    let zero = ConstantDensityFunction(value: 0)
    return NoiseRouter(
        preliminarySurfaceLevel: ConstantDensityFunction(value: 64),
        finalDensity: zero,
        barrier: zero,
        fluidLevelFloodedness: zero,
        fluidLevelSpread: zero,
        lava: zero,
        veinToggle: zero,
        veinRidged: zero,
        veinGap: zero,
        temperature: zero,
        humidity: zero,
        continents: zero,
        erosion: zero,
        depth: zero,
        weirdness: zero
    )
}

private func aquiferTestSettings(
    aquifersEnabled: Bool,
    seaLevel: Int = 63,
    floodedness: Double = 0,
    spread: Double = 0,
    lava: Double = 0
) -> NoiseSettings {
    let zero = ConstantDensityFunction(value: 0)
    return NoiseSettings(
        legacyRandomSource: false,
        seaLevel: seaLevel,
        aquifersEnabled: aquifersEnabled,
        minY: -64,
        height: 384,
        sizeHorizontal: 1,
        sizeVertical: 2,
        noiseRouter: NoiseRouter(
            preliminarySurfaceLevel: ConstantDensityFunction(value: 64),
            finalDensity: zero,
            barrier: zero,
            fluidLevelFloodedness: ConstantDensityFunction(value: floodedness),
            fluidLevelSpread: ConstantDensityFunction(value: spread),
            lava: ConstantDensityFunction(value: lava),
            veinToggle: zero,
            veinRidged: zero,
            veinGap: zero,
            temperature: zero,
            humidity: zero,
            continents: zero,
            erosion: zero,
            depth: zero,
            weirdness: zero
        ),
        surfaceRule: SurfaceRuleBlock(resultState: .init(name: "minecraft:stone"))
    )
}

@Test func testSurfaceRuleEvaluationUsesSequenceAndStoneDepth() throws {
    let settings = NoiseSettings(
        legacyRandomSource: false,
        minY: -64,
        height: 384,
        sizeHorizontal: 1,
        sizeVertical: 2,
        noiseRouter: surfaceCarverTestRouter(),
        surfaceRule: SurfaceRuleBlock(resultState: .init(name: "minecraft:stone"))
    )
    let evaluator = SurfaceRuleApplicator(
        settings: settings,
        noises: Registry<DoublePerlinNoise>(),
        biomes: Registry<Biome>(),
        worldSeed: 1234
    )
    let rule = SurfaceRuleSequence(sequence: [
        SurfaceRuleConditionRule(
            ifTrue: SurfaceRuleBiomeCondition(biomeIs: ["minecraft:desert"]),
            thenRun: SurfaceRuleBlock(resultState: .init(name: "minecraft:sand"))
        ),
        SurfaceRuleConditionRule(
            ifTrue: SurfaceRuleStoneDepthCondition(offset: 0, surfaceType: .floor, addSurfaceDepth: false),
            thenRun: SurfaceRuleBlock(resultState: .init(name: "minecraft:grass_block"))
        )
    ])
    let context = SurfaceRuleEvaluationContext(
        blockPosition: PosInt3D(x: 0, y: 64, z: 0),
        biome: RegistryKey(referencing: "minecraft:plains"),
        stoneDepthAbove: 1,
        stoneDepthBelow: 12,
        fluidHeight: nil,
        surfaceDepth: 3,
        secondarySurfaceDepth: 0,
        seaLevel: 63,
        minY: -64,
        height: 384,
        estimatedSurfaceY: 60,
        isSteep: false,
        biomeTemperature: 0.8
    )

    #expect(evaluator.evaluate(rule: rule, context: context)?.type.id == "minecraft:grass_block")
}

@Test func testConfiguredVanillaCarversDecode() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("vanilla/1.21.11/data/minecraft/worldgen/configured_carver")
    let decoder = JSONDecoder()
    for name in ["cave", "cave_extra_underground", "canyon", "nether_cave"] {
        let data = try Data(contentsOf: root.appendingPathComponent("\(name).json"))
        let decoded = try decoder.decode(ConfiguredCarver.self, from: data)
        let roundTripped = try decoder.decode(ConfiguredCarver.self, from: JSONEncoder().encode(decoded))
        #expect(roundTripped == decoded)
    }
}

@Test func testSeaLevelAquiferMaterializesFluidWithoutChangingDensityBitmap() throws {
    let settings = aquiferTestSettings(aquifersEnabled: false, seaLevel: 8)
    let chunk = ProtoChunk()
    try chunk.configure(minY: 0, height: 16)
    let sampler = VanillaChunkTerrainSampler(
        chunkPos: PosInt2D(x: 0, z: 0),
        minY: 0,
        height: 16,
        sizeHorizontal: 1,
        sizeVertical: 1
    )
    let aquifer = AquiferSampler(settings: settings, chunkPos: PosInt2D(x: 0, z: 0), worldSeed: 1)
    sampler.generateTerrain(
        into: chunk,
        with: ConstantDensityFunction(value: -1),
        aquifer: aquifer
    )

    #expect(chunk.block(atLocal: PosInt3D(x: 4, y: 7, z: 9)).type.id == "minecraft:water")
    #expect(chunk.block(atLocal: PosInt3D(x: 4, y: 8, z: 9)).type.id == "minecraft:air")
    #expect(!chunk.isTerrain(atLocal: PosInt3D(x: 4, y: 7, z: 9)))
}

@Test func testAquiferFloodednessAndLavaSelectionAreDeterministic() {
    let wetSettings = aquiferTestSettings(aquifersEnabled: true, floodedness: 1)
    let drySettings = aquiferTestSettings(aquifersEnabled: true, floodedness: -1)
    let lavaSettings = aquiferTestSettings(aquifersEnabled: true, floodedness: 0.6, lava: 1)
    let position = PosInt3D(x: 3, y: 30, z: 7)
    let firstWet = AquiferSampler(settings: wetSettings, chunkPos: PosInt2D(x: 0, z: 0), worldSeed: 99)
    let secondWet = AquiferSampler(settings: wetSettings, chunkPos: PosInt2D(x: 0, z: 0), worldSeed: 99)
    let dry = AquiferSampler(settings: drySettings, chunkPos: PosInt2D(x: 0, z: 0), worldSeed: 99)
    let lava = AquiferSampler(settings: lavaSettings, chunkPos: PosInt2D(x: 0, z: 0), worldSeed: 99)

    #expect(firstWet.apply(at: position, density: -1)?.type.id == "minecraft:water")
    #expect(secondWet.apply(at: position, density: -1) == firstWet.apply(at: position, density: -1))
    #expect(dry.apply(at: position, density: -1)?.type.id == "minecraft:air")
    #expect(lava.apply(at: PosInt3D(x: 3, y: -21, z: 7), density: -1)?.type.id == "minecraft:lava")
    #expect(firstWet.apply(at: position, density: 0.1) == nil)
}

@Test func testSurfaceRulesApplyToGeneratedColumn() throws {
    let rule = SurfaceRuleConditionRule(
        ifTrue: SurfaceRuleStoneDepthCondition(offset: 0, surfaceType: .floor, addSurfaceDepth: false),
        thenRun: SurfaceRuleBlock(resultState: .init(name: "minecraft:grass_block"))
    )
    let settings = NoiseSettings(
        legacyRandomSource: false,
        seaLevel: -100,
        minY: 0,
        height: 16,
        sizeHorizontal: 1,
        sizeVertical: 1,
        noiseRouter: surfaceCarverTestRouter(),
        surfaceRule: rule
    )
    let chunk = ProtoChunk()
    try chunk.configure(minY: 0, height: 16)
    for z in Int32(0)..<16 {
        for x in Int32(0)..<16 {
            for y in Int32(0)...10 { chunk.setTerrain(true, atLocal: PosInt3D(x: x, y: y, z: z)) }
        }
    }
    SurfaceRuleApplicator(
        settings: settings,
        noises: Registry<DoublePerlinNoise>(),
        biomes: Registry<Biome>(),
        worldSeed: 1
    ).apply(to: chunk, at: PosInt2D(x: 0, z: 0))

    #expect(chunk.block(atLocal: PosInt3D(x: 3, y: 10, z: 7)).type.id == "minecraft:grass_block")
    #expect(chunk.block(atLocal: PosInt3D(x: 3, y: 9, z: 7)).type.id == "minecraft:stone")
}

@Test func testRavineCarverUsesAquiferFluid() throws {
    let json = """
    {
      "type":"minecraft:canyon",
      "config":{
        "probability":1.0,
        "y":{"type":"minecraft:uniform","min_inclusive":{"absolute":24},"max_inclusive":{"absolute":24}},
        "yScale":3.0,
        "lava_level":{"absolute":-64},
        "replaceable":"#test:replaceable",
        "vertical_rotation":0.0,
        "shape":{
          "distance_factor":1.0,
          "thickness":6.0,
          "width_smoothness":3,
          "horizontal_radius_factor":1.0,
          "vertical_radius_default_factor":1.0,
          "vertical_radius_center_factor":0.0
        }
      }
    }
    """
    let carver = try JSONDecoder().decode(ConfiguredCarver.self, from: Data(json.utf8))
    let chunk = ProtoChunk()
    try chunk.configure(minY: 0, height: 64)
    for y in Int32(0)..<64 {
        for z in Int32(0)..<16 {
            for x in Int32(0)..<16 { chunk.setTerrain(true, atLocal: PosInt3D(x: x, y: y, z: z)) }
        }
    }
    var mask = CarvingMask(minY: 0, height: 64)
    let aquifer = AquiferSampler(
        settings: aquiferTestSettings(aquifersEnabled: false),
        chunkPos: PosInt2D(x: 0, z: 0),
        worldSeed: 9
    )
    CarverApplicator(replaceable: { _, id in id == "minecraft:stone" }).apply(
        [(carver, 0)],
        to: chunk,
        targetChunkPos: PosInt2D(x: 0, z: 0),
        sourceChunkPos: PosInt2D(x: 0, z: 0),
        worldSeed: 9,
        aquifer: aquifer,
        mask: &mask
    )
    var carved = 0
    for y in Int32(0)..<64 {
        for z in Int32(0)..<16 {
            for x in Int32(0)..<16 where chunk.block(atLocal: PosInt3D(x: x, y: y, z: z)).type.id == "minecraft:water" {
                carved += 1
            }
        }
    }
    #expect(carved > 0)
}
