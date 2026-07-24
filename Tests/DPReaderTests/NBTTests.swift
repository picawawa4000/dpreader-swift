import Foundation
import Testing
@testable import DPReader

private struct PlayerData: Codable, Equatable {
    let name: String
    let health: Float
    let position: [Double]
    let canFly: Bool
    let slot: Int8
}

private struct IntBox: Codable, Equatable {
    let value: Int
}

private struct UIntBox: Codable, Equatable {
    let value: UInt
}

private func nbtFixtureURL(named name: String) -> URL {
    URL(filePath: "Tests/Resources/NBT/\(name)")
}

@Test func testNBTRawTagRoundTrip() throws {
    let tag = NBTTag.compound([
        "name": .string("Steve"),
        "health": .float(20.0),
        "position": .list([
            .double(12.5),
            .double(64.0),
            .double(-3.25)
        ]),
        "flags": .byteArray([1, 0, -1]),
        "scores": .intArray([7, 42, -9]),
        "ticks": .longArray([1, 2, 3]),
        "inventory": .list([
            .compound([
                "slot": .byte(0),
                "id": .string("minecraft:stone"),
                "count": .byte(64)
            ]),
            .compound([
                "slot": .byte(1),
                "id": .string("minecraft:torch"),
                "count": .byte(16)
            ])
        ])
    ])

    let encoded = try NBTEncoder().encode(tag, rootName: "Player")
    let decodedRoot = try NBTDecoder().decodeRoot(encoded)

    #expect(decodedRoot.name == "Player")
    #expect(decodedRoot.tag == tag)
}

@Test func testNBTSupportsEmptyLists() throws {
    let tag = NBTTag.list([])

    let encoded = try NBTEncoder().encode(tag)
    let decoded = try NBTDecoder().decode(encoded)

    #expect(decoded == tag)
}

@Test func testNBTBoolUsesByteEncoding() throws {
    let value = PlayerData(
        name: "Alex",
        health: 18.5,
        position: [1.25, 70.0, -8.0],
        canFly: true,
        slot: 4
    )

    let encodedTag = try NBTEncoder().encodeTag(value)
    #expect(encodedTag == .compound([
        "name": .string("Alex"),
        "health": .float(18.5),
        "position": .list([
            .double(1.25),
            .double(70.0),
            .double(-8.0)
        ]),
        "canFly": .byte(1),
        "slot": .byte(4)
    ]))

    let roundTrip = try NBTDecoder().decode(PlayerData.self, from: encodedTag)
    #expect(roundTrip == value)
}

@Test func testNBTRejectsMixedListEncoding() throws {
    #expect(throws: NBTTag.CodingError.nonHomogeneousList(expected: 3, actual: 8)) {
        try NBTEncoder().encode(.list([.int(1), .string("two")]))
    }
}

@Test func testNBTRejectsEndAsRootTag() throws {
    #expect(throws: NBTTag.CodingError.invalidRootTag) {
        try NBTEncoder().encode(.end)
    }
}

@Test func testNBTRejectsEncodingInt() throws {
    do {
        _ = try NBTEncoder().encodeTag(IntBox(value: 7))
        Issue.record("Expected Int encoding to be rejected")
    } catch let error as EncodingError {
        guard case .invalidValue = error else {
            Issue.record("Expected EncodingError.invalidValue, got \(error)")
            return
        }
    }
}

@Test func testNBTRejectsEncodingUInt() throws {
    do {
        _ = try NBTEncoder().encodeTag(UIntBox(value: 7))
        Issue.record("Expected UInt encoding to be rejected")
    } catch let error as EncodingError {
        guard case .invalidValue = error else {
            Issue.record("Expected EncodingError.invalidValue, got \(error)")
            return
        }
    }
}

@Test func testNBTRejectsDecodingInt() throws {
    let tag = NBTTag.compound(["value": .int(7)])

    do {
        _ = try NBTDecoder().decode(IntBox.self, from: tag)
        Issue.record("Expected Int decoding to be rejected")
    } catch let error as DecodingError {
        guard case .typeMismatch = error else {
            Issue.record("Expected DecodingError.typeMismatch, got \(error)")
            return
        }
    }
}

@Test func testNBTRejectsDecodingUInt() throws {
    let tag = NBTTag.compound(["value": .int(7)])

    do {
        _ = try NBTDecoder().decode(UIntBox.self, from: tag)
        Issue.record("Expected UInt decoding to be rejected")
    } catch let error as DecodingError {
        guard case .typeMismatch = error else {
            Issue.record("Expected DecodingError.typeMismatch, got \(error)")
            return
        }
    }
}

@Test func testNBTLoadsStructureFileFromCompressedFixture() throws {
    let structure = try NBTDecoder().decode(StructureFile.self, fromFileAt: nbtFixtureURL(named: "testingstructure.nbt"))

    #expect(structure.DataVersion == 4_903)
    #expect(structure.size == [2, 2, 2])
    #expect(structure.palette.map(\.Name) == [
        "minecraft:gold_block",
        "minecraft:diamond_block"
    ])
    #expect(structure.palettes == nil)
    #expect(structure.entities.isEmpty)
    #expect(structure.blocks.count == 8)

    let blockNamesByPosition = Dictionary(
        uniqueKeysWithValues: structure.blocks.map { block in
            (block.pos, structure.palette[Int(block.state)].Name)
        }
    )

    for x in 0...1 {
        for y in 0...1 {
            for z in 0...1 {
                let position = [Int32(x), Int32(y), Int32(z)]
                let expectedName = ((x + y + z) % 2 == 0) ? "minecraft:gold_block" : "minecraft:diamond_block"
                #expect(blockNamesByPosition[position] == expectedName)
            }
        }
    }
}
