import Foundation
import Testing
@testable import DPReader

private func makeState(_ id: String, properties: [String: String] = [:]) -> BlockState {
    return BlockState(type: Block(withID: id), properties: properties)
}

private func sameState(_ lhs: BlockState, _ rhs: BlockState) -> Bool {
    return lhs.type.id == rhs.type.id && lhs.properties == rhs.properties
}

@Test func testPalettedChunkBlockStorageDefaultFill() async throws {
    let air = makeState("minecraft:air")
    let storage = PalettedChunkBlockStorage(filledWith: air)

    let positions = [
        PosInt3D(x: 0, y: 0, z: 0),
        PosInt3D(x: 15, y: 15, z: 15),
        PosInt3D(x: 7, y: 3, z: 12)
    ]

    for pos in positions {
        #expect(sameState(storage.getBlock(at: pos), air))
    }
}

@Test func testPalettedChunkBlockStorageSetAndGet() async throws {
    let air = makeState("minecraft:air")
    let stone = makeState("minecraft:stone")
    let dirt = makeState("minecraft:dirt")
    let storage = PalettedChunkBlockStorage(filledWith: air)

    let posA = PosInt3D(x: 1, y: 2, z: 3)
    let posB = PosInt3D(x: 4, y: 5, z: 6)

    storage.setBlock(stone, at: posA)
    #expect(sameState(storage.getBlock(at: posA), stone))
    #expect(sameState(storage.getBlock(at: posB), air))

    storage.setBlock(dirt, at: posB)
    #expect(sameState(storage.getBlock(at: posA), stone))
    #expect(sameState(storage.getBlock(at: posB), dirt))
}

@Test func testPalettedChunkBlockStorageWordPackingBoundary() async throws {
    let air = makeState("minecraft:air")
    let storage = PalettedChunkBlockStorage(filledWith: air)

    var states: [BlockState] = []
    for i in 1...16 {
        states.append(makeState("minecraft:test_\(i)"))
    }

    for i in 0..<16 {
        storage.setBlock(states[i], at: PosInt3D(x: Int32(i), y: 0, z: 0))
    }

    #expect(storage.debugPaletteCount == 17)
    guard let data = storage.debugData else {
        #expect(Bool(false))
        return
    }

    #expect(data.count == 342)

    var expectedWord0: UInt64 = 0
    for slot in 0..<12 {
        expectedWord0 |= UInt64(slot + 1) << UInt64(slot * 5)
    }

    var expectedWord1: UInt64 = 0
    for slot in 0..<4 {
        expectedWord1 |= UInt64(slot + 13) << UInt64(slot * 5)
    }

    #expect(data[0] == expectedWord0)
    #expect(data[1] == expectedWord1)
}
