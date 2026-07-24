/// Interface between Minecraft's NBT format and Foundation's serialisation library.
/// TODO: superclass coding should not store data to a new key, but should be flattened instead.

import Foundation
#if canImport(zlib)
import zlib
#endif

public enum NBTTag: Equatable, Sendable {
    case end
    case byte(Int8)
    case short(Int16)
    case int(Int32)
    case long(Int64)

    case float(Float)
    case double(Double)

    case byteArray([Int8])
    case intArray([Int32])
    case longArray([Int64])

    case string(String)

    case list([NBTTag])

    case compound([String: NBTTag])
}

public extension NBTTag {
    struct Root: Equatable, Sendable {
        public let name: String
        public let tag: NBTTag

        public init(name: String = "", tag: NBTTag) {
            self.name = name
            self.tag = tag
        }
    }

    enum CodingError: Error, Equatable {
        case invalidRootTag
        case invalidTagType(UInt8)
        case invalidListElementType(UInt8)
        case invalidCompoundEntry
        case nonHomogeneousList(expected: UInt8, actual: UInt8)
        case negativeLength(Int32)
        case lengthOutOfRange(Int)
        case stringTooLong(Int)
        case invalidUTF8String
        case unexpectedEOF(expected: Int, remaining: Int)
        case trailingBytes(Int)
    }
}

public final class NBTEncoder: Encoder {
    public var codingPath: [any CodingKey]
    public var userInfo: [CodingUserInfoKey: Any]

    private let box: NBTEncodingBox

    public init(userInfo: [CodingUserInfoKey: Any] = [:]) {
        self.codingPath = []
        self.userInfo = userInfo
        self.box = NBTEncodingBox()
    }

    fileprivate init(
        codingPath: [any CodingKey],
        userInfo: [CodingUserInfoKey: Any],
        box: NBTEncodingBox
    ) {
        self.codingPath = codingPath
        self.userInfo = userInfo
        self.box = box
    }

    public func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        let container = NBTKeyedEncodingContainer<Key>(
            codingPath: codingPath,
            userInfo: userInfo,
            storage: box.makeKeyedStorage()
        )
        return KeyedEncodingContainer(container)
    }

    public func unkeyedContainer() -> any UnkeyedEncodingContainer {
        NBTUnkeyedEncodingContainer(
            codingPath: codingPath,
            userInfo: userInfo,
            storage: box.makeUnkeyedStorage()
        )
    }

    public func singleValueContainer() -> any SingleValueEncodingContainer {
        NBTSingleValueEncodingContainer(codingPath: codingPath, userInfo: userInfo, box: box)
    }

    public func encodeTag<T: Encodable>(_ value: T) throws -> NBTTag {
        let encoder = NBTEncoder(userInfo: userInfo)
        try value.encode(to: encoder)
        return try encoder.box.materialize(codingPath: [])
    }

    public func encodeRoot<T: Encodable>(_ value: T, rootName: String = "") throws -> NBTTag.Root {
        let tag = try encodeTag(value)
        guard let tagType = tag.tagType, tagType != .end else {
            throw NBTTag.CodingError.invalidRootTag
        }
        return NBTTag.Root(name: rootName, tag: tag)
    }

    public func encode<T: Encodable>(_ value: T, rootName: String = "") throws -> Data {
        try encode(encodeRoot(value, rootName: rootName))
    }

    public func encode(_ tag: NBTTag, rootName: String = "") throws -> Data {
        try encode(NBTTag.Root(name: rootName, tag: tag))
    }

    public func encode(_ root: NBTTag.Root) throws -> Data {
        guard let tagType = root.tag.tagType, tagType != .end else {
            throw NBTTag.CodingError.invalidRootTag
        }

        try validate(tag: root.tag)

        var writer = BinaryWriter()
        writer.writeUInt8(tagType.rawValue)
        try writer.writeString(root.name)
        try writer.writePayload(root.tag)
        return Data(writer.bytes)
    }
}

public final class NBTDecoder: Decoder {
    public var codingPath: [any CodingKey]
    public var userInfo: [CodingUserInfoKey: Any]

    private let tag: NBTTag?

    public init(userInfo: [CodingUserInfoKey: Any] = [:]) {
        self.codingPath = []
        self.userInfo = userInfo
        self.tag = nil
    }

    fileprivate init(
        tag: NBTTag,
        codingPath: [any CodingKey],
        userInfo: [CodingUserInfoKey: Any]
    ) {
        self.codingPath = codingPath
        self.userInfo = userInfo
        self.tag = tag
    }

    public func container<Key>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        let tag = try requireTag()
        guard case .compound(let values) = tag else {
            throw typeMismatch(type, for: tag, at: codingPath)
        }

        let container = NBTKeyedDecodingContainer<Key>(
            codingPath: codingPath,
            userInfo: userInfo,
            values: values
        )
        return KeyedDecodingContainer(container)
    }

    public func unkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let tag = try requireTag()
        guard case .list(let values) = tag else {
            throw typeMismatch([NBTTag].self, for: tag, at: codingPath)
        }

        return NBTUnkeyedDecodingContainer(
            codingPath: codingPath,
            userInfo: userInfo,
            values: values
        )
    }

    public func singleValueContainer() throws -> any SingleValueDecodingContainer {
        NBTSingleValueDecodingContainer(codingPath: codingPath, userInfo: userInfo, tag: try requireTag())
    }

    public func decode(_ data: Data) throws -> NBTTag {
        try decodeRoot(data).tag
    }

    public func decodeRoot(_ data: Data) throws -> NBTTag.Root {
        var reader = BinaryReader(data: data)
        let typeID = try reader.readUInt8()
        guard let type = NBTTag.TagType(rawValue: typeID), type != .end else {
            throw NBTTag.CodingError.invalidRootTag
        }

        let name = try reader.readString()
        let tag = try reader.readPayload(for: type)
        try reader.ensureFinished()
        return NBTTag.Root(name: name, tag: tag)
    }

    public func decode<T: Decodable>(_ type: T.Type, from tag: NBTTag) throws -> T {
        let decoder = NBTDecoder(tag: tag, codingPath: [], userInfo: userInfo)
        return try T(from: decoder)
    }

    public func decode<T: Decodable>(_ type: T.Type, from root: NBTTag.Root) throws -> T {
        try decode(type, from: root.tag)
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decode(type, from: decodeRoot(data))
    }

    public func decode<T: Decodable>(_ type: T.Type, fromFileAt url: URL) throws -> T {
        try decode(type, from: try loadNBTData(from: url))
    }

    public func decodeRoot(fromFileAt url: URL) throws -> NBTTag.Root {
        try decodeRoot(try loadNBTData(from: url))
    }

    private func requireTag() throws -> NBTTag {
        guard let tag else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "NBTDecoder has no current tag"
                )
            )
        }
        return tag
    }
}

private func loadNBTData(from url: URL) throws -> Data {
    let data = try Data(contentsOf: url)
    return try gunzipIfNeeded(data)
}

private func gunzipIfNeeded(_ data: Data) throws -> Data {
    guard data.count >= 2 else {
        return data
    }
    guard data[0] == 0x1f, data[1] == 0x8b else {
        return data
    }

    #if canImport(zlib)
    var stream = z_stream()
    let windowBits = MAX_WBITS + 16
    let initResult = inflateInit2_(
        &stream,
        windowBits,
        ZLIB_VERSION,
        Int32(MemoryLayout<z_stream>.size)
    )
    guard initResult == Z_OK else {
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: [],
                debugDescription: "Failed to initialize gzip decompression for NBT file"
            )
        )
    }
    defer {
        inflateEnd(&stream)
    }

    return try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress else {
            return Data()
        }

        stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress)
        stream.avail_in = UInt32(rawBuffer.count)

        let chunkSize = 64 * 1024
        var output = Data()
        var status: Int32 = Z_OK

        repeat {
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            status = chunk.withUnsafeMutableBufferPointer { buffer in
                stream.next_out = buffer.baseAddress
                stream.avail_out = UInt32(buffer.count)
                return inflate(&stream, Z_NO_FLUSH)
            }

            guard status == Z_OK || status == Z_STREAM_END else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "Failed to decompress gzip-compressed NBT file"
                    )
                )
            }

            let produced = chunkSize - Int(stream.avail_out)
            output.append(contentsOf: chunk.prefix(produced))
        } while status != Z_STREAM_END

        return output
    }
    #else
    throw DecodingError.dataCorrupted(
        DecodingError.Context(
            codingPath: [],
            debugDescription: "Gzip-compressed NBT files are unsupported on this platform"
        )
    )
    #endif
}

private extension NBTTag {
    enum TagType: UInt8 {
        case end = 0
        case byte = 1
        case short = 2
        case int = 3
        case long = 4
        case float = 5
        case double = 6
        case byteArray = 7
        case string = 8
        case list = 9
        case compound = 10
        case intArray = 11
        case longArray = 12
    }

    var tagType: TagType? {
        switch self {
        case .end:
            return .end
        case .byte:
            return .byte
        case .short:
            return .short
        case .int:
            return .int
        case .long:
            return .long
        case .float:
            return .float
        case .double:
            return .double
        case .byteArray:
            return .byteArray
        case .string:
            return .string
        case .list:
            return .list
        case .compound:
            return .compound
        case .intArray:
            return .intArray
        case .longArray:
            return .longArray
        }
    }

    var typeDescription: String {
        switch self {
        case .end:
            return "TAG_End"
        case .byte:
            return "TAG_Byte"
        case .short:
            return "TAG_Short"
        case .int:
            return "TAG_Int"
        case .long:
            return "TAG_Long"
        case .float:
            return "TAG_Float"
        case .double:
            return "TAG_Double"
        case .byteArray:
            return "TAG_Byte_Array"
        case .string:
            return "TAG_String"
        case .list:
            return "TAG_List"
        case .compound:
            return "TAG_Compound"
        case .intArray:
            return "TAG_Int_Array"
        case .longArray:
            return "TAG_Long_Array"
        }
    }
}

private final class NBTEncodingBox {
    enum Storage {
        case unset
        case tag(NBTTag)
        case keyed(NBTKeyedStorage)
        case unkeyed(NBTUnkeyedStorage)
    }

    private(set) var storage: Storage = .unset

    func makeKeyedStorage() -> NBTKeyedStorage {
        switch storage {
        case .unset:
            let keyed = NBTKeyedStorage()
            storage = .keyed(keyed)
            return keyed
        case .keyed(let keyed):
            return keyed
        case .tag, .unkeyed:
            preconditionFailure("Attempted to create a keyed container after encoding a different container type")
        }
    }

    func makeUnkeyedStorage() -> NBTUnkeyedStorage {
        switch storage {
        case .unset:
            let unkeyed = NBTUnkeyedStorage()
            storage = .unkeyed(unkeyed)
            return unkeyed
        case .unkeyed(let unkeyed):
            return unkeyed
        case .tag, .keyed:
            preconditionFailure("Attempted to create an unkeyed container after encoding a different container type")
        }
    }

    func set(tag: NBTTag) {
        switch storage {
        case .unset, .tag:
            storage = .tag(tag)
        case .keyed, .unkeyed:
            preconditionFailure("Attempted to encode a single value after encoding a container")
        }
    }

    func materialize(codingPath: [any CodingKey]) throws -> NBTTag {
        switch storage {
        case .unset:
            throw EncodingError.invalidValue(
                NSNull(),
                EncodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "No value was encoded into the NBT container"
                )
            )
        case .tag(let tag):
            return tag
        case .keyed(let keyed):
            var values: [String: NBTTag] = [:]
            for (key, valueBox) in keyed.values {
                values[key] = try valueBox.materialize(codingPath: codingPath.appending(NBTAnyCodingKey(stringValue: key)!))
            }
            let tag = NBTTag.compound(values)
            try validate(tag: tag)
            return tag
        case .unkeyed(let unkeyed):
            var values: [NBTTag] = []
            values.reserveCapacity(unkeyed.values.count)
            for (index, valueBox) in unkeyed.values.enumerated() {
                values.append(try valueBox.materialize(codingPath: codingPath.appending(NBTAnyCodingKey(index: index))))
            }
            let tag = NBTTag.list(values)
            try validate(tag: tag)
            return tag
        }
    }
}

private final class NBTKeyedStorage {
    var values: [String: NBTEncodingBox] = [:]
}

private final class NBTUnkeyedStorage {
    var values: [NBTEncodingBox] = []
}

private struct NBTKeyedEncodingContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    typealias Key = Key

    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]
    let storage: NBTKeyedStorage

    mutating func encodeNil(forKey key: Key) throws {
        storage.values.removeValue(forKey: key.stringValue)
    }

    mutating func encode(_ value: Bool, forKey key: Key) throws {
        set(.byte(value ? 1 : 0), forKey: key)
    }

    mutating func encode(_ value: String, forKey key: Key) throws {
        set(.string(value), forKey: key)
    }

    mutating func encode(_ value: Double, forKey key: Key) throws {
        set(.double(value), forKey: key)
    }

    mutating func encode(_ value: Float, forKey key: Key) throws {
        set(.float(value), forKey: key)
    }

    mutating func encode(_ value: Int, forKey key: Key) throws {
        throw unsupportedIntegerEncodingError(value, at: codingPath.appending(key))
    }

    mutating func encode(_ value: Int8, forKey key: Key) throws {
        set(.byte(value), forKey: key)
    }

    mutating func encode(_ value: Int16, forKey key: Key) throws {
        set(.short(value), forKey: key)
    }

    mutating func encode(_ value: Int32, forKey key: Key) throws {
        set(.int(value), forKey: key)
    }

    mutating func encode(_ value: Int64, forKey key: Key) throws {
        set(.long(value), forKey: key)
    }

    mutating func encode(_ value: UInt, forKey key: Key) throws {
        throw unsupportedIntegerEncodingError(value, at: codingPath.appending(key))
    }

    mutating func encode(_ value: UInt8, forKey key: Key) throws {
        throw unsupportedIntegerEncodingError(value, at: codingPath.appending(key))
    }

    mutating func encode(_ value: UInt16, forKey key: Key) throws {
        throw unsupportedIntegerEncodingError(value, at: codingPath.appending(key))
    }

    mutating func encode(_ value: UInt32, forKey key: Key) throws {
        throw unsupportedIntegerEncodingError(value, at: codingPath.appending(key))
    }

    mutating func encode(_ value: UInt64, forKey key: Key) throws {
        throw unsupportedIntegerEncodingError(value, at: codingPath.appending(key))
    }

    mutating func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        let childBox = NBTEncodingBox()
        storage.values[key.stringValue] = childBox
        let childEncoder = NBTEncoder(
            codingPath: codingPath.appending(key),
            userInfo: userInfo,
            box: childBox
        )
        try value.encode(to: childEncoder)
    }

    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: Key) -> KeyedEncodingContainer<NestedKey> {
        let childBox = NBTEncodingBox()
        storage.values[key.stringValue] = childBox
        let container = NBTKeyedEncodingContainer<NestedKey>(
            codingPath: codingPath.appending(key),
            userInfo: userInfo,
            storage: childBox.makeKeyedStorage()
        )
        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer(forKey key: Key) -> any UnkeyedEncodingContainer {
        let childBox = NBTEncodingBox()
        storage.values[key.stringValue] = childBox
        return NBTUnkeyedEncodingContainer(
            codingPath: codingPath.appending(key),
            userInfo: userInfo,
            storage: childBox.makeUnkeyedStorage()
        )
    }

    mutating func superEncoder() -> any Encoder {
        let key = NBTAnyCodingKey.superKey
        let childBox = NBTEncodingBox()
        storage.values[key.stringValue] = childBox
        return NBTEncoder(codingPath: codingPath.appending(key), userInfo: userInfo, box: childBox)
    }

    mutating func superEncoder(forKey key: Key) -> any Encoder {
        let childBox = NBTEncodingBox()
        storage.values[key.stringValue] = childBox
        return NBTEncoder(codingPath: codingPath.appending(key), userInfo: userInfo, box: childBox)
    }

    private func set(_ tag: NBTTag, forKey key: Key) {
        let box = NBTEncodingBox()
        box.set(tag: tag)
        storage.values[key.stringValue] = box
    }
}

private struct NBTUnkeyedEncodingContainer: UnkeyedEncodingContainer {
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]
    let storage: NBTUnkeyedStorage

    var count: Int { storage.values.count }

    mutating func encodeNil() throws {
        throw unsupportedNilEncodingError(at: codingPath.appending(NBTAnyCodingKey(index: count)))
    }

    mutating func encode(_ value: Bool) throws {
        append(.byte(value ? 1 : 0))
    }

    mutating func encode(_ value: String) throws {
        append(.string(value))
    }

    mutating func encode(_ value: Double) throws {
        append(.double(value))
    }

    mutating func encode(_ value: Float) throws {
        append(.float(value))
    }

    mutating func encode(_ value: Int) throws {
        throw unsupportedIntegerEncodingError(value, at: codingPath.appending(NBTAnyCodingKey(index: count)))
    }

    mutating func encode(_ value: Int8) throws {
        append(.byte(value))
    }

    mutating func encode(_ value: Int16) throws {
        append(.short(value))
    }

    mutating func encode(_ value: Int32) throws {
        append(.int(value))
    }

    mutating func encode(_ value: Int64) throws {
        append(.long(value))
    }

    mutating func encode(_ value: UInt) throws {
        throw unsupportedIntegerEncodingError(value, at: codingPath.appending(NBTAnyCodingKey(index: count)))
    }

    mutating func encode(_ value: UInt8) throws {
        throw unsupportedIntegerEncodingError(value, at: codingPath.appending(NBTAnyCodingKey(index: count)))
    }

    mutating func encode(_ value: UInt16) throws {
        throw unsupportedIntegerEncodingError(value, at: codingPath.appending(NBTAnyCodingKey(index: count)))
    }

    mutating func encode(_ value: UInt32) throws {
        throw unsupportedIntegerEncodingError(value, at: codingPath.appending(NBTAnyCodingKey(index: count)))
    }

    mutating func encode(_ value: UInt64) throws {
        throw unsupportedIntegerEncodingError(value, at: codingPath.appending(NBTAnyCodingKey(index: count)))
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let childBox = NBTEncodingBox()
        storage.values.append(childBox)
        let childEncoder = NBTEncoder(
            codingPath: codingPath.appending(NBTAnyCodingKey(index: storage.values.count - 1)),
            userInfo: userInfo,
            box: childBox
        )
        try value.encode(to: childEncoder)
    }

    mutating func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> {
        let childBox = NBTEncodingBox()
        storage.values.append(childBox)
        let container = NBTKeyedEncodingContainer<NestedKey>(
            codingPath: codingPath.appending(NBTAnyCodingKey(index: storage.values.count - 1)),
            userInfo: userInfo,
            storage: childBox.makeKeyedStorage()
        )
        return KeyedEncodingContainer(container)
    }

    mutating func nestedUnkeyedContainer() -> any UnkeyedEncodingContainer {
        let childBox = NBTEncodingBox()
        storage.values.append(childBox)
        return NBTUnkeyedEncodingContainer(
            codingPath: codingPath.appending(NBTAnyCodingKey(index: storage.values.count - 1)),
            userInfo: userInfo,
            storage: childBox.makeUnkeyedStorage()
        )
    }

    mutating func superEncoder() -> any Encoder {
        let childBox = NBTEncodingBox()
        storage.values.append(childBox)
        return NBTEncoder(
            codingPath: codingPath.appending(NBTAnyCodingKey(index: storage.values.count - 1)),
            userInfo: userInfo,
            box: childBox
        )
    }

    private func append(_ tag: NBTTag) {
        let box = NBTEncodingBox()
        box.set(tag: tag)
        storage.values.append(box)
    }
}

private struct NBTSingleValueEncodingContainer: SingleValueEncodingContainer {
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]
    let box: NBTEncodingBox

    mutating func encodeNil() throws {
        throw unsupportedNilEncodingError(at: codingPath)
    }

    mutating func encode(_ value: Bool) throws {
        box.set(tag: .byte(value ? 1 : 0))
    }

    mutating func encode(_ value: String) throws {
        box.set(tag: .string(value))
    }

    mutating func encode(_ value: Double) throws {
        box.set(tag: .double(value))
    }

    mutating func encode(_ value: Float) throws {
        box.set(tag: .float(value))
    }

    mutating func encode(_ value: Int) throws {
        throw unsupportedIntegerEncodingError(value, at: codingPath)
    }

    mutating func encode(_ value: Int8) throws {
        box.set(tag: .byte(value))
    }

    mutating func encode(_ value: Int16) throws {
        box.set(tag: .short(value))
    }

    mutating func encode(_ value: Int32) throws {
        box.set(tag: .int(value))
    }

    mutating func encode(_ value: Int64) throws {
        box.set(tag: .long(value))
    }

    mutating func encode(_ value: UInt) throws {
        throw unsupportedIntegerEncodingError(value, at: codingPath)
    }

    mutating func encode(_ value: UInt8) throws {
        throw unsupportedIntegerEncodingError(value, at: codingPath)
    }

    mutating func encode(_ value: UInt16) throws {
        throw unsupportedIntegerEncodingError(value, at: codingPath)
    }

    mutating func encode(_ value: UInt32) throws {
        throw unsupportedIntegerEncodingError(value, at: codingPath)
    }

    mutating func encode(_ value: UInt64) throws {
        throw unsupportedIntegerEncodingError(value, at: codingPath)
    }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let childEncoder = NBTEncoder(codingPath: codingPath, userInfo: userInfo, box: box)
        try value.encode(to: childEncoder)
    }
}

private struct NBTKeyedDecodingContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    typealias Key = Key

    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]
    let values: [String: NBTTag]

    var allKeys: [Key] {
        values.keys.compactMap(Key.init(stringValue:))
    }

    func contains(_ key: Key) -> Bool {
        values[key.stringValue] != nil
    }

    func decodeNil(forKey key: Key) throws -> Bool {
        values[key.stringValue] == nil
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool {
        try decodeBool(from: try value(for: key), at: codingPath.appending(key))
    }

    func decode(_ type: String.Type, forKey key: Key) throws -> String {
        try decodeString(from: try value(for: key), at: codingPath.appending(key))
    }

    func decode(_ type: Double.Type, forKey key: Key) throws -> Double {
        try decodeDouble(from: try value(for: key), at: codingPath.appending(key))
    }

    func decode(_ type: Float.Type, forKey key: Key) throws -> Float {
        try decodeFloat(from: try value(for: key), at: codingPath.appending(key))
    }

    func decode(_ type: Int.Type, forKey key: Key) throws -> Int {
        throw unsupportedIntegerDecodingError(type, from: try value(for: key), at: codingPath.appending(key))
    }

    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 {
        try decodeInt8(from: try value(for: key), at: codingPath.appending(key))
    }

    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 {
        try decodeInt16(from: try value(for: key), at: codingPath.appending(key))
    }

    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 {
        try decodeInt32(from: try value(for: key), at: codingPath.appending(key))
    }

    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 {
        try decodeInt64(from: try value(for: key), at: codingPath.appending(key))
    }

    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt {
        throw unsupportedIntegerDecodingError(type, from: try value(for: key), at: codingPath.appending(key))
    }

    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 {
        throw unsupportedIntegerDecodingError(type, from: try value(for: key), at: codingPath.appending(key))
    }

    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 {
        throw unsupportedIntegerDecodingError(type, from: try value(for: key), at: codingPath.appending(key))
    }

    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 {
        throw unsupportedIntegerDecodingError(type, from: try value(for: key), at: codingPath.appending(key))
    }

    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 {
        throw unsupportedIntegerDecodingError(type, from: try value(for: key), at: codingPath.appending(key))
    }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        let tag = try value(for: key)
        return try T(
            from: NBTDecoder(
                tag: tag,
                codingPath: codingPath.appending(key),
                userInfo: userInfo
            )
        )
    }

    func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        let tag = try value(for: key)
        guard case .compound(let nestedValues) = tag else {
            throw typeMismatch(type, for: tag, at: codingPath.appending(key))
        }
        let container = NBTKeyedDecodingContainer<NestedKey>(
            codingPath: codingPath.appending(key),
            userInfo: userInfo,
            values: nestedValues
        )
        return KeyedDecodingContainer(container)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> any UnkeyedDecodingContainer {
        let tag = try value(for: key)
        guard case .list(let nestedValues) = tag else {
            throw typeMismatch([NBTTag].self, for: tag, at: codingPath.appending(key))
        }
        return NBTUnkeyedDecodingContainer(
            codingPath: codingPath.appending(key),
            userInfo: userInfo,
            values: nestedValues
        )
    }

    func superDecoder() throws -> any Decoder {
        let key = NBTAnyCodingKey.superKey
        guard let tag = values[key.stringValue] else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "No value associated with key \(key.stringValue)"
                )
            )
        }
        return NBTDecoder(tag: tag, codingPath: codingPath.appending(key), userInfo: userInfo)
    }

    func superDecoder(forKey key: Key) throws -> any Decoder {
        let tag = try value(for: key)
        return NBTDecoder(tag: tag, codingPath: codingPath.appending(key), userInfo: userInfo)
    }

    private func value(for key: Key) throws -> NBTTag {
        guard let value = values[key.stringValue] else {
            throw DecodingError.keyNotFound(
                key,
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "No value associated with key \(key.stringValue)"
                )
            )
        }
        return value
    }
}

private struct NBTUnkeyedDecodingContainer: UnkeyedDecodingContainer {
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]
    let values: [NBTTag]

    var count: Int? { values.count }
    var currentIndex = 0
    var isAtEnd: Bool { currentIndex >= values.count }

    mutating func decodeNil() throws -> Bool {
        false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool {
        let path = codingPath.appending(NBTAnyCodingKey(index: currentIndex))
        let value = try nextValue()
        return try decodeBool(from: value, at: path)
    }

    mutating func decode(_ type: String.Type) throws -> String {
        let path = codingPath.appending(NBTAnyCodingKey(index: currentIndex))
        let value = try nextValue()
        return try decodeString(from: value, at: path)
    }

    mutating func decode(_ type: Double.Type) throws -> Double {
        let path = codingPath.appending(NBTAnyCodingKey(index: currentIndex))
        let value = try nextValue()
        return try decodeDouble(from: value, at: path)
    }

    mutating func decode(_ type: Float.Type) throws -> Float {
        let path = codingPath.appending(NBTAnyCodingKey(index: currentIndex))
        let value = try nextValue()
        return try decodeFloat(from: value, at: path)
    }

    mutating func decode(_ type: Int.Type) throws -> Int {
        let path = codingPath.appending(NBTAnyCodingKey(index: currentIndex))
        let value = try nextValue()
        throw unsupportedIntegerDecodingError(type, from: value, at: path)
    }

    mutating func decode(_ type: Int8.Type) throws -> Int8 {
        let path = codingPath.appending(NBTAnyCodingKey(index: currentIndex))
        let value = try nextValue()
        return try decodeInt8(from: value, at: path)
    }

    mutating func decode(_ type: Int16.Type) throws -> Int16 {
        let path = codingPath.appending(NBTAnyCodingKey(index: currentIndex))
        let value = try nextValue()
        return try decodeInt16(from: value, at: path)
    }

    mutating func decode(_ type: Int32.Type) throws -> Int32 {
        let path = codingPath.appending(NBTAnyCodingKey(index: currentIndex))
        let value = try nextValue()
        return try decodeInt32(from: value, at: path)
    }

    mutating func decode(_ type: Int64.Type) throws -> Int64 {
        let path = codingPath.appending(NBTAnyCodingKey(index: currentIndex))
        let value = try nextValue()
        return try decodeInt64(from: value, at: path)
    }

    mutating func decode(_ type: UInt.Type) throws -> UInt {
        let path = codingPath.appending(NBTAnyCodingKey(index: currentIndex))
        let value = try nextValue()
        throw unsupportedIntegerDecodingError(type, from: value, at: path)
    }

    mutating func decode(_ type: UInt8.Type) throws -> UInt8 {
        let path = codingPath.appending(NBTAnyCodingKey(index: currentIndex))
        let value = try nextValue()
        throw unsupportedIntegerDecodingError(type, from: value, at: path)
    }

    mutating func decode(_ type: UInt16.Type) throws -> UInt16 {
        let path = codingPath.appending(NBTAnyCodingKey(index: currentIndex))
        let value = try nextValue()
        throw unsupportedIntegerDecodingError(type, from: value, at: path)
    }

    mutating func decode(_ type: UInt32.Type) throws -> UInt32 {
        let path = codingPath.appending(NBTAnyCodingKey(index: currentIndex))
        let value = try nextValue()
        throw unsupportedIntegerDecodingError(type, from: value, at: path)
    }

    mutating func decode(_ type: UInt64.Type) throws -> UInt64 {
        let path = codingPath.appending(NBTAnyCodingKey(index: currentIndex))
        let value = try nextValue()
        throw unsupportedIntegerDecodingError(type, from: value, at: path)
    }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let path = codingPath.appending(NBTAnyCodingKey(index: currentIndex))
        let value = try nextValue()
        return try T(from: NBTDecoder(tag: value, codingPath: path, userInfo: userInfo))
    }

    mutating func nestedContainer<NestedKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        let path = codingPath.appending(NBTAnyCodingKey(index: currentIndex))
        let value = try nextValue()
        guard case .compound(let nestedValues) = value else {
            throw typeMismatch(type, for: value, at: path)
        }

        let container = NBTKeyedDecodingContainer<NestedKey>(
            codingPath: path,
            userInfo: userInfo,
            values: nestedValues
        )
        return KeyedDecodingContainer(container)
    }

    mutating func nestedUnkeyedContainer() throws -> any UnkeyedDecodingContainer {
        let path = codingPath.appending(NBTAnyCodingKey(index: currentIndex))
        let value = try nextValue()
        guard case .list(let nestedValues) = value else {
            throw typeMismatch([NBTTag].self, for: value, at: path)
        }
        return NBTUnkeyedDecodingContainer(codingPath: path, userInfo: userInfo, values: nestedValues)
    }

    mutating func superDecoder() throws -> any Decoder {
        let path = codingPath.appending(NBTAnyCodingKey(index: currentIndex))
        let value = try nextValue()
        return NBTDecoder(tag: value, codingPath: path, userInfo: userInfo)
    }

    private mutating func nextValue() throws -> NBTTag {
        guard !isAtEnd else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "Unkeyed container is at end"
                )
            )
        }
        defer { currentIndex += 1 }
        return values[currentIndex]
    }
}

private struct NBTSingleValueDecodingContainer: SingleValueDecodingContainer {
    let codingPath: [any CodingKey]
    let userInfo: [CodingUserInfoKey: Any]
    let tag: NBTTag

    func decodeNil() -> Bool {
        false
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        try decodeBool(from: tag, at: codingPath)
    }

    func decode(_ type: String.Type) throws -> String {
        try decodeString(from: tag, at: codingPath)
    }

    func decode(_ type: Double.Type) throws -> Double {
        try decodeDouble(from: tag, at: codingPath)
    }

    func decode(_ type: Float.Type) throws -> Float {
        try decodeFloat(from: tag, at: codingPath)
    }

    func decode(_ type: Int.Type) throws -> Int {
        throw unsupportedIntegerDecodingError(type, from: tag, at: codingPath)
    }

    func decode(_ type: Int8.Type) throws -> Int8 {
        try decodeInt8(from: tag, at: codingPath)
    }

    func decode(_ type: Int16.Type) throws -> Int16 {
        try decodeInt16(from: tag, at: codingPath)
    }

    func decode(_ type: Int32.Type) throws -> Int32 {
        try decodeInt32(from: tag, at: codingPath)
    }

    func decode(_ type: Int64.Type) throws -> Int64 {
        try decodeInt64(from: tag, at: codingPath)
    }

    func decode(_ type: UInt.Type) throws -> UInt {
        throw unsupportedIntegerDecodingError(type, from: tag, at: codingPath)
    }

    func decode(_ type: UInt8.Type) throws -> UInt8 {
        throw unsupportedIntegerDecodingError(type, from: tag, at: codingPath)
    }

    func decode(_ type: UInt16.Type) throws -> UInt16 {
        throw unsupportedIntegerDecodingError(type, from: tag, at: codingPath)
    }

    func decode(_ type: UInt32.Type) throws -> UInt32 {
        throw unsupportedIntegerDecodingError(type, from: tag, at: codingPath)
    }

    func decode(_ type: UInt64.Type) throws -> UInt64 {
        throw unsupportedIntegerDecodingError(type, from: tag, at: codingPath)
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try T(from: NBTDecoder(tag: tag, codingPath: codingPath, userInfo: userInfo))
    }
}

private func validate(tag: NBTTag) throws {
    switch tag {
    case .end:
        return
    case .byte, .short, .int, .long, .float, .double, .byteArray, .intArray, .longArray, .string:
        return
    case .list(let values):
        var expectedType: NBTTag.TagType?
        for value in values {
            guard let valueType = value.tagType, valueType != .end else {
                throw NBTTag.CodingError.invalidListElementType(NBTTag.TagType.end.rawValue)
            }
            if let expectedType, expectedType != valueType {
                throw NBTTag.CodingError.nonHomogeneousList(expected: expectedType.rawValue, actual: valueType.rawValue)
            }
            try validate(tag: value)
            expectedType = expectedType ?? valueType
        }
    case .compound(let values):
        for (_, value) in values {
            guard value != .end else {
                throw NBTTag.CodingError.invalidCompoundEntry
            }
            try validate(tag: value)
        }
    }
}

private func unsupportedIntegerEncodingError<T>(_ value: T, at codingPath: [any CodingKey]) -> EncodingError {
    EncodingError.invalidValue(
        value,
        EncodingError.Context(
            codingPath: codingPath,
            debugDescription: "NBTEncoder does not support Int or UInt. Use an explicit fixed-width integer type."
        )
    )
}

private func unsupportedNilEncodingError(at codingPath: [any CodingKey]) -> EncodingError {
    EncodingError.invalidValue(
        NSNull(),
        EncodingError.Context(
            codingPath: codingPath,
            debugDescription: "NBT does not support nil values"
        )
    )
}

private func unsupportedIntegerDecodingError<T>(_ type: T.Type, from tag: NBTTag, at codingPath: [any CodingKey]) -> DecodingError {
    DecodingError.typeMismatch(
        type,
        DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "NBTDecoder does not support Int or UInt. Decode an explicit fixed-width integer type from \(tag.typeDescription)."
        )
    )
}

private func typeMismatch<T>(_ type: T.Type, for tag: NBTTag, at codingPath: [any CodingKey]) -> DecodingError {
    DecodingError.typeMismatch(
        type,
        DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Expected \(type) but found \(tag.typeDescription)"
        )
    )
}

private func invalidBooleanValue(_ value: Int8, at codingPath: [any CodingKey]) -> DecodingError {
    DecodingError.dataCorrupted(
        DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Expected TAG_Byte boolean value 0 or 1, found \(value)"
        )
    )
}

private func decodeBool(from tag: NBTTag, at codingPath: [any CodingKey]) throws -> Bool {
    guard case .byte(let value) = tag else {
        throw typeMismatch(Bool.self, for: tag, at: codingPath)
    }
    switch value {
    case 0:
        return false
    case 1:
        return true
    default:
        throw invalidBooleanValue(value, at: codingPath)
    }
}

private func decodeString(from tag: NBTTag, at codingPath: [any CodingKey]) throws -> String {
    guard case .string(let value) = tag else {
        throw typeMismatch(String.self, for: tag, at: codingPath)
    }
    return value
}

private func decodeDouble(from tag: NBTTag, at codingPath: [any CodingKey]) throws -> Double {
    guard case .double(let value) = tag else {
        throw typeMismatch(Double.self, for: tag, at: codingPath)
    }
    return value
}

private func decodeFloat(from tag: NBTTag, at codingPath: [any CodingKey]) throws -> Float {
    guard case .float(let value) = tag else {
        throw typeMismatch(Float.self, for: tag, at: codingPath)
    }
    return value
}

private func decodeInt8(from tag: NBTTag, at codingPath: [any CodingKey]) throws -> Int8 {
    guard case .byte(let value) = tag else {
        throw typeMismatch(Int8.self, for: tag, at: codingPath)
    }
    return value
}

private func decodeInt16(from tag: NBTTag, at codingPath: [any CodingKey]) throws -> Int16 {
    guard case .short(let value) = tag else {
        throw typeMismatch(Int16.self, for: tag, at: codingPath)
    }
    return value
}

private func decodeInt32(from tag: NBTTag, at codingPath: [any CodingKey]) throws -> Int32 {
    guard case .int(let value) = tag else {
        throw typeMismatch(Int32.self, for: tag, at: codingPath)
    }
    return value
}

private func decodeInt64(from tag: NBTTag, at codingPath: [any CodingKey]) throws -> Int64 {
    guard case .long(let value) = tag else {
        throw typeMismatch(Int64.self, for: tag, at: codingPath)
    }
    return value
}

private struct NBTAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }

    init(index: Int) {
        self.stringValue = String(index)
        self.intValue = index
    }

    static let superKey = NBTAnyCodingKey(stringValue: "super")!
}

private extension Array where Element == any CodingKey {
    func appending(_ key: some CodingKey) -> [any CodingKey] {
        var updated = self
        updated.append(key)
        return updated
    }
}

private struct BinaryReader {
    private let bytes: [UInt8]
    private var index = 0

    init(data: Data) {
        self.bytes = Array(data)
    }

    mutating func ensureFinished() throws {
        let remaining = bytes.count - index
        guard remaining == 0 else {
            throw NBTTag.CodingError.trailingBytes(remaining)
        }
    }

    mutating func readUInt8() throws -> UInt8 {
        try ensureAvailable(1)
        defer { index += 1 }
        return bytes[index]
    }

    mutating func readInt8() throws -> Int8 {
        Int8(bitPattern: try readUInt8())
    }

    mutating func readUInt16() throws -> UInt16 {
        let high = UInt16(try readUInt8())
        let low = UInt16(try readUInt8())
        return (high << 8) | low
    }

    mutating func readInt16() throws -> Int16 {
        Int16(bitPattern: try readUInt16())
    }

    mutating func readUInt32() throws -> UInt32 {
        let a = UInt32(try readUInt8())
        let b = UInt32(try readUInt8())
        let c = UInt32(try readUInt8())
        let d = UInt32(try readUInt8())
        return (a << 24) | (b << 16) | (c << 8) | d
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    mutating func readUInt64() throws -> UInt64 {
        let a = UInt64(try readUInt8())
        let b = UInt64(try readUInt8())
        let c = UInt64(try readUInt8())
        let d = UInt64(try readUInt8())
        let e = UInt64(try readUInt8())
        let f = UInt64(try readUInt8())
        let g = UInt64(try readUInt8())
        let h = UInt64(try readUInt8())
        return (a << 56) | (b << 48) | (c << 40) | (d << 32) | (e << 24) | (f << 16) | (g << 8) | h
    }

    mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readUInt64())
    }

    mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    mutating func readDouble() throws -> Double {
        Double(bitPattern: try readUInt64())
    }

    mutating func readString() throws -> String {
        let length = Int(try readUInt16())
        let stringBytes = try readBytes(count: length)
        guard let string = String(bytes: stringBytes, encoding: .utf8) else {
            throw NBTTag.CodingError.invalidUTF8String
        }
        return string
    }

    mutating func readPayload(for type: NBTTag.TagType) throws -> NBTTag {
        switch type {
        case .end:
            return .end
        case .byte:
            return .byte(try readInt8())
        case .short:
            return .short(try readInt16())
        case .int:
            return .int(try readInt32())
        case .long:
            return .long(try readInt64())
        case .float:
            return .float(try readFloat())
        case .double:
            return .double(try readDouble())
        case .byteArray:
            return .byteArray(try readArray(of: { reader in
                try reader.readInt8()
            }))
        case .string:
            return .string(try readString())
        case .list:
            let elementTypeID = try readUInt8()
            let length = try readLength()
            guard let elementType = NBTTag.TagType(rawValue: elementTypeID) else {
                throw NBTTag.CodingError.invalidListElementType(elementTypeID)
            }
            if elementType == .end && length > 0 {
                throw NBTTag.CodingError.invalidListElementType(elementTypeID)
            }

            var values: [NBTTag] = []
            values.reserveCapacity(length)
            for _ in 0..<length {
                values.append(try readPayload(for: elementType))
            }
            return .list(values)
        case .compound:
            var values: [String: NBTTag] = [:]
            while true {
                let typeID = try readUInt8()
                guard let entryType = NBTTag.TagType(rawValue: typeID) else {
                    throw NBTTag.CodingError.invalidTagType(typeID)
                }
                if entryType == .end {
                    break
                }

                let name = try readString()
                let value = try readPayload(for: entryType)
                if value == .end {
                    throw NBTTag.CodingError.invalidCompoundEntry
                }
                values[name] = value
            }
            return .compound(values)
        case .intArray:
            return .intArray(try readArray(of: { reader in
                try reader.readInt32()
            }))
        case .longArray:
            return .longArray(try readArray(of: { reader in
                try reader.readInt64()
            }))
        }
    }

    private mutating func readLength() throws -> Int {
        let length = try readInt32()
        guard length >= 0 else {
            throw NBTTag.CodingError.negativeLength(length)
        }
        return Int(length)
    }

    private mutating func readBytes(count: Int) throws -> [UInt8] {
        try ensureAvailable(count)
        let slice = Array(bytes[index..<(index + count)])
        index += count
        return slice
    }

    private mutating func readArray<T>(of readElement: (inout BinaryReader) throws -> T) throws -> [T] {
        let length = try readLength()
        var values: [T] = []
        values.reserveCapacity(length)
        for _ in 0..<length {
            values.append(try readElement(&self))
        }
        return values
    }

    private func ensureAvailable(_ count: Int) throws {
        let remaining = bytes.count - index
        guard remaining >= count else {
            throw NBTTag.CodingError.unexpectedEOF(expected: count, remaining: remaining)
        }
    }
}

private struct BinaryWriter {
    var bytes: [UInt8] = []

    mutating func writeUInt8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func writeInt8(_ value: Int8) {
        writeUInt8(UInt8(bitPattern: value))
    }

    mutating func writeUInt16(_ value: UInt16) {
        writeUInt8(UInt8((value >> 8) & 0xff))
        writeUInt8(UInt8(value & 0xff))
    }

    mutating func writeInt16(_ value: Int16) {
        writeUInt16(UInt16(bitPattern: value))
    }

    mutating func writeUInt32(_ value: UInt32) {
        writeUInt8(UInt8((value >> 24) & 0xff))
        writeUInt8(UInt8((value >> 16) & 0xff))
        writeUInt8(UInt8((value >> 8) & 0xff))
        writeUInt8(UInt8(value & 0xff))
    }

    mutating func writeInt32(_ value: Int32) {
        writeUInt32(UInt32(bitPattern: value))
    }

    mutating func writeUInt64(_ value: UInt64) {
        writeUInt8(UInt8((value >> 56) & 0xff))
        writeUInt8(UInt8((value >> 48) & 0xff))
        writeUInt8(UInt8((value >> 40) & 0xff))
        writeUInt8(UInt8((value >> 32) & 0xff))
        writeUInt8(UInt8((value >> 24) & 0xff))
        writeUInt8(UInt8((value >> 16) & 0xff))
        writeUInt8(UInt8((value >> 8) & 0xff))
        writeUInt8(UInt8(value & 0xff))
    }

    mutating func writeInt64(_ value: Int64) {
        writeUInt64(UInt64(bitPattern: value))
    }

    mutating func writeFloat(_ value: Float) {
        writeUInt32(value.bitPattern)
    }

    mutating func writeDouble(_ value: Double) {
        writeUInt64(value.bitPattern)
    }

    mutating func writeString(_ value: String) throws {
        let encoded = Array(value.utf8)
        guard encoded.count <= Int(UInt16.max) else {
            throw NBTTag.CodingError.stringTooLong(encoded.count)
        }

        writeUInt16(UInt16(encoded.count))
        bytes.append(contentsOf: encoded)
    }

    mutating func writePayload(_ tag: NBTTag) throws {
        switch tag {
        case .end:
            return
        case .byte(let value):
            writeInt8(value)
        case .short(let value):
            writeInt16(value)
        case .int(let value):
            writeInt32(value)
        case .long(let value):
            writeInt64(value)
        case .float(let value):
            writeFloat(value)
        case .double(let value):
            writeDouble(value)
        case .byteArray(let values):
            try writeLength(values.count)
            for value in values {
                writeInt8(value)
            }
        case .intArray(let values):
            try writeLength(values.count)
            for value in values {
                writeInt32(value)
            }
        case .longArray(let values):
            try writeLength(values.count)
            for value in values {
                writeInt64(value)
            }
        case .string(let value):
            try writeString(value)
        case .list(let values):
            let elementType: NBTTag.TagType
            if let first = values.first {
                guard let firstType = first.tagType, firstType != .end else {
                    throw NBTTag.CodingError.invalidListElementType(NBTTag.TagType.end.rawValue)
                }
                elementType = firstType
                for value in values.dropFirst() {
                    guard let currentType = value.tagType, currentType != .end else {
                        throw NBTTag.CodingError.invalidListElementType(NBTTag.TagType.end.rawValue)
                    }
                    guard currentType == elementType else {
                        throw NBTTag.CodingError.nonHomogeneousList(expected: elementType.rawValue, actual: currentType.rawValue)
                    }
                }
            } else {
                elementType = .end
            }

            writeUInt8(elementType.rawValue)
            try writeLength(values.count)
            for value in values {
                try writePayload(value)
            }
        case .compound(let values):
            for (name, value) in values {
                guard let type = value.tagType, type != .end else {
                    throw NBTTag.CodingError.invalidCompoundEntry
                }
                writeUInt8(type.rawValue)
                try writeString(name)
                try writePayload(value)
            }
            writeUInt8(NBTTag.TagType.end.rawValue)
        }
    }

    private mutating func writeLength(_ count: Int) throws {
        guard count <= Int(Int32.max) else {
            throw NBTTag.CodingError.lengthOutOfRange(count)
        }
        writeInt32(Int32(count))
    }
}
