import Foundation

private enum WASMValueType: UInt8 {
    case i32 = 0x7f
    case i64 = 0x7e
    case f64 = 0x7c
}

private struct WASMEncoder {
    var bytes: [UInt8] = []

    mutating func append(_ byte: UInt8) {
        self.bytes.append(byte)
    }

    mutating func append(contentsOf bytes: [UInt8]) {
        self.bytes.append(contentsOf: bytes)
    }

    mutating func appendUnsigned(_ value: Int) {
        var remaining = UInt(value)
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            self.bytes.append(byte)
        } while remaining != 0
    }

    mutating func appendSigned(_ value: Int32) {
        var remaining = value
        var hasMore = true
        while hasMore {
            var byte = UInt8(truncatingIfNeeded: remaining) & 0x7f
            remaining >>= 7
            let signBitSet = byte & 0x40 != 0
            hasMore = !((remaining == 0 && !signBitSet) || (remaining == -1 && signBitSet))
            if hasMore { byte |= 0x80 }
            self.bytes.append(byte)
        }
    }

    mutating func appendSigned(_ value: Int64) {
        var remaining = value
        var hasMore = true
        while hasMore {
            var byte = UInt8(truncatingIfNeeded: remaining) & 0x7f
            remaining >>= 7
            let signBitSet = byte & 0x40 != 0
            hasMore = !((remaining == 0 && !signBitSet) || (remaining == -1 && signBitSet))
            if hasMore { byte |= 0x80 }
            self.bytes.append(byte)
        }
    }

    mutating func appendName(_ name: String) {
        let utf8 = Array(name.utf8)
        self.appendUnsigned(utf8.count)
        self.append(contentsOf: utf8)
    }

    mutating func appendSection(id: UInt8, contents: [UInt8]) {
        self.append(id)
        self.appendUnsigned(contents.count)
        self.append(contentsOf: contents)
    }

    mutating func appendFixed(_ value: Int32) {
        var bits = value.littleEndian
        withUnsafeBytes(of: &bits) { self.append(contentsOf: Array($0)) }
    }

    mutating func appendFixed(_ value: Int64) {
        var bits = value.littleEndian
        withUnsafeBytes(of: &bits) { self.append(contentsOf: Array($0)) }
    }

    mutating func appendFixed(_ value: Double) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { self.append(contentsOf: Array($0)) }
    }
}

private func wasmValueType(_ type: DensityFunctionIRValueType) -> WASMValueType {
    switch type {
    case .i32, .condition: .i32
    case .i64: .i64
    case .f64: .f64
    }
}

private func appendFunctionType(
    parameters: [WASMValueType],
    results: [WASMValueType],
    to encoder: inout WASMEncoder
) {
    encoder.append(0x60)
    encoder.appendUnsigned(parameters.count)
    for parameter in parameters { encoder.append(parameter.rawValue) }
    encoder.appendUnsigned(results.count)
    for result in results { encoder.append(result.rawValue) }
}

private func appendLocalGet(_ index: Int, to encoder: inout WASMEncoder) {
    encoder.append(0x20)
    encoder.appendUnsigned(index)
}

private func appendLocalSet(_ index: Int, to encoder: inout WASMEncoder) {
    encoder.append(0x21)
    encoder.appendUnsigned(index)
}

private func appendDoubleConstant(_ value: Double, to encoder: inout WASMEncoder) {
    encoder.append(0x44)
    var bits = value.bitPattern.littleEndian
    withUnsafeBytes(of: &bits) { encoder.append(contentsOf: Array($0)) }
}

private func appendIntConstant(_ value: Int32, to encoder: inout WASMEncoder) {
    encoder.append(0x41)
    encoder.appendSigned(value)
}

private func appendInt64Constant(_ value: Int64, to encoder: inout WASMEncoder) {
    encoder.append(0x42)
    encoder.appendSigned(value)
}

private struct WASMBiomeTreeLayout {
    static let nodeStride = 128

    let nodeBaseOffset: Int
    let stackOffset: Int
}

private struct WASMEmbeddedOctaveLayout {
    let permutationOffset: Int
    let amplitude: Double
    let lacunarity: Double
}

private struct WASMEmbeddedNoiseLayout {
    let firstOctaves: [WASMEmbeddedOctaveLayout]
    let secondOctaves: [WASMEmbeddedOctaveLayout]
    let amplitude: Double
}

private func appendEmbeddedPerlin(
    _ snapshot: WASMPerlinNoiseSnapshot,
    to data: inout WASMEncoder
) -> Int {
    while data.bytes.count % 8 != 0 { data.append(0) }
    let offset = data.bytes.count
    data.appendFixed(snapshot.originX)
    data.appendFixed(snapshot.originY)
    data.appendFixed(snapshot.originZ)
    data.append(contentsOf: snapshot.permutation)
    return offset
}

private func appendEmbeddedNoise(
    _ snapshot: WASMDoublePerlinNoiseSnapshot,
    to data: inout WASMEncoder
) -> WASMEmbeddedNoiseLayout {
    func appendOctaves(
        _ snapshots: [WASMOctaveNoiseSnapshot],
        to data: inout WASMEncoder
    ) -> [WASMEmbeddedOctaveLayout] {
        snapshots.map {
            WASMEmbeddedOctaveLayout(
                permutationOffset: appendEmbeddedPerlin($0.noise, to: &data),
                amplitude: $0.amplitude,
                lacunarity: $0.lacunarity
            )
        }
    }
    return WASMEmbeddedNoiseLayout(
        firstOctaves: appendOctaves(snapshot.firstOctaves, to: &data),
        secondOctaves: appendOctaves(snapshot.secondOctaves, to: &data),
        amplitude: snapshot.amplitude
    )
}

private func appendDoubleLoad(offset: Int, to body: inout WASMEncoder) {
    body.append(0x2b) // f64.load
    body.appendUnsigned(3) // 8-byte alignment
    body.appendUnsigned(offset)
}

private func appendDoubleStore(to body: inout WASMEncoder) {
    body.append(0x39) // f64.store
    body.appendUnsigned(3) // 8-byte alignment
    body.appendUnsigned(0)
}

private func alignWASMOffset(_ offset: Int, to alignment: Int) -> Int {
    precondition(alignment > 0 && alignment.nonzeroBitCount == 1)
    return (offset + alignment - 1) & -alignment
}

private func appendInt32Load(offset: Int, to body: inout WASMEncoder) {
    body.append(0x28) // i32.load
    body.appendUnsigned(2) // 4-byte alignment
    body.appendUnsigned(offset)
}

private func appendInt64Load(offset: Int, to body: inout WASMEncoder) {
    body.append(0x29) // i64.load
    body.appendUnsigned(3) // 8-byte alignment
    body.appendUnsigned(offset)
}

private func appendInt32Store(to body: inout WASMEncoder) {
    body.append(0x36) // i32.store
    body.appendUnsigned(2) // 4-byte alignment
    body.appendUnsigned(0)
}

private func appendBiomeSquaredDistanceDimensionFromMemory(
    dimension: Int,
    point: [Int],
    nodeAddressLocal: Int,
    accumulatorLocal: Int,
    deltaLocal: Int,
    minimumLocal: Int,
    maximumLocal: Int,
    to body: inout WASMEncoder
) {
    appendLocalGet(nodeAddressLocal, to: &body)
    appendInt64Load(offset: 16 + dimension * 8, to: &body)
    appendLocalSet(minimumLocal, to: &body)
    appendLocalGet(nodeAddressLocal, to: &body)
    appendInt64Load(offset: 72 + dimension * 8, to: &body)
    appendLocalSet(maximumLocal, to: &body)

    appendLocalGet(point[dimension], to: &body)
    appendLocalGet(minimumLocal, to: &body)
    body.append(0x53) // i64.lt_s
    body.append(0x04) // if (result i64)
    body.append(WASMValueType.i64.rawValue)
    appendLocalGet(minimumLocal, to: &body)
    appendLocalGet(point[dimension], to: &body)
    body.append(0x7d) // i64.sub
    body.append(0x05) // else
    appendLocalGet(point[dimension], to: &body)
    appendLocalGet(maximumLocal, to: &body)
    body.append(0x55) // i64.gt_s
    body.append(0x04) // if (result i64)
    body.append(WASMValueType.i64.rawValue)
    appendLocalGet(point[dimension], to: &body)
    appendLocalGet(maximumLocal, to: &body)
    body.append(0x7d) // i64.sub
    body.append(0x05) // else
    appendInt64Constant(0, to: &body)
    body.append(0x0b) // end
    body.append(0x0b) // end
    body.append(0x22) // local.tee
    body.appendUnsigned(deltaLocal)
    appendLocalGet(deltaLocal, to: &body)
    body.append(0x7e) // i64.mul
    appendLocalGet(accumulatorLocal, to: &body)
    body.append(0x7c) // i64.add
    appendLocalSet(accumulatorLocal, to: &body)
}

/// Emits a bounded squared-distance calculation for the node at `nodeAddressLocal`.
/// Each partial sum can only increase for valid biome parameters, so abandon the node as soon as it
/// exceeds the current best distance. `br_if 0` targets the caller-provided node-skip block.
private func appendBiomeSquaredDistanceFromMemory(
    point: [Int],
    nodeAddressLocal: Int,
    accumulatorLocal: Int,
    deltaLocal: Int,
    minimumLocal: Int,
    maximumLocal: Int,
    bestDistanceLocal: Int,
    to body: inout WASMEncoder
) {
    appendInt64Constant(0, to: &body)
    appendLocalSet(accumulatorLocal, to: &body)
    for dimension in [2, 3, 5, 4, 0, 1] {
        appendBiomeSquaredDistanceDimensionFromMemory(
            dimension: dimension,
            point: point,
            nodeAddressLocal: nodeAddressLocal,
            accumulatorLocal: accumulatorLocal,
            deltaLocal: deltaLocal,
            minimumLocal: minimumLocal,
            maximumLocal: maximumLocal,
            to: &body
        )

        appendLocalGet(accumulatorLocal, to: &body)
        appendLocalGet(bestDistanceLocal, to: &body)
        body.append(0x55) // i64.gt_s
        body.append(0x0d) // br_if
        body.appendUnsigned(0)
    }

    // Offset inputs are always zero. Most biome nodes contain zero and can skip this dimension entirely.
    appendLocalGet(nodeAddressLocal, to: &body)
    appendInt32Load(offset: 12, to: &body)
    body.append(0x45) // i32.eqz
    body.append(0x04) // if offset does not contain zero
    body.append(0x40)
    appendBiomeSquaredDistanceDimensionFromMemory(
        dimension: 6,
        point: point,
        nodeAddressLocal: nodeAddressLocal,
        accumulatorLocal: accumulatorLocal,
        deltaLocal: deltaLocal,
        minimumLocal: minimumLocal,
        maximumLocal: maximumLocal,
        to: &body
    )
    body.append(0x0b) // end offset check
    appendLocalGet(accumulatorLocal, to: &body)
    appendLocalGet(bestDistanceLocal, to: &body)
    body.append(0x55) // i64.gt_s
    body.append(0x0d) // br_if
    body.appendUnsigned(0)
}

private func appendBiomeSearchFromMemory(
    tree: BiomeSearchIRTree,
    layout: WASMBiomeTreeLayout,
    point: [Int],
    resultLocal: Int,
    bestDistanceLocal: Int,
    candidateDistanceLocal: Int,
    deltaLocal: Int,
    minimumLocal: Int,
    maximumLocal: Int,
    stackCountLocal: Int,
    nodeIndexLocal: Int,
    nodeAddressLocal: Int,
    childIndexLocal: Int,
    to body: inout WASMEncoder
) {
    let root = tree.nodes[tree.rootIndex]
    if root.isLeaf {
        appendIntConstant(root.valueIndex, to: &body)
        return
    }

    appendInt64Constant(Int64.max, to: &body)
    appendLocalSet(bestDistanceLocal, to: &body)
    appendIntConstant(-1, to: &body)
    appendLocalSet(resultLocal, to: &body)
    appendIntConstant(0, to: &body)
    appendLocalSet(stackCountLocal, to: &body)

    // Seed the LIFO work stack in reverse so traversal preserves deterministic child order.
    for childIndex in (root.childIndexStart..<(root.childIndexStart + root.childCount)).reversed() {
        appendIntConstant(Int32(layout.stackOffset), to: &body)
        appendLocalGet(stackCountLocal, to: &body)
        appendIntConstant(2, to: &body)
        body.append(0x74) // i32.shl
        body.append(0x6a) // i32.add
        appendIntConstant(Int32(childIndex), to: &body)
        appendInt32Store(to: &body)
        appendLocalGet(stackCountLocal, to: &body)
        appendIntConstant(1, to: &body)
        body.append(0x6a) // i32.add
        appendLocalSet(stackCountLocal, to: &body)
    }

    body.append(0x02) // block $done
    body.append(0x40)
    body.append(0x03) // loop $search
    body.append(0x40)

    appendLocalGet(stackCountLocal, to: &body)
    body.append(0x45) // i32.eqz
    body.append(0x0d) // br_if $done
    body.appendUnsigned(1)

    appendLocalGet(stackCountLocal, to: &body)
    appendIntConstant(1, to: &body)
    body.append(0x6b) // i32.sub
    body.append(0x22) // local.tee
    body.appendUnsigned(stackCountLocal)
    appendIntConstant(2, to: &body)
    body.append(0x74) // i32.shl
    appendIntConstant(Int32(layout.stackOffset), to: &body)
    body.append(0x6a) // i32.add
    appendInt32Load(offset: 0, to: &body)
    appendLocalSet(nodeIndexLocal, to: &body)

    appendLocalGet(nodeIndexLocal, to: &body)
    appendIntConstant(7, to: &body)
    body.append(0x74) // i32.shl (128-byte node stride)
    appendIntConstant(Int32(layout.nodeBaseOffset), to: &body)
    body.append(0x6a) // i32.add
    appendLocalSet(nodeAddressLocal, to: &body)

    body.append(0x02) // block $skipNode
    body.append(0x40)
    appendBiomeSquaredDistanceFromMemory(
        point: point,
        nodeAddressLocal: nodeAddressLocal,
        accumulatorLocal: candidateDistanceLocal,
        deltaLocal: deltaLocal,
        minimumLocal: minimumLocal,
        maximumLocal: maximumLocal,
        bestDistanceLocal: bestDistanceLocal,
        to: &body
    )

    appendLocalGet(nodeAddressLocal, to: &body)
    appendInt32Load(offset: 0, to: &body)
    body.append(0x22) // local.tee
    body.appendUnsigned(nodeIndexLocal)
    appendIntConstant(0, to: &body)
    body.append(0x4e) // i32.ge_s
    body.append(0x04) // if leaf
    body.append(0x40)
    appendLocalGet(candidateDistanceLocal, to: &body)
    appendLocalSet(bestDistanceLocal, to: &body)
    appendLocalGet(nodeIndexLocal, to: &body)
    appendLocalSet(resultLocal, to: &body)
    appendLocalGet(candidateDistanceLocal, to: &body)
    body.append(0x50) // i64.eqz
    body.append(0x04) // if exact match
    body.append(0x40)
    body.append(0x0c) // br $done
    body.appendUnsigned(4)
    body.append(0x0b) // end exact match
    body.append(0x05) // else internal node

    appendLocalGet(nodeAddressLocal, to: &body)
    appendInt32Load(offset: 4, to: &body)
    appendLocalSet(nodeIndexLocal, to: &body) // child start
    appendLocalGet(nodeAddressLocal, to: &body)
    appendInt32Load(offset: 8, to: &body)
    appendLocalGet(nodeIndexLocal, to: &body)
    body.append(0x6a) // i32.add
    appendLocalSet(childIndexLocal, to: &body) // child end

    body.append(0x02) // block $childrenDone
    body.append(0x40)
    body.append(0x03) // loop $pushChildren
    body.append(0x40)
    appendLocalGet(childIndexLocal, to: &body)
    appendLocalGet(nodeIndexLocal, to: &body)
    body.append(0x46) // i32.eq
    body.append(0x0d) // br_if $childrenDone
    body.appendUnsigned(1)
    appendLocalGet(childIndexLocal, to: &body)
    appendIntConstant(1, to: &body)
    body.append(0x6b) // i32.sub
    appendLocalSet(childIndexLocal, to: &body)
    appendIntConstant(Int32(layout.stackOffset), to: &body)
    appendLocalGet(stackCountLocal, to: &body)
    appendIntConstant(2, to: &body)
    body.append(0x74) // i32.shl
    body.append(0x6a) // i32.add
    appendLocalGet(childIndexLocal, to: &body)
    appendInt32Store(to: &body)
    appendLocalGet(stackCountLocal, to: &body)
    appendIntConstant(1, to: &body)
    body.append(0x6a) // i32.add
    appendLocalSet(stackCountLocal, to: &body)
    body.append(0x0c) // br $pushChildren
    body.appendUnsigned(0)
    body.append(0x0b) // end pushChildren
    body.append(0x0b) // end childrenDone
    body.append(0x0b) // end leaf/internal if
    body.append(0x0b) // end skipNode
    body.append(0x0c) // br $search
    body.appendUnsigned(0)
    body.append(0x0b) // end search
    body.append(0x0b) // end done
    appendLocalGet(resultLocal, to: &body)
}

private func appendCall(_ functionIndex: Int, to body: inout WASMEncoder) {
    body.append(0x10)
    body.appendUnsigned(functionIndex)
}

private func makeWASMMapFunctionBody() -> [UInt8] {
    var body = WASMEncoder()
    body.appendUnsigned(0)
    appendLocalGet(0, to: &body)
    appendIntConstant(24, to: &body)
    body.append(0x6a) // i32.add
    appendLocalGet(1, to: &body)
    appendIntConstant(255, to: &body)
    body.append(0x71) // i32.and
    body.append(0x6a) // i32.add
    body.append(0x2d) // i32.load8_u
    body.appendUnsigned(0)
    body.appendUnsigned(0)
    body.append(0x0b)
    return body.bytes
}

private func makeWASMGradientFunctionBody() -> [UInt8] {
    // (hash: i32, x: f64, y: f64, z: f64) -> f64
    var body = WASMEncoder()
    body.appendUnsigned(2)
    body.appendUnsigned(1)
    body.append(WASMValueType.i32.rawValue)
    body.appendUnsigned(2)
    body.append(WASMValueType.f64.rawValue)

    appendLocalGet(0, to: &body)
    appendIntConstant(15, to: &body)
    body.append(0x71) // i32.and
    appendLocalSet(4, to: &body)

    appendLocalGet(1, to: &body)
    appendLocalGet(2, to: &body)
    appendLocalGet(4, to: &body)
    appendIntConstant(8, to: &body)
    body.append(0x49) // i32.lt_u
    body.append(0x1b) // select
    appendLocalSet(5, to: &body)

    appendLocalGet(2, to: &body)
    appendLocalGet(1, to: &body)
    appendLocalGet(3, to: &body)
    appendLocalGet(4, to: &body)
    appendIntConstant(12, to: &body)
    body.append(0x46) // i32.eq
    appendLocalGet(4, to: &body)
    appendIntConstant(14, to: &body)
    body.append(0x46) // i32.eq
    body.append(0x72) // i32.or
    body.append(0x1b) // select x/z
    appendLocalGet(4, to: &body)
    appendIntConstant(4, to: &body)
    body.append(0x49) // i32.lt_u
    body.append(0x1b) // select y/(x or z)
    appendLocalSet(6, to: &body)

    appendLocalGet(5, to: &body)
    appendLocalGet(5, to: &body)
    body.append(0x9a) // f64.neg
    appendLocalGet(4, to: &body)
    appendIntConstant(1, to: &body)
    body.append(0x71) // i32.and
    body.append(0x45) // i32.eqz
    body.append(0x1b) // select
    appendLocalGet(6, to: &body)
    appendLocalGet(6, to: &body)
    body.append(0x9a) // f64.neg
    appendLocalGet(4, to: &body)
    appendIntConstant(2, to: &body)
    body.append(0x71) // i32.and
    body.append(0x45) // i32.eqz
    body.append(0x1b) // select
    body.append(0xa0) // f64.add
    body.append(0x0b)
    return body.bytes
}

private func makeWASMFadeFunctionBody() -> [UInt8] {
    var body = WASMEncoder()
    body.appendUnsigned(0)
    appendLocalGet(0, to: &body)
    appendLocalGet(0, to: &body)
    body.append(0xa2) // f64.mul
    appendLocalGet(0, to: &body)
    body.append(0xa2) // f64.mul
    appendLocalGet(0, to: &body)
    appendLocalGet(0, to: &body)
    appendDoubleConstant(6.0, to: &body)
    body.append(0xa2) // f64.mul
    appendDoubleConstant(15.0, to: &body)
    body.append(0xa1) // f64.sub
    body.append(0xa2) // f64.mul
    appendDoubleConstant(10.0, to: &body)
    body.append(0xa0) // f64.add
    body.append(0xa2) // f64.mul
    body.append(0x0b)
    return body.bytes
}

private func makeWASMLerpFunctionBody() -> [UInt8] {
    var body = WASMEncoder()
    body.appendUnsigned(0)
    appendLocalGet(1, to: &body)
    appendLocalGet(0, to: &body)
    appendLocalGet(2, to: &body)
    appendLocalGet(1, to: &body)
    body.append(0xa1) // f64.sub
    body.append(0xa2) // f64.mul
    body.append(0xa0) // f64.add
    body.append(0x0b)
    return body.bytes
}

private func makeWASMPerlinFunctionBody(
    mapFunctionIndex: Int,
    gradientFunctionIndex: Int,
    fadeFunctionIndex: Int,
    lerpFunctionIndex: Int
) -> [UInt8] {
    // Parameters: data base, x, y, z. The data starts with three f64 origins followed by 256 bytes.
    var body = WASMEncoder()
    body.appendUnsigned(5)
    body.appendUnsigned(3)
    body.append(WASMValueType.f64.rawValue) // sample coordinates: 4...6
    body.appendUnsigned(3)
    body.append(WASMValueType.i32.rawValue) // integer sections: 7...9
    body.appendUnsigned(3)
    body.append(WASMValueType.f64.rawValue) // local coordinates: 10...12
    body.appendUnsigned(6)
    body.append(WASMValueType.i32.rawValue) // permutation intermediates: 13...18
    body.appendUnsigned(11)
    body.append(WASMValueType.f64.rawValue) // gradients/fades: 19...29

    for (input, originOffset, destination) in [(1, 0, 4), (2, 8, 5), (3, 16, 6)] {
        appendLocalGet(input, to: &body)
        appendLocalGet(0, to: &body)
        appendDoubleLoad(offset: originOffset, to: &body)
        body.append(0xa0) // f64.add
        appendLocalSet(destination, to: &body)
    }
    for (sample, section, local) in [(4, 7, 10), (5, 8, 11), (6, 9, 12)] {
        appendLocalGet(sample, to: &body)
        body.append(0x9c) // f64.floor
        body.append(0xaa) // i32.trunc_f64_s
        appendLocalSet(section, to: &body)
        appendLocalGet(sample, to: &body)
        appendLocalGet(sample, to: &body)
        body.append(0x9c) // f64.floor
        body.append(0xa1) // f64.sub
        appendLocalSet(local, to: &body)
    }

    func appendMap(_ input: () -> Void, destination: Int) {
        appendLocalGet(0, to: &body)
        input()
        appendCall(mapFunctionIndex, to: &body)
        appendLocalSet(destination, to: &body)
    }
    appendMap({ appendLocalGet(7, to: &body) }, destination: 13)
    appendMap({ appendLocalGet(7, to: &body); appendIntConstant(1, to: &body); body.append(0x6a) }, destination: 14)
    appendMap({ appendLocalGet(13, to: &body); appendLocalGet(8, to: &body); body.append(0x6a) }, destination: 15)
    appendMap({ appendLocalGet(13, to: &body); appendLocalGet(8, to: &body); body.append(0x6a); appendIntConstant(1, to: &body); body.append(0x6a) }, destination: 16)
    appendMap({ appendLocalGet(14, to: &body); appendLocalGet(8, to: &body); body.append(0x6a) }, destination: 17)
    appendMap({ appendLocalGet(14, to: &body); appendLocalGet(8, to: &body); body.append(0x6a); appendIntConstant(1, to: &body); body.append(0x6a) }, destination: 18)

    let corners: [(xy: Int, zOffset: Int, xOffset: Double, yOffset: Double, zDelta: Double)] = [
        (15, 0, 0, 0, 0), (17, 0, -1, 0, 0), (16, 0, 0, -1, 0), (18, 0, -1, -1, 0),
        (15, 1, 0, 0, -1), (17, 1, -1, 0, -1), (16, 1, 0, -1, -1), (18, 1, -1, -1, -1)
    ]
    for (cornerIndex, corner) in corners.enumerated() {
        appendLocalGet(0, to: &body)
        appendLocalGet(corner.xy, to: &body)
        appendLocalGet(9, to: &body)
        body.append(0x6a) // i32.add
        if corner.zOffset != 0 { appendIntConstant(Int32(corner.zOffset), to: &body); body.append(0x6a) }
        appendCall(mapFunctionIndex, to: &body)
        for (coordinate, offset) in [(10, corner.xOffset), (11, corner.yOffset), (12, corner.zDelta)] {
            appendLocalGet(coordinate, to: &body)
            if offset != 0 { appendDoubleConstant(offset, to: &body); body.append(0xa0) }
        }
        appendCall(gradientFunctionIndex, to: &body)
        appendLocalSet(19 + cornerIndex, to: &body)
    }
    for (coordinate, destination) in [(10, 27), (11, 28), (12, 29)] {
        appendLocalGet(coordinate, to: &body)
        appendCall(fadeFunctionIndex, to: &body)
        appendLocalSet(destination, to: &body)
    }

    func appendLerp(_ delta: Int, _ start: Int, _ end: Int, destination: Int) {
        appendLocalGet(delta, to: &body)
        appendLocalGet(start, to: &body)
        appendLocalGet(end, to: &body)
        appendCall(lerpFunctionIndex, to: &body)
        appendLocalSet(destination, to: &body)
    }
    appendLerp(27, 19, 20, destination: 19)
    appendLerp(27, 21, 22, destination: 20)
    appendLerp(28, 19, 20, destination: 19)
    appendLerp(27, 23, 24, destination: 20)
    appendLerp(27, 25, 26, destination: 21)
    appendLerp(28, 20, 21, destination: 20)
    appendLocalGet(29, to: &body)
    appendLocalGet(19, to: &body)
    appendLocalGet(20, to: &body)
    appendCall(lerpFunctionIndex, to: &body)
    body.append(0x0b)
    return body.bytes
}

private func appendEmbeddedNoiseSample(
    layout: WASMEmbeddedNoiseLayout,
    x: Int,
    y: Int,
    z: Int,
    perlinFunctionIndex: Int,
    to body: inout WASMEncoder
) {
    func appendOctaves(_ octaves: [WASMEmbeddedOctaveLayout], coordinateMultiplier: Double) {
        appendDoubleConstant(0, to: &body)
        for octave in octaves {
            appendDoubleConstant(octave.amplitude, to: &body)
            appendIntConstant(Int32(octave.permutationOffset), to: &body)
            for coordinate in [x, y, z] {
                appendLocalGet(coordinate, to: &body)
                appendDoubleConstant(octave.lacunarity * coordinateMultiplier, to: &body)
                body.append(0xa2) // f64.mul
            }
            appendCall(perlinFunctionIndex, to: &body)
            body.append(0xa2) // f64.mul amplitude
            body.append(0xa0) // f64.add accumulator
        }
    }
    appendOctaves(layout.firstOctaves, coordinateMultiplier: 1)
    appendOctaves(layout.secondOctaves, coordinateMultiplier: 337.0 / 331.0)
    body.append(0xa0) // f64.add samplers
    appendDoubleConstant(layout.amplitude, to: &body)
    body.append(0xa2) // f64.mul
}

private func makeWASMBulkFunctionBody(
    bufferContext: CompiledDensityFunctionBufferContext,
    outputOffset: Int,
    scalarFunctionIndex: Int,
    outputValueCount: Int
) -> [UInt8] {
    // Parameters are base x/y/z. Locals are z/x/y offsets, the output address, and
    // one temporary per scalar result so multi-value returns can be stored in order.
    var body = WASMEncoder()
    body.appendUnsigned(2)
    body.appendUnsigned(4)
    body.append(WASMValueType.i32.rawValue)
    body.appendUnsigned(outputValueCount)
    body.append(WASMValueType.f64.rawValue)

    appendIntConstant(0, to: &body)
    appendLocalSet(3, to: &body)
    appendIntConstant(Int32(outputOffset), to: &body)
    appendLocalSet(6, to: &body)

    body.append(0x03) // loop z
    body.append(0x40)
    appendIntConstant(0, to: &body)
    appendLocalSet(4, to: &body)

    body.append(0x03) // loop x
    body.append(0x40)
    appendIntConstant(0, to: &body)
    appendLocalSet(5, to: &body)

    body.append(0x03) // loop y
    body.append(0x40)
    for (base, offset, step) in [
        (0, 4, bufferContext.xStep),
        (1, 5, bufferContext.yStep),
        (2, 3, bufferContext.zStep)
    ] {
        appendLocalGet(base, to: &body)
        appendLocalGet(offset, to: &body)
        appendIntConstant(step, to: &body)
        body.append(0x6c) // i32.mul
        body.append(0x6a) // i32.add
    }
    appendCall(scalarFunctionIndex, to: &body)
    for outputIndex in (0..<outputValueCount).reversed() {
        appendLocalSet(7 + outputIndex, to: &body)
    }
    for outputIndex in 0..<outputValueCount {
        appendLocalGet(6, to: &body)
        appendLocalGet(7 + outputIndex, to: &body)
        appendDoubleStore(to: &body)
        appendLocalGet(6, to: &body)
        appendIntConstant(8, to: &body)
        body.append(0x6a) // i32.add
        appendLocalSet(6, to: &body)
    }
    appendLocalGet(5, to: &body)
    appendIntConstant(1, to: &body)
    body.append(0x6a) // i32.add
    body.append(0x22) // local.tee
    body.appendUnsigned(5)
    appendIntConstant(bufferContext.yCount, to: &body)
    body.append(0x49) // i32.lt_u
    body.append(0x0d) // br_if y
    body.appendUnsigned(0)
    body.append(0x0b) // end y

    appendLocalGet(4, to: &body)
    appendIntConstant(1, to: &body)
    body.append(0x6a) // i32.add
    body.append(0x22) // local.tee
    body.appendUnsigned(4)
    appendIntConstant(bufferContext.xCount, to: &body)
    body.append(0x49) // i32.lt_u
    body.append(0x0d) // br_if x
    body.appendUnsigned(0)
    body.append(0x0b) // end x

    appendLocalGet(3, to: &body)
    appendIntConstant(1, to: &body)
    body.append(0x6a) // i32.add
    body.append(0x22) // local.tee
    body.appendUnsigned(3)
    appendIntConstant(bufferContext.zCount, to: &body)
    body.append(0x49) // i32.lt_u
    body.append(0x0d) // br_if z
    body.appendUnsigned(0)
    body.append(0x0b) // end z

    appendIntConstant(Int32(outputOffset), to: &body)
    body.append(0x0b)
    return body.bytes
}

func buildDensityFunctionWASMModule(
    _ program: DensityFunctionIRProgram,
    exportName: String = "sample",
    bulkContext: CompiledDensityFunctionBufferContext? = nil,
    bulkExportName: String = "sample_bulk"
) throws -> [UInt8] {
    if bulkContext != nil {
        let outputsAreDoubles = program.outputs.allSatisfy { output in
            let instructionIndex = output - program.inputTypes.count
            return instructionIndex >= 0
                && instructionIndex < program.instructions.count
                && program.instructions[instructionIndex].resultType == .f64
        }
        guard program.inputTypes == [.i32, .i32, .i32], outputsAreDoubles else {
            throw DensityFunctionCompilationError.badDensityFunction(
                "WASM bulk compilation requires f64 outputs with x/y/z inputs."
            )
        }
    }
    var module = WASMEncoder()
    module.append(contentsOf: [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])

    var staticData = WASMEncoder()
    var biomeTreeLayouts: [WASMBiomeTreeLayout] = []
    var maximumBiomeTreeNodeCount = 0
    for tree in program.biomeSearchTrees {
        let nodeBaseOffset = staticData.bytes.count
        for node in tree.nodes {
            staticData.appendFixed(node.valueIndex)
            staticData.appendFixed(Int32(node.childIndexStart))
            staticData.appendFixed(Int32(node.childCount))
            staticData.appendFixed(Int32(node.minimums[6] <= 0 && node.maximums[6] >= 0 ? 1 : 0))
            for minimum in node.minimums { staticData.appendFixed(minimum) }
            for maximum in node.maximums { staticData.appendFixed(maximum) }
        }
        biomeTreeLayouts.append(WASMBiomeTreeLayout(nodeBaseOffset: nodeBaseOffset, stackOffset: 0))
        maximumBiomeTreeNodeCount = max(maximumBiomeTreeNodeCount, tree.nodes.count)
    }

    var embeddedNoiseLayouts: [Int: WASMEmbeddedNoiseLayout] = [:]
    var embeddedNoiseLayoutsBySampler: [ObjectIdentifier: WASMEmbeddedNoiseLayout] = [:]
    for (index, noise) in program.noises.enumerated() {
        guard let bakedNoise = noise as? BakedNoise else { continue }
        let identity = ObjectIdentifier(bakedNoise.sampler)
        if let existing = embeddedNoiseLayoutsBySampler[identity] {
            embeddedNoiseLayouts[index] = existing
        } else {
            let layout = appendEmbeddedNoise(bakedNoise.sampler.wasmSnapshot, to: &staticData)
            embeddedNoiseLayoutsBySampler[identity] = layout
            embeddedNoiseLayouts[index] = layout
        }
    }

    let biomeStackOffset = staticData.bytes.count
    biomeTreeLayouts = biomeTreeLayouts.map {
        WASMBiomeTreeLayout(nodeBaseOffset: $0.nodeBaseOffset, stackOffset: biomeStackOffset)
    }
    let biomeScratchEnd = biomeStackOffset + maximumBiomeTreeNodeCount * MemoryLayout<Int32>.size
    let bulkOutputOffset = bulkContext.map { _ in alignWASMOffset(biomeScratchEnd, to: 8) }
    let bulkOutputEnd: Int
    if let bulkContext, let bulkOutputOffset {
        let (valueCount, valueCountOverflow) = bulkContext.sampleCount.multipliedReportingOverflow(
            by: program.outputs.count
        )
        let (byteCount, byteCountOverflow) = valueCount.multipliedReportingOverflow(
            by: MemoryLayout<Double>.size
        )
        let (endOffset, endOffsetOverflow) = bulkOutputOffset.addingReportingOverflow(byteCount)
        guard !valueCountOverflow, !byteCountOverflow, !endOffsetOverflow else {
            throw DensityFunctionCompilationError.badDensityFunction("WASM bulk output size overflowed Int.")
        }
        bulkOutputEnd = endOffset
    } else {
        bulkOutputEnd = biomeScratchEnd
    }
    guard bulkOutputEnd <= Int(Int32.max) else {
        throw DensityFunctionCompilationError.badDensityFunction("WASM bulk output exceeds the 32-bit address space.")
    }

    let importsDensitySampler = program.instructions.contains { instruction in
        if case .sampleDensity = instruction { return true }
        return false
    }
    let importsNoiseSampler = program.instructions.contains { instruction in
        if case .sampleNoise(let index, _, _, _) = instruction {
            return embeddedNoiseLayouts[index] == nil
        }
        return false
    }
    let embedsNoiseSampler = !embeddedNoiseLayouts.isEmpty
    let densitySamplerFunctionIndex = importsDensitySampler ? 0 : nil
    let noiseSamplerFunctionIndex = importsNoiseSampler ? (importsDensitySampler ? 1 : 0) : nil
    let importCount = (importsDensitySampler ? 1 : 0) + (importsNoiseSampler ? 1 : 0)

    let baseTypeCount = embedsNoiseSampler ? 6 : 3
    var types = WASMEncoder()
    types.appendUnsigned(baseTypeCount + (bulkContext == nil ? 0 : 1))
    appendFunctionType(parameters: [.i32, .i32, .i32, .i32], results: [.f64], to: &types)
    appendFunctionType(parameters: [.i32, .f64, .f64, .f64], results: [.f64], to: &types)
    let outputTypes: [DensityFunctionIRValueType] = program.outputs.map { output in
        if output < program.inputTypes.count {
            program.inputTypes[output]
        } else {
            program.instructions[output - program.inputTypes.count].resultType
        }
    }
    if embedsNoiseSampler {
        appendFunctionType(parameters: [.i32, .i32], results: [.i32], to: &types)
        appendFunctionType(parameters: [.f64], results: [.f64], to: &types)
        appendFunctionType(parameters: [.f64, .f64, .f64], results: [.f64], to: &types)
    }
    let mainFunctionTypeIndex = embedsNoiseSampler ? 5 : 2
    appendFunctionType(
        parameters: program.inputTypes.map(wasmValueType),
        results: outputTypes.map(wasmValueType),
        to: &types
    )
    let bulkFunctionTypeIndex = bulkContext.map { _ in baseTypeCount }
    if bulkContext != nil {
        appendFunctionType(parameters: [.i32, .i32, .i32], results: [.i32], to: &types)
    }
    module.appendSection(id: 1, contents: types.bytes)

    var imports = WASMEncoder()
    imports.appendUnsigned(importCount)
    if importsDensitySampler {
        imports.appendName("dpreader")
        imports.appendName("sample_density")
        imports.append(0x00)
        imports.appendUnsigned(0)
    }
    if importsNoiseSampler {
        imports.appendName("dpreader")
        imports.appendName("sample_noise")
        imports.append(0x00)
        imports.appendUnsigned(1)
    }
    module.appendSection(id: 2, contents: imports.bytes)

    let helperFunctionCount = embedsNoiseSampler ? 5 : 0
    let mapFunctionIndex = importCount
    let gradientFunctionIndex = importCount + 1
    let fadeFunctionIndex = importCount + 2
    let lerpFunctionIndex = importCount + 3
    let perlinFunctionIndex = importCount + 4
    let mainFunctionIndex = importCount + helperFunctionCount
    let bulkFunctionIndex = bulkContext.map { _ in mainFunctionIndex + 1 }

    var functions = WASMEncoder()
    functions.appendUnsigned(helperFunctionCount + 1 + (bulkContext == nil ? 0 : 1))
    if embedsNoiseSampler {
        functions.appendUnsigned(2) // map
        functions.appendUnsigned(1) // gradient
        functions.appendUnsigned(3) // fade
        functions.appendUnsigned(4) // lerp
        functions.appendUnsigned(1) // perlin
    }
    functions.appendUnsigned(mainFunctionTypeIndex)
    if let bulkFunctionTypeIndex {
        functions.appendUnsigned(bulkFunctionTypeIndex)
    }
    module.appendSection(id: 3, contents: functions.bytes)

    if embedsNoiseSampler || !program.biomeSearchTrees.isEmpty || bulkContext != nil {
        var memories = WASMEncoder()
        memories.appendUnsigned(1)
        memories.append(0x00) // minimum only
        let requiredByteCount = max(biomeScratchEnd, bulkOutputEnd)
        memories.appendUnsigned(max(1, (requiredByteCount + 65_535) / 65_536))
        module.appendSection(id: 5, contents: memories.bytes)
    }

    var exports = WASMEncoder()
    exports.appendUnsigned(bulkContext == nil ? 1 : 3)
    exports.appendName(exportName)
    exports.append(0x00)
    exports.appendUnsigned(mainFunctionIndex)
    if let bulkFunctionIndex {
        exports.appendName(bulkExportName)
        exports.append(0x00)
        exports.appendUnsigned(bulkFunctionIndex)
        exports.appendName("memory")
        exports.append(0x02)
        exports.appendUnsigned(0)
    }
    module.appendSection(id: 7, contents: exports.bytes)

    var body = WASMEncoder()
    var localRuns: [(count: Int, type: WASMValueType)] = []
    for instruction in program.instructions {
        let type = wasmValueType(instruction.resultType)
        if let last = localRuns.last, last.type == type {
            localRuns[localRuns.count - 1].count += 1
        } else {
            localRuns.append((1, type))
        }
    }
    let hasBiomeSearch = program.instructions.contains { instruction in
        if case .searchBiome = instruction { return true }
        return false
    }
    let scratchLocalStart = program.inputTypes.count + program.instructions.count
    if hasBiomeSearch {
        if let last = localRuns.last, last.type == .i64 {
            localRuns[localRuns.count - 1].count += 5
        } else {
            localRuns.append((5, .i64))
        }
        localRuns.append((4, .i32))
    }
    body.appendUnsigned(localRuns.count)
    for run in localRuns {
        body.appendUnsigned(run.count)
        body.append(run.type.rawValue)
    }

    for (instructionIndex, instruction) in program.instructions.enumerated() {
        switch instruction {
        case .constant(let value):
            appendDoubleConstant(value, to: &body)
        case .constantInt32(let value):
            appendIntConstant(value, to: &body)
        case .constantInt64(let value):
            appendInt64Constant(value, to: &body)
        case .convertSignedIntToDouble(let input):
            appendLocalGet(input, to: &body)
            body.append(0xb7)
        case .convertDoubleToSignedInt64(let input):
            appendLocalGet(input, to: &body)
            body.append(0xb0) // i64.trunc_f64_s
        case .add(let lhs, let rhs):
            appendLocalGet(lhs, to: &body)
            appendLocalGet(rhs, to: &body)
            body.append(0xa0)
        case .subtract(let lhs, let rhs):
            appendLocalGet(lhs, to: &body)
            appendLocalGet(rhs, to: &body)
            body.append(0xa1)
        case .multiply(let lhs, let rhs):
            appendLocalGet(lhs, to: &body)
            appendLocalGet(rhs, to: &body)
            body.append(0xa2)
        case .divide(let lhs, let rhs):
            appendLocalGet(lhs, to: &body)
            appendLocalGet(rhs, to: &body)
            body.append(0xa3)
        case .negate(let input):
            appendLocalGet(input, to: &body)
            body.append(0x9a)
        case .compare(let comparison, let lhs, let rhs):
            appendLocalGet(lhs, to: &body)
            appendLocalGet(rhs, to: &body)
            let opcode: UInt8 = switch comparison {
            case .equal: 0x61
            case .lessThan: 0x63
            case .greaterThan: 0x64
            case .lessThanOrEqual: 0x65
            case .greaterThanOrEqual: 0x66
            }
            body.append(opcode)
        case .and(let lhs, let rhs):
            appendLocalGet(lhs, to: &body)
            appendLocalGet(rhs, to: &body)
            body.append(0x71)
        case .select(let condition, let whenTrue, let whenFalse):
            appendLocalGet(whenTrue, to: &body)
            appendLocalGet(whenFalse, to: &body)
            appendLocalGet(condition, to: &body)
            body.append(0x1b)
        case .sampleDensity(let index, let x, let y, let z):
            appendIntConstant(Int32(index), to: &body)
            appendLocalGet(x, to: &body)
            appendLocalGet(y, to: &body)
            appendLocalGet(z, to: &body)
            body.append(0x10)
            body.appendUnsigned(densitySamplerFunctionIndex!)
        case .sampleNoise(let index, let x, let y, let z):
            if let embedded = embeddedNoiseLayouts[index] {
                appendEmbeddedNoiseSample(
                    layout: embedded,
                    x: x,
                    y: y,
                    z: z,
                    perlinFunctionIndex: perlinFunctionIndex,
                    to: &body
                )
            } else {
                appendIntConstant(Int32(index), to: &body)
                appendLocalGet(x, to: &body)
                appendLocalGet(y, to: &body)
                appendLocalGet(z, to: &body)
                appendCall(noiseSamplerFunctionIndex!, to: &body)
            }
        case .searchBiome(let index, let point):
            let resultLocal = program.inputTypes.count + instructionIndex
            let bestDistanceLocal = scratchLocalStart
            let candidateDistanceLocal = scratchLocalStart + 1
            let deltaLocal = scratchLocalStart + 2
            let minimumLocal = scratchLocalStart + 3
            let maximumLocal = scratchLocalStart + 4
            let stackCountLocal = scratchLocalStart + 5
            let nodeIndexLocal = scratchLocalStart + 6
            let nodeAddressLocal = scratchLocalStart + 7
            let childIndexLocal = scratchLocalStart + 8
            let tree = program.biomeSearchTrees[index]
            appendBiomeSearchFromMemory(
                tree: tree,
                layout: biomeTreeLayouts[index],
                point: point,
                resultLocal: resultLocal,
                bestDistanceLocal: bestDistanceLocal,
                candidateDistanceLocal: candidateDistanceLocal,
                deltaLocal: deltaLocal,
                minimumLocal: minimumLocal,
                maximumLocal: maximumLocal,
                stackCountLocal: stackCountLocal,
                nodeIndexLocal: nodeIndexLocal,
                nodeAddressLocal: nodeAddressLocal,
                childIndexLocal: childIndexLocal,
                to: &body
            )
        }
        appendLocalSet(program.inputTypes.count + instructionIndex, to: &body)
    }
    for output in program.outputs {
        appendLocalGet(output, to: &body)
    }
    body.append(0x0b)

    var code = WASMEncoder()
    code.appendUnsigned(helperFunctionCount + 1 + (bulkContext == nil ? 0 : 1))
    if embedsNoiseSampler {
        for helperBody in [
            makeWASMMapFunctionBody(),
            makeWASMGradientFunctionBody(),
            makeWASMFadeFunctionBody(),
            makeWASMLerpFunctionBody(),
            makeWASMPerlinFunctionBody(
                mapFunctionIndex: mapFunctionIndex,
                gradientFunctionIndex: gradientFunctionIndex,
                fadeFunctionIndex: fadeFunctionIndex,
                lerpFunctionIndex: lerpFunctionIndex
            )
        ] {
            code.appendUnsigned(helperBody.count)
            code.append(contentsOf: helperBody)
        }
    }
    code.appendUnsigned(body.bytes.count)
    code.append(contentsOf: body.bytes)
    if let bulkContext, let bulkOutputOffset {
        let bulkBody = makeWASMBulkFunctionBody(
            bufferContext: bulkContext,
            outputOffset: bulkOutputOffset,
            scalarFunctionIndex: mainFunctionIndex,
            outputValueCount: program.outputs.count
        )
        code.appendUnsigned(bulkBody.count)
        code.append(contentsOf: bulkBody)
    }
    module.appendSection(id: 10, contents: code.bytes)
    if !staticData.bytes.isEmpty {
        var data = WASMEncoder()
        data.appendUnsigned(1)
        data.append(0x00) // active segment for memory 0
        appendIntConstant(0, to: &data)
        data.append(0x0b) // end offset expression
        data.appendUnsigned(staticData.bytes.count)
        data.append(contentsOf: staticData.bytes)
        module.appendSection(id: 11, contents: data.bytes)
    }
    return module.bytes
}
