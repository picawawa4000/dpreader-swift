import Foundation
import Testing
@testable import DPReader

@Suite(.serialized)
struct RuinedPortalTests {
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
                withWorldSeed: RuinedPortalTests.seed,
                usingDataPacks: [self.pack],
                usingSettings: RegistryKey(referencing: "minecraft:overworld")
            )
            self.context = StructureGenerationContext(
                seaLevel: 63, minimumWorldY: -64, maximumWorldY: 319, usingDataPacks: [self.pack]
            ) { [weak self] pos in self?.block(at: pos) ?? Blocks.airState }
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

    @Test func referenceRuinedPortalLoot() throws {
        let structure = try #require(Self.fixture.pack.structureRegistry.get(
            RegistryKey(referencing: "minecraft:ruined_portal")
        ))
        let generated = try #require(try structure.generate(
            worldSeed: Self.seed,
            startChunk: PosInt2D(x: -257, z: -35),
            context: Self.fixture.context
        ))
        guard case .ruinedPortal(let result) = generated else {
            Issue.record("Expected ruined portal result")
            return
        }
        let chest = result.lootContainers.first { $0.pos == PosInt3D(x: -4_107, y: 26, z: -554) }
        #expect(chest?.block == "minecraft:chest")
        #expect(chest?.lootTable == "minecraft:chests/ruined_portal")
        #expect(chest?.lootSeed == -3_655_315_866_665_580_896)
    }
}
