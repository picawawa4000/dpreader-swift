import Foundation
import Testing
@testable import DPReader

private func structureDispatchContext() -> StructureGenerationContext {
    StructureGenerationContext(seaLevel: 63, minimumWorldY: -64) { pos in
        if pos.y <= 63 {
            return BlockState(type: Block(withID: "minecraft:sand"))
        }
        return BlockState(type: Block(withID: "minecraft:air"))
    }
}

@Test func testStructureDispatchGeneratesDesertPyramid() async throws {
    let structure = Structure(
        type: "minecraft:desert_pyramid",
        biomes: .rawID("minecraft:desert"),
        spawnOverrides: [:],
        step: "surface_structures"
    )
    let context = structureDispatchContext()

    let graph = try structure.generatePieceGraph(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: context
    )
    let result = try structure.generate(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: context
    )

    guard let generatedGraph = graph else {
        Issue.record("Expected desert pyramid piece graph")
        return
    }
    guard case .desertPyramid(let generatedResult)? = result else {
        Issue.record("Expected desert pyramid generation result")
        return
    }

    #expect(generatedGraph.pieces.count == 1)
    #expect(generatedResult.graph.boundingBox == generatedGraph.boundingBox)
}

@Test func testStructureDispatchGeneratesOceanMonument() async throws {
    let structure = Structure(
        type: "minecraft:ocean_monument",
        biomes: .rawID("minecraft:deep_ocean"),
        spawnOverrides: [:],
        step: "surface_structures"
    )
    let context = StructureGenerationContext(seaLevel: 63, minimumWorldY: -64) { _ in
        BlockState(type: Block(withID: "minecraft:water"))
    }

    let graph = try structure.generatePieceGraph(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: context
    )
    let result = try structure.generate(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: context
    )

    guard let generatedGraph = graph else {
        Issue.record("Expected ocean monument piece graph")
        return
    }
    guard case .oceanMonument(let generatedResult)? = result else {
        Issue.record("Expected ocean monument generation result")
        return
    }

    #expect(generatedGraph.pieces.count > 1)
    #expect(generatedResult.graph.boundingBox == generatedGraph.boundingBox)
}

@Test func testStructureDispatchRejectsUnsupportedTypes() async throws {
    let structure = Structure(
        type: "minecraft:fortress",
        biomes: .rawID("minecraft:nether_wastes"),
        spawnOverrides: [:],
        step: "surface_structures"
    )
    let context = structureDispatchContext()

    #expect(throws: StructureGenerationError.unsupportedStructureType("minecraft:fortress")) {
        _ = try structure.generatePieceGraph(
            worldSeed: 503815372,
            startChunk: PosInt2D(x: 0, z: 0),
            context: context
        )
    }

    #expect(throws: StructureGenerationError.unsupportedStructureType("minecraft:fortress")) {
        _ = try structure.generate(
            worldSeed: 503815372,
            startChunk: PosInt2D(x: 0, z: 0),
            context: context
        )
    }
}
