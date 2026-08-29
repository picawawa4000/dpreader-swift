import Foundation
import Testing
@testable import DPReader

@Suite(.serialized)
struct MineshaftTests {
    private static let seed: WorldSeed = 123_458
    private final class Fixture: @unchecked Sendable {
        let pack: DataPack
        let generator: WorldGenerator
        var context: StructureGenerationContext!
        var chunks: [String: ProtoChunk] = [:]
        let lock = NSLock()
        init() throws {
            self.pack = try DataPack(fromRootPath: URL(filePath: "vanilla/1.21.11"))
            self.generator = try WorldGenerator(
                withWorldSeed: MineshaftTests.seed,
                usingDataPacks: [self.pack],
                usingSettings: RegistryKey(referencing: "minecraft:overworld")
            )
            self.context = StructureGenerationContext(
                seaLevel: 63, minimumWorldY: -64, maximumWorldY: 319, usingDataPacks: [self.pack]
            ) { [weak self] pos in self?.block(at: pos) ?? BlockState(id: "minecraft:air") }
        }
        func block(at pos: PosInt3D) -> BlockState {
            let chunkPos = PosInt2D(x: floorDiv(pos.x, by: 16), z: floorDiv(pos.z, by: 16))
            let key = "\(chunkPos.x),\(chunkPos.z)"
            self.lock.lock()
            defer { self.lock.unlock() }
            let chunk: ProtoChunk
            if let cached = self.chunks[key] { chunk = cached }
            else {
                let generated = ProtoChunk()
                try! self.generator.generateInto(generated, at: chunkPos)
                self.chunks[key] = generated
                chunk = generated
            }
            return chunk.block(atLocal: PosInt3D(x: pos.x & 15, y: pos.y + 64, z: pos.z & 15))
        }
    }
    private static let fixture = try! Fixture()

    @Test func referenceMineshaftChestMinecart() throws {
        let structure = try #require(Self.fixture.pack.structureRegistry.get(RegistryKey(referencing: "minecraft:mineshaft")))
        let generated = try #require(try structure.generate(
            worldSeed: Self.seed,
            startChunk: PosInt2D(x: 0, z: -6),
            context: Self.fixture.context
        ))
        guard case .mineshaft(let result) = generated else { Issue.record("Expected mineshaft result"); return }
        #expect(result.graph.pieces.count > 1)
        let minecart = result.lootContainers.first { $0.pos == PosInt3D(x: 8, y: -37, z: -79) }
        #expect(minecart?.block == "minecraft:chest_minecart")
        #expect(minecart?.lootTable == "minecraft:chests/abandoned_mineshaft")
        #expect(minecart?.lootSeed == -6_645_496_324_011_988_235)
    }

    @Test func mesaMineshaftUsesDarkOakPalette() throws {
        let structure = try #require(Self.fixture.pack.structureRegistry.get(RegistryKey(referencing: "minecraft:mineshaft_mesa")))
        let result = try #require(try structure.generate(
            worldSeed: Self.seed,
            startChunk: PosInt2D(x: 0, z: -6),
            context: Self.fixture.context
        ))
        guard case .mineshaft(let generated) = result else { Issue.record("Expected mineshaft result"); return }
        let pieces = generated.graph.pieces.compactMap { $0 as? MineshaftPiece }
        #expect(pieces.allSatisfy { $0.mineshaftType == MineshaftType.mesa })
        #expect(generated.blocks.allTouchedBlocks().contains { $0.1.id == "minecraft:dark_oak_planks" })
    }
}
