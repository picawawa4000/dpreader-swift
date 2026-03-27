import Foundation
import Testing
@testable import DPReader

private func oceanMonumentTestContext() -> OceanMonumentGenerationContext {
    OceanMonumentGenerationContext(seaLevel: 63, minimumWorldY: -64) { pos in
        if pos.y < 30 {
            return BlockState(type: Block(withID: "minecraft:stone"))
        }
        if pos.y <= 63 {
            return BlockState(type: Block(withID: "minecraft:water"))
        }
        return BlockState(type: Block(withID: "minecraft:air"))
    }
}

@Test func testOceanMonumentBlockVolumeSamplerFallback() async throws {
    let bounds = OceanMonumentBoundingBox(minX: 0, minY: 0, minZ: 0, maxX: 31, maxY: 31, maxZ: 31)
    let volume = OceanMonumentBlockVolume(bounds: bounds) { _ in
        BlockState(type: Block(withID: "minecraft:stone"))
    }

    #expect(volume.block(at: PosInt3D(x: 1, y: 2, z: 3)).type.id == "minecraft:stone")

    volume.setBlock(BlockState(type: Block(withID: "minecraft:water")), at: PosInt3D(x: 1, y: 2, z: 3))
    #expect(volume.block(at: PosInt3D(x: 1, y: 2, z: 3)).type.id == "minecraft:water")
    #expect(volume.block(at: PosInt3D(x: 2, y: 2, z: 3)).type.id == "minecraft:stone")
}

@Test func testOceanMonumentPieceGraphIsDeterministic() async throws {
    let graphA = OceanMonument.generatePieceGraph(worldSeed: 503815372, startChunk: PosInt2D(x: 0, z: 0))
    let graphB = OceanMonument.generatePieceGraph(worldSeed: 503815372, startChunk: PosInt2D(x: 0, z: 0))

    #expect(graphA.orientation == graphB.orientation)
    #expect(graphA.boundingBox == graphB.boundingBox)
    #expect(graphA.pieces.count == graphB.pieces.count)
    #expect(graphA.pieces.map(\.kind) == graphB.pieces.map(\.kind))
    #expect(graphA.pieces.count == 32)
    #expect(graphA.boundingBox == OceanMonumentBoundingBox(minX: -29, minY: 39, minZ: -29, maxX: 28, maxY: 61, maxZ: 28))
}

@Test func testOceanMonumentGenerationSnapshot() async throws {
    let result = OceanMonument.generate(
        worldSeed: 503815372,
        startChunk: PosInt2D(x: 0, z: 0),
        context: oceanMonumentTestContext()
    )

    let counts = result.blocks.allTouchedBlocks().reduce(into: [String: Int]()) { partialResult, entry in
        partialResult[entry.1.type.id, default: 0] += 1
    }
    let hash = result.blocks.allTouchedBlocks().reduce(into: UInt64(1469598103934665603)) { partialResult, entry in
        partialResult ^= UInt64(bitPattern: Int64(entry.0.x))
        partialResult &*= 1099511628211
        partialResult ^= UInt64(bitPattern: Int64(entry.0.y))
        partialResult &*= 1099511628211
        partialResult ^= UInt64(bitPattern: Int64(entry.0.z))
        partialResult &*= 1099511628211
        for byte in entry.1.type.id.utf8 {
            partialResult ^= UInt64(byte)
            partialResult &*= 1099511628211
        }
    }

    #expect(result.graph.pieces.count == 32)
    #expect(result.graph.boundingBox == OceanMonumentBoundingBox(minX: -29, minY: 39, minZ: -29, maxX: 28, maxY: 61, maxZ: 28))
    #expect(result.blocks.allTouchedBlocks().count == 16547)
    #expect(
        result.elderGuardians == [
            PosInt3D(x: -17, y: 42, z: -12),
            PosInt3D(x: 16, y: 45, z: -15),
            PosInt3D(x: -1, y: 53, z: -1)
        ]
    )
    #expect(counts == [
        "minecraft:dark_prismarine": 275,
        "minecraft:gold_block": 8,
        "minecraft:prismarine": 6582,
        "minecraft:prismarine_bricks": 9494,
        "minecraft:sea_lantern": 122,
        "minecraft:water": 66
    ])
    #expect(hash == 6749865940407714986)
}
