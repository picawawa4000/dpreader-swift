import Foundation

private enum WASMValueType: UInt8 {
    case i32 = 0x7f
    case i64 = 0x7e
    case f64 = 0x7c
    case v128 = 0x7b
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

private func appendFloatConstant(_ value: Float, to encoder: inout WASMEncoder) {
    encoder.append(0x43)
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
    let originX: Double
    let originY: Double
    let originZ: Double
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
    let offset = data.bytes.count
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
                originX: $0.noise.originX,
                originY: $0.noise.originY,
                originZ: $0.noise.originZ,
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

private func appendPerlinGradientTable(to data: inout WASMEncoder) -> Int {
    while data.bytes.count % MemoryLayout<Double>.alignment != 0 { data.append(0) }
    let offset = data.bytes.count
    for hash in 0..<16 {
        var coefficients = [Double](repeating: 0, count: 3)
        let uAxis = hash < 8 ? 0 : 1
        let vAxis = hash < 4 ? 1 : ((hash == 12 || hash == 14) ? 0 : 2)
        coefficients[uAxis] += hash & 1 == 0 ? 1 : -1
        coefficients[vAxis] += hash & 2 == 0 ? 1 : -1
        for coefficient in coefficients { data.appendFixed(coefficient) }
    }
    return offset
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

private func appendDoublePairStore(to body: inout WASMEncoder) {
    body.append(0xfd) // SIMD prefix
    body.appendUnsigned(0x0b) // v128.store
    body.appendUnsigned(4) // Bulk output is 16-byte aligned.
    body.appendUnsigned(0)
}

private func appendDoubleSplat(to body: inout WASMEncoder) {
    body.append(0xfd)
    body.appendUnsigned(0x14) // f64x2.splat
}

private func appendDoubleReplaceLane(_ lane: UInt8, to body: inout WASMEncoder) {
    body.append(0xfd)
    body.appendUnsigned(0x22) // f64x2.replace_lane
    body.append(lane)
}

private func appendSIMDOpcode(_ opcode: Int, to body: inout WASMEncoder) {
    body.append(0xfd)
    body.appendUnsigned(opcode)
}

private func appendDoubleExtractLane(_ lane: UInt8, to body: inout WASMEncoder) {
    appendSIMDOpcode(0x21, to: &body) // f64x2.extract_lane
    body.append(lane)
}

private func appendInt32ExtractLane(_ lane: UInt8, to body: inout WASMEncoder) {
    appendSIMDOpcode(0x1b, to: &body) // i32x4.extract_lane_s
    body.append(lane)
}

private func supportsWASMPairedSIMD(_ program: DensityFunctionIRProgram) -> Bool {
    guard program.inputTypes == [.i32, .i32, .i32], program.outputs.count == 1 else { return false }
    let output = program.outputs[0]
    let outputType = output < program.inputTypes.count
        ? program.inputTypes[output]
        : program.instructions[output - program.inputTypes.count].resultType
    let isFusedClimateBiome = outputType == .i32
        && output >= program.inputTypes.count
        && {
            if case .searchBiome(_, _, nil, nil, false) = program.instructions[output - program.inputTypes.count] {
                return true
            }
            return false
        }()
    guard outputType == .f64 || isFusedClimateBiome else { return false }
    for instruction in program.instructions {
        switch instruction {
        case .constant, .convertSignedIntToDouble, .add, .subtract, .multiply, .divide,
             .negate, .compare, .and, .select, .sampleNoise:
            continue
        case .sampleDensity(_, let x, let y, let z):
            guard x < 3, y < 3, z < 3 else { return false }
        case .constantInt64, .convertDoubleToSignedInt64:
            guard isFusedClimateBiome else { return false }
        case .searchBiome(_, let point, let initialBestDistance, let initialBestNode, let returnNodeIndex):
            guard isFusedClimateBiome,
                  initialBestDistance == nil,
                  initialBestNode == nil,
                  !returnNodeIndex,
                  point.allSatisfy({ value in
                      value >= program.inputTypes.count
                          && program.instructions[value - program.inputTypes.count].resultType == .i64
                  })
            else { return false }
        case .constantInt32, .divideSignedInt32, .multiplyInt32, .spline:
            return false
        }
    }
    return program.outputs[0] >= program.inputTypes.count
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
    initialBestDistance: Int?,
    initialBestNode: Int?,
    alternativeNodeOffset: Int?,
    returnNodeIndex: Bool,
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
        appendIntConstant(returnNodeIndex ? Int32(tree.rootIndex) : root.valueIndex, to: &body)
        return
    }

    if let alternativeNodeOffset, initialBestDistance == nil, initialBestNode == nil {
        appendIntConstant(Int32(alternativeNodeOffset), to: &body)
        appendInt32Load(offset: 0, to: &body)
        body.append(0x22) // local.tee
        body.appendUnsigned(nodeIndexLocal)
        appendIntConstant(0, to: &body)
        body.append(0x4e) // i32.ge_s
        body.append(0x04) // if cached leaf
        body.append(0x40)

        appendLocalGet(nodeIndexLocal, to: &body)
        appendIntConstant(7, to: &body)
        body.append(0x74) // i32.shl (128-byte node stride)
        appendIntConstant(Int32(layout.nodeBaseOffset), to: &body)
        body.append(0x6a) // i32.add
        appendLocalSet(nodeAddressLocal, to: &body)
        appendInt64Constant(0, to: &body)
        appendLocalSet(candidateDistanceLocal, to: &body)
        for dimension in [2, 3, 5, 4, 0, 1, 6] {
            appendBiomeSquaredDistanceDimensionFromMemory(
                dimension: dimension,
                point: point,
                nodeAddressLocal: nodeAddressLocal,
                accumulatorLocal: candidateDistanceLocal,
                deltaLocal: deltaLocal,
                minimumLocal: minimumLocal,
                maximumLocal: maximumLocal,
                to: &body
            )
        }
        appendLocalGet(candidateDistanceLocal, to: &body)
        appendLocalSet(bestDistanceLocal, to: &body)
        if returnNodeIndex {
            appendLocalGet(nodeIndexLocal, to: &body)
        } else {
            appendLocalGet(nodeAddressLocal, to: &body)
            appendInt32Load(offset: 0, to: &body)
        }
        appendLocalSet(resultLocal, to: &body)
        body.append(0x05) // else no cached leaf
        appendInt64Constant(Int64.max, to: &body)
        appendLocalSet(bestDistanceLocal, to: &body)
        appendIntConstant(-1, to: &body)
        appendLocalSet(resultLocal, to: &body)
        body.append(0x0b)
    } else if let initialBestDistance, let initialBestNode {
        appendLocalGet(initialBestDistance, to: &body)
        appendLocalSet(bestDistanceLocal, to: &body)
        appendLocalGet(initialBestNode, to: &body)
        appendLocalSet(resultLocal, to: &body)
    } else {
        appendInt64Constant(Int64.max, to: &body)
        appendLocalSet(bestDistanceLocal, to: &body)
        appendIntConstant(-1, to: &body)
        appendLocalSet(resultLocal, to: &body)
    }
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
    body.appendUnsigned(childIndexLocal)
    appendIntConstant(0, to: &body)
    body.append(0x4e) // i32.ge_s
    body.append(0x04) // if leaf
    body.append(0x40)
    appendLocalGet(candidateDistanceLocal, to: &body)
    appendLocalSet(bestDistanceLocal, to: &body)
    appendLocalGet(returnNodeIndex ? nodeIndexLocal : childIndexLocal, to: &body)
    appendLocalSet(resultLocal, to: &body)
    if let alternativeNodeOffset {
        appendIntConstant(Int32(alternativeNodeOffset), to: &body)
        appendLocalGet(nodeIndexLocal, to: &body)
        appendInt32Store(to: &body)
    }
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

private func makeWASMPerlinFunctionBody(gradientTableOffset: Int) -> [UInt8] {
    // Parameters: permutation-table base, x, y, z.
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

    for (input, destination) in [(1, 4), (2, 5), (3, 6)] {
        appendLocalGet(input, to: &body)
        appendLocalSet(destination, to: &body)
    }
    for (sample, section, local) in [(4, 7, 10), (5, 8, 11), (6, 9, 12)] {
        appendLocalGet(sample, to: &body)
        body.append(0x9c) // f64.floor
        body.append(0xaa) // i32.trunc_f64_s
        appendLocalSet(section, to: &body)
        appendLocalGet(sample, to: &body)
        appendLocalGet(section, to: &body)
        body.append(0xb7) // f64.convert_i32_s; section is the exact floored value
        body.append(0xa1) // f64.sub
        appendLocalSet(local, to: &body)
    }
    func appendMap(_ input: () -> Void) {
        appendLocalGet(0, to: &body)
        input()
        appendIntConstant(255, to: &body)
        body.append(0x71) // i32.and
        body.append(0x6a) // i32.add
        body.append(0x2d) // i32.load8_u
        body.appendUnsigned(0)
        body.appendUnsigned(0)
    }
    func appendMapped(_ input: () -> Void, destination: Int) {
        appendMap(input)
        appendLocalSet(destination, to: &body)
    }
    appendMapped({ appendLocalGet(7, to: &body) }, destination: 13)
    appendMapped({ appendLocalGet(7, to: &body); appendIntConstant(1, to: &body); body.append(0x6a) }, destination: 14)
    appendMapped({ appendLocalGet(13, to: &body); appendLocalGet(8, to: &body); body.append(0x6a) }, destination: 15)
    appendMapped({ appendLocalGet(13, to: &body); appendLocalGet(8, to: &body); body.append(0x6a); appendIntConstant(1, to: &body); body.append(0x6a) }, destination: 16)
    appendMapped({ appendLocalGet(14, to: &body); appendLocalGet(8, to: &body); body.append(0x6a) }, destination: 17)
    appendMapped({ appendLocalGet(14, to: &body); appendLocalGet(8, to: &body); body.append(0x6a); appendIntConstant(1, to: &body); body.append(0x6a) }, destination: 18)

    func appendGradient(xOffset: Double, yOffset: Double, zOffset: Double) {
        func appendCoordinate(_ local: Int, offset: Double) {
            appendLocalGet(local, to: &body)
            if offset != 0 {
                appendDoubleConstant(offset, to: &body)
                body.append(0xa0) // f64.add
            }
        }
        // Reuse permutation locals after all XY intermediates have been materialised.
        appendLocalSet(13, to: &body)
        appendLocalGet(13, to: &body)
        appendIntConstant(15, to: &body)
        body.append(0x71) // i32.and
        appendIntConstant(24, to: &body)
        body.append(0x6c) // i32.mul; three f64 coefficients per hash
        appendIntConstant(Int32(gradientTableOffset), to: &body)
        body.append(0x6a) // i32.add
        appendLocalSet(14, to: &body)

        appendLocalGet(14, to: &body)
        appendDoubleLoad(offset: 0, to: &body)
        appendCoordinate(10, offset: xOffset)
        body.append(0xa2) // f64.mul
        appendLocalGet(14, to: &body)
        appendDoubleLoad(offset: 8, to: &body)
        appendCoordinate(11, offset: yOffset)
        body.append(0xa2) // f64.mul
        body.append(0xa0) // f64.add
        appendLocalGet(14, to: &body)
        appendDoubleLoad(offset: 16, to: &body)
        appendCoordinate(12, offset: zOffset)
        body.append(0xa2) // f64.mul
        body.append(0xa0) // f64.add
    }

    let corners: [(xy: Int, zOffset: Int, xOffset: Double, yOffset: Double, zDelta: Double)] = [
        (15, 0, 0, 0, 0), (17, 0, -1, 0, 0), (16, 0, 0, -1, 0), (18, 0, -1, -1, 0),
        (15, 1, 0, 0, -1), (17, 1, -1, 0, -1), (16, 1, 0, -1, -1), (18, 1, -1, -1, -1)
    ]
    for (cornerIndex, corner) in corners.enumerated() {
        appendMap {
            appendLocalGet(corner.xy, to: &body)
            appendLocalGet(9, to: &body)
            body.append(0x6a) // i32.add
            if corner.zOffset != 0 { appendIntConstant(Int32(corner.zOffset), to: &body); body.append(0x6a) }
        }
        appendGradient(
            xOffset: corner.xOffset,
            yOffset: corner.yOffset,
            zOffset: corner.zDelta
        )
        appendLocalSet(19 + cornerIndex, to: &body)
    }
    for (coordinate, destination) in [(10, 27), (11, 28), (12, 29)] {
        appendLocalGet(coordinate, to: &body)
        appendLocalGet(coordinate, to: &body)
        body.append(0xa2) // f64.mul
        appendLocalGet(coordinate, to: &body)
        body.append(0xa2) // f64.mul
        appendLocalGet(coordinate, to: &body)
        appendLocalGet(coordinate, to: &body)
        appendDoubleConstant(6.0, to: &body)
        body.append(0xa2) // f64.mul
        appendDoubleConstant(15.0, to: &body)
        body.append(0xa1) // f64.sub
        body.append(0xa2) // f64.mul
        appendDoubleConstant(10.0, to: &body)
        body.append(0xa0) // f64.add
        body.append(0xa2) // f64.mul
        appendLocalSet(destination, to: &body)
    }

    func appendLerp(_ delta: Int, _ start: Int, _ end: Int, destination: Int) {
        appendLocalGet(start, to: &body)
        appendLocalGet(delta, to: &body)
        appendLocalGet(end, to: &body)
        appendLocalGet(start, to: &body)
        body.append(0xa1) // f64.sub
        body.append(0xa2) // f64.mul
        body.append(0xa0) // f64.add
        appendLocalSet(destination, to: &body)
    }
    appendLerp(27, 19, 20, destination: 19)
    appendLerp(27, 21, 22, destination: 20)
    appendLerp(28, 19, 20, destination: 19)
    appendLerp(27, 23, 24, destination: 20)
    appendLerp(27, 25, 26, destination: 21)
    appendLerp(28, 20, 21, destination: 20)
    appendLocalGet(19, to: &body)
    appendLocalGet(29, to: &body)
    appendLocalGet(20, to: &body)
    appendLocalGet(19, to: &body)
    body.append(0xa1) // f64.sub
    body.append(0xa2) // f64.mul
    body.append(0xa0) // f64.add
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
            for (coordinate, origin) in zip(
                [x, y, z],
                [octave.originX, octave.originY, octave.originZ]
            ) {
                appendLocalGet(coordinate, to: &body)
                appendDoubleConstant(octave.lacunarity * coordinateMultiplier, to: &body)
                body.append(0xa2) // f64.mul
                appendDoubleConstant(origin, to: &body)
                body.append(0xa0) // f64.add
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

private func makeWASMPairedSIMDFunctionBody(
    program: DensityFunctionIRProgram,
    embeddedNoiseLayouts: [Int: WASMEmbeddedNoiseLayout],
    densitySamplerFunctionIndex: Int?,
    noiseSamplerFunctionIndex: Int?,
    perlinFunctionIndex: Int,
    biomeTreeLayouts: [WASMBiomeTreeLayout],
    alternativeNodeOffset: Int?
) -> [UInt8] {
    precondition(supportsWASMPairedSIMD(program))
    // Six scalar parameters contain x/y/z for two adjacent samples. Every IR value is
    // represented by a v128 local, with the two samples in its low f64/i32 lanes.
    let vectorLocalStart = 6
    let temporaryLocalStart = vectorLocalStart + program.inputTypes.count + program.instructions.count
    func vectorLocal(_ value: Int) -> Int { vectorLocalStart + value }
    let output = program.outputs[0]
    let outputType = output < program.inputTypes.count
        ? program.inputTypes[output]
        : program.instructions[output - program.inputTypes.count].resultType
    let isFusedClimateBiome = outputType == .i32
    let i64InstructionIndices = program.instructions.indices.filter {
        program.instructions[$0].resultType == .i64
    }
    let i64InstructionOffsets = Dictionary(uniqueKeysWithValues: i64InstructionIndices.enumerated().map { ($0.element, $0.offset) })
    let laneI64LocalStart = temporaryLocalStart + 3
    func laneI64Local(_ value: Int, lane: Int) -> Int {
        let instructionIndex = value - program.inputTypes.count
        return laneI64LocalStart + i64InstructionOffsets[instructionIndex]! * 2 + lane
    }
    let biomeScratchI64Start = laneI64LocalStart + i64InstructionIndices.count * 2
    let biomeScratchI32Start = biomeScratchI64Start + 5
    let biomeResultLane0Local = biomeScratchI32Start + 4
    let biomeResultLane1Local = biomeScratchI32Start + 5

    var body = WASMEncoder()
    body.appendUnsigned(isFusedClimateBiome ? 4 : 2)
    body.appendUnsigned(program.inputTypes.count + program.instructions.count)
    body.append(WASMValueType.v128.rawValue)
    body.appendUnsigned(3)
    body.append(WASMValueType.f64.rawValue)
    if isFusedClimateBiome {
        body.appendUnsigned(i64InstructionIndices.count * 2 + 5)
        body.append(WASMValueType.i64.rawValue)
        body.appendUnsigned(6)
        body.append(WASMValueType.i32.rawValue)
    }

    for input in 0..<3 {
        appendLocalGet(input, to: &body)
        appendSIMDOpcode(0x11, to: &body) // i32x4.splat
        appendLocalGet(input + 3, to: &body)
        appendSIMDOpcode(0x1c, to: &body) // i32x4.replace_lane
        body.append(1)
        appendLocalSet(vectorLocal(input), to: &body)
    }

    func appendExtractedCoordinates(_ coordinates: [Int], lane: UInt8, to body: inout WASMEncoder) {
        for (temporary, coordinate) in coordinates.enumerated() {
            appendLocalGet(vectorLocal(coordinate), to: &body)
            appendDoubleExtractLane(lane, to: &body)
            appendLocalSet(temporaryLocalStart + temporary, to: &body)
        }
    }

    for (instructionIndex, instruction) in program.instructions.enumerated() {
        switch instruction {
        case .constant(let value):
            appendDoubleConstant(value, to: &body)
            appendDoubleSplat(to: &body)
        case .convertSignedIntToDouble(let input):
            appendLocalGet(vectorLocal(input), to: &body)
            appendSIMDOpcode(0xfe, to: &body) // f64x2.convert_low_i32x4_s
        case .add(let lhs, let rhs), .subtract(let lhs, let rhs),
             .multiply(let lhs, let rhs), .divide(let lhs, let rhs):
            appendLocalGet(vectorLocal(lhs), to: &body)
            appendLocalGet(vectorLocal(rhs), to: &body)
            let opcode: Int = switch instruction {
            case .add: 0xf0 // f64x2.add
            case .subtract: 0xf1 // f64x2.sub
            case .multiply: 0xf2 // f64x2.mul
            case .divide: 0xf3 // f64x2.div
            default: preconditionFailure()
            }
            appendSIMDOpcode(opcode, to: &body)
        case .negate(let input):
            appendLocalGet(vectorLocal(input), to: &body)
            appendSIMDOpcode(0xed, to: &body) // f64x2.neg
        case .compare(let comparison, let lhs, let rhs):
            appendLocalGet(vectorLocal(lhs), to: &body)
            appendLocalGet(vectorLocal(rhs), to: &body)
            let opcode: Int = switch comparison {
            case .equal: 0x47
            case .lessThan: 0x49
            case .greaterThan: 0x4a
            case .lessThanOrEqual: 0x4b
            case .greaterThanOrEqual: 0x4c
            }
            appendSIMDOpcode(opcode, to: &body)
        case .and(let lhs, let rhs):
            appendLocalGet(vectorLocal(lhs), to: &body)
            appendLocalGet(vectorLocal(rhs), to: &body)
            appendSIMDOpcode(0x4e, to: &body) // v128.and
        case .select(let condition, let whenTrue, let whenFalse):
            appendLocalGet(vectorLocal(whenTrue), to: &body)
            appendLocalGet(vectorLocal(whenFalse), to: &body)
            appendLocalGet(vectorLocal(condition), to: &body)
            appendSIMDOpcode(0x52, to: &body) // v128.bitselect
        case .sampleDensity(let index, let x, let y, let z):
            precondition(x < 3 && y < 3 && z < 3)
            appendIntConstant(Int32(index), to: &body)
            for coordinate in [x, y, z] { appendLocalGet(coordinate, to: &body) }
            appendCall(densitySamplerFunctionIndex!, to: &body)
            appendDoubleSplat(to: &body)
            appendIntConstant(Int32(index), to: &body)
            for coordinate in [x, y, z] { appendLocalGet(coordinate + 3, to: &body) }
            appendCall(densitySamplerFunctionIndex!, to: &body)
            appendDoubleReplaceLane(1, to: &body)
        case .sampleNoise(let index, let x, let y, let z):
            let coordinates = [x, y, z]
            appendExtractedCoordinates(coordinates, lane: 0, to: &body)
            if let embedded = embeddedNoiseLayouts[index] {
                appendEmbeddedNoiseSample(
                    layout: embedded,
                    x: temporaryLocalStart,
                    y: temporaryLocalStart + 1,
                    z: temporaryLocalStart + 2,
                    perlinFunctionIndex: perlinFunctionIndex,
                    to: &body
                )
            } else {
                appendIntConstant(Int32(index), to: &body)
                for temporary in 0..<3 { appendLocalGet(temporaryLocalStart + temporary, to: &body) }
                appendCall(noiseSamplerFunctionIndex!, to: &body)
            }
            appendDoubleSplat(to: &body)
            appendExtractedCoordinates(coordinates, lane: 1, to: &body)
            if let embedded = embeddedNoiseLayouts[index] {
                appendEmbeddedNoiseSample(
                    layout: embedded,
                    x: temporaryLocalStart,
                    y: temporaryLocalStart + 1,
                    z: temporaryLocalStart + 2,
                    perlinFunctionIndex: perlinFunctionIndex,
                    to: &body
                )
            } else {
                appendIntConstant(Int32(index), to: &body)
                for temporary in 0..<3 { appendLocalGet(temporaryLocalStart + temporary, to: &body) }
                appendCall(noiseSamplerFunctionIndex!, to: &body)
            }
            appendDoubleReplaceLane(1, to: &body)
        case .constantInt64(let value):
            precondition(isFusedClimateBiome)
            appendInt64Constant(value, to: &body)
            appendLocalSet(laneI64Local(program.inputTypes.count + instructionIndex, lane: 0), to: &body)
            appendInt64Constant(value, to: &body)
            appendLocalSet(laneI64Local(program.inputTypes.count + instructionIndex, lane: 1), to: &body)
            continue
        case .convertDoubleToSignedInt64(let input):
            precondition(isFusedClimateBiome)
            for lane in 0..<2 {
                appendLocalGet(vectorLocal(input), to: &body)
                appendDoubleExtractLane(UInt8(lane), to: &body)
                body.append(0xb0) // i64.trunc_f64_s
                appendLocalSet(laneI64Local(program.inputTypes.count + instructionIndex, lane: lane), to: &body)
            }
            continue
        case .searchBiome(let index, let point, let initialBestDistance, let initialBestNode, let returnNodeIndex):
            precondition(isFusedClimateBiome)
            precondition(initialBestDistance == nil && initialBestNode == nil && !returnNodeIndex)
            let tree = program.biomeSearchTrees[index]
            for lane in 0..<2 {
                appendBiomeSearchFromMemory(
                    tree: tree,
                    layout: biomeTreeLayouts[index],
                    point: point.map { laneI64Local($0, lane: lane) },
                    initialBestDistance: nil,
                    initialBestNode: nil,
                    alternativeNodeOffset: alternativeNodeOffset,
                    returnNodeIndex: false,
                    resultLocal: biomeResultLane0Local,
                    bestDistanceLocal: biomeScratchI64Start,
                    candidateDistanceLocal: biomeScratchI64Start + 1,
                    deltaLocal: biomeScratchI64Start + 2,
                    minimumLocal: biomeScratchI64Start + 3,
                    maximumLocal: biomeScratchI64Start + 4,
                    stackCountLocal: biomeScratchI32Start,
                    nodeIndexLocal: biomeScratchI32Start + 1,
                    nodeAddressLocal: biomeScratchI32Start + 2,
                    childIndexLocal: biomeScratchI32Start + 3,
                    to: &body
                )
                appendLocalSet(lane == 0 ? biomeResultLane0Local : biomeResultLane1Local, to: &body)
            }
            appendLocalGet(biomeResultLane0Local, to: &body)
            appendSIMDOpcode(0x11, to: &body) // i32x4.splat
            appendLocalGet(biomeResultLane1Local, to: &body)
            appendSIMDOpcode(0x1a, to: &body) // i32x4.replace_lane
            body.append(1)
        case .constantInt32, .divideSignedInt32, .multiplyInt32, .spline:
            preconditionFailure("Unsupported instruction reached paired SIMD lowering.")
        }
        appendLocalSet(vectorLocal(program.inputTypes.count + instructionIndex), to: &body)
    }
    appendLocalGet(vectorLocal(program.output), to: &body)
    body.append(0x0b)
    return body.bytes
}

private func makeWASMBulkFunctionBody(
    bufferContext: CompiledDensityFunctionBufferContext,
    outputOffset: Int,
    scalarFunctionIndex: Int,
    outputValueCount: Int,
    outputType: DensityFunctionIRValueType,
    pairedSIMDFunctionIndex: Int?,
    alternativeNodeOffset: Int?
) -> [UInt8] {
    // Parameters are base x/y/z. Carrying coordinates between iterations avoids three
    // multiply/add pairs in the innermost loop. Supported single-output programs evaluate
    // adjacent samples through paired SIMD IR and write them with one f64x2 store.
    // Z/x/y output order makes Y the natural pairing axis, but a horizontal biome plane
    // has yCount == 1; use adjacent X samples in that case rather than leaving SIMD idle.
    enum PairedSIMDAxis { case y, x }
    let pairedAxis: PairedSIMDAxis? = (outputType == .f64 || outputType == .i32)
        && pairedSIMDFunctionIndex != nil
        && outputValueCount == 1
        ? (bufferContext.yCount >= 2 ? .y : (bufferContext.xCount >= 2 ? .x : nil))
        : nil
    let usesSIMDStores = pairedAxis != nil
    let outputStride = outputType == .i32 ? 4 : 8
    let evenYCount = bufferContext.yCount & ~1
    let evenXCount = bufferContext.xCount & ~1
    let firstOutputLocal = 10
    let vectorLocal = firstOutputLocal + outputValueCount
    var body = WASMEncoder()
    body.appendUnsigned(usesSIMDStores ? 3 : 2)
    body.appendUnsigned(7)
    body.append(WASMValueType.i32.rawValue)
    body.appendUnsigned(outputValueCount)
    body.append(wasmValueType(outputType).rawValue)
    if usesSIMDStores {
        body.appendUnsigned(1)
        body.append(WASMValueType.v128.rawValue)
    }

    if let alternativeNodeOffset {
        appendIntConstant(Int32(alternativeNodeOffset), to: &body)
        appendIntConstant(-1, to: &body)
        appendInt32Store(to: &body)
    }

    appendIntConstant(0, to: &body)
    appendLocalSet(3, to: &body)
    appendLocalGet(2, to: &body)
    appendLocalSet(9, to: &body)
    appendIntConstant(Int32(outputOffset), to: &body)
    appendLocalSet(6, to: &body)

    func appendPairOutputStore() {
        appendLocalGet(6, to: &body)
        appendLocalGet(vectorLocal, to: &body)
        if outputType == .f64 {
            appendDoublePairStore(to: &body)
            appendLocalGet(6, to: &body)
            appendIntConstant(16, to: &body)
            body.append(0x6a) // i32.add
            appendLocalSet(6, to: &body)
        } else {
            appendInt32ExtractLane(0, to: &body)
            appendInt32Store(to: &body)
            appendLocalGet(6, to: &body)
            appendIntConstant(4, to: &body)
            body.append(0x6a) // i32.add
            appendLocalSet(6, to: &body)
            appendLocalGet(6, to: &body)
            appendLocalGet(vectorLocal, to: &body)
            appendInt32ExtractLane(1, to: &body)
            appendInt32Store(to: &body)
            appendLocalGet(6, to: &body)
            appendIntConstant(4, to: &body)
            body.append(0x6a) // i32.add
            appendLocalSet(6, to: &body)
        }
    }

    body.append(0x03) // loop z
    body.append(0x40)
    appendIntConstant(0, to: &body)
    appendLocalSet(4, to: &body)
    appendLocalGet(0, to: &body)
    appendLocalSet(7, to: &body)

    body.append(0x03) // loop x
    body.append(0x40)
    appendIntConstant(0, to: &body)
    appendLocalSet(5, to: &body)
    appendLocalGet(1, to: &body)
    appendLocalSet(8, to: &body)

    if pairedAxis == .y {
        body.append(0x03) // loop over pairs of y samples
        body.append(0x40)

        for local in [7, 8, 9] { appendLocalGet(local, to: &body) }
        appendLocalGet(7, to: &body)
        appendLocalGet(8, to: &body)
        appendIntConstant(bufferContext.yStep, to: &body)
        body.append(0x6a) // i32.add
        appendLocalGet(9, to: &body)
        appendCall(pairedSIMDFunctionIndex!, to: &body)
        appendLocalSet(vectorLocal, to: &body)

        appendPairOutputStore()

        appendLocalGet(8, to: &body)
        appendIntConstant(bufferContext.yStep &* 2, to: &body)
        body.append(0x6a) // i32.add
        appendLocalSet(8, to: &body)
        appendLocalGet(5, to: &body)
        appendIntConstant(2, to: &body)
        body.append(0x6a) // i32.add
        body.append(0x22) // local.tee
        body.appendUnsigned(5)
        appendIntConstant(evenYCount, to: &body)
        body.append(0x49) // i32.lt_u
        body.append(0x0d) // br_if y pair
        body.appendUnsigned(0)
        body.append(0x0b) // end y pair

        if bufferContext.yCount != evenYCount {
            appendLocalGet(7, to: &body)
            appendLocalGet(8, to: &body)
            appendLocalGet(9, to: &body)
            appendCall(scalarFunctionIndex, to: &body)
            appendLocalSet(firstOutputLocal, to: &body)
            appendLocalGet(6, to: &body)
            appendLocalGet(firstOutputLocal, to: &body)
            appendDoubleStore(to: &body)
            appendLocalGet(6, to: &body)
            appendIntConstant(8, to: &body)
            body.append(0x6a) // i32.add
            appendLocalSet(6, to: &body)
        }
    } else if pairedAxis == .x {
        // This route is only selected when yCount == 1. Consecutive X samples are
        // contiguous in the Z/x/y output buffer, so the same f64x2 store is valid.
        body.append(0x03) // loop over pairs of x samples
        body.append(0x40)

        appendLocalGet(7, to: &body)
        appendLocalGet(8, to: &body)
        appendLocalGet(9, to: &body)
        appendLocalGet(7, to: &body)
        appendIntConstant(bufferContext.xStep, to: &body)
        body.append(0x6a) // i32.add
        appendLocalGet(8, to: &body)
        appendLocalGet(9, to: &body)
        appendCall(pairedSIMDFunctionIndex!, to: &body)
        appendLocalSet(vectorLocal, to: &body)

        appendPairOutputStore()

        appendLocalGet(7, to: &body)
        appendIntConstant(bufferContext.xStep &* 2, to: &body)
        body.append(0x6a) // i32.add
        appendLocalSet(7, to: &body)
        appendLocalGet(4, to: &body)
        appendIntConstant(2, to: &body)
        body.append(0x6a) // i32.add
        body.append(0x22) // local.tee
        body.appendUnsigned(4)
        appendIntConstant(evenXCount, to: &body)
        body.append(0x49) // i32.lt_u
        body.append(0x0d) // br_if x pair
        body.appendUnsigned(0)
        body.append(0x0b) // end x pair

        if bufferContext.xCount != evenXCount {
            appendLocalGet(7, to: &body)
            appendLocalGet(8, to: &body)
            appendLocalGet(9, to: &body)
            appendCall(scalarFunctionIndex, to: &body)
            appendLocalSet(firstOutputLocal, to: &body)
            appendLocalGet(6, to: &body)
            appendLocalGet(firstOutputLocal, to: &body)
            appendDoubleStore(to: &body)
            appendLocalGet(6, to: &body)
            appendIntConstant(8, to: &body)
            body.append(0x6a) // i32.add
            appendLocalSet(6, to: &body)
        }
    } else {
        func appendScalarSampleAndStore() {
            appendLocalGet(7, to: &body)
            appendLocalGet(8, to: &body)
            appendLocalGet(9, to: &body)
            appendCall(scalarFunctionIndex, to: &body)
            for outputIndex in (0..<outputValueCount).reversed() {
                appendLocalSet(firstOutputLocal + outputIndex, to: &body)
            }
            for outputIndex in 0..<outputValueCount {
                appendLocalGet(6, to: &body)
                appendLocalGet(firstOutputLocal + outputIndex, to: &body)
                if outputType == .i32 {
                    appendInt32Store(to: &body)
                } else {
                    appendDoubleStore(to: &body)
                }
                appendLocalGet(6, to: &body)
                appendIntConstant(Int32(outputStride), to: &body)
                body.append(0x6a) // i32.add
                appendLocalSet(6, to: &body)
            }
        }
        if bufferContext.yCount == 1 {
            appendScalarSampleAndStore()
        } else {
            body.append(0x03) // loop y
            body.append(0x40)
            appendScalarSampleAndStore()
            appendLocalGet(8, to: &body)
            appendIntConstant(bufferContext.yStep, to: &body)
            body.append(0x6a) // i32.add
            appendLocalSet(8, to: &body)
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
        }
    }

    appendLocalGet(7, to: &body)
    appendIntConstant(bufferContext.xStep, to: &body)
    body.append(0x6a) // i32.add
    appendLocalSet(7, to: &body)
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

    appendLocalGet(9, to: &body)
    appendIntConstant(bufferContext.zStep, to: &body)
    body.append(0x6a) // i32.add
    appendLocalSet(9, to: &body)
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
    bulkExportName: String = "sample_bulk",
    useBulkSIMD: Bool = true,
    useBiomeSearchAlternative: Bool = false
) throws -> [UInt8] {
    let outputTypes: [DensityFunctionIRValueType] = program.outputs.map { output in
        if output < program.inputTypes.count {
            program.inputTypes[output]
        } else {
            program.instructions[output - program.inputTypes.count].resultType
        }
    }
    let bulkOutputType = outputTypes.first
    if bulkContext != nil {
        let outputsHaveSupportedType = bulkOutputType == .f64 || bulkOutputType == .i32
        guard program.inputTypes == [.i32, .i32, .i32],
              let bulkOutputType,
              outputsHaveSupportedType,
              outputTypes.allSatisfy({ $0 == bulkOutputType })
        else {
            throw DensityFunctionCompilationError.badDensityFunction(
                "WASM bulk compilation requires homogeneous f64 or i32 outputs with x/y/z inputs."
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
    let perlinGradientTableOffset = embeddedNoiseLayouts.isEmpty
        ? nil
        : appendPerlinGradientTable(to: &staticData)

    let biomeStackOffset = staticData.bytes.count
    biomeTreeLayouts = biomeTreeLayouts.map {
        WASMBiomeTreeLayout(nodeBaseOffset: $0.nodeBaseOffset, stackOffset: biomeStackOffset)
    }
    let biomeStackEnd = biomeStackOffset + maximumBiomeTreeNodeCount * MemoryLayout<Int32>.size
    let alternativeNodeOffset = useBiomeSearchAlternative && !program.biomeSearchTrees.isEmpty
        ? alignWASMOffset(biomeStackEnd, to: MemoryLayout<Int32>.alignment)
        : nil
    let biomeScratchEnd = alternativeNodeOffset.map { $0 + MemoryLayout<Int32>.size } ?? biomeStackEnd
    if let alternativeNodeOffset {
        if staticData.bytes.count < alternativeNodeOffset {
            staticData.append(contentsOf: [UInt8](
                repeating: 0,
                count: alternativeNodeOffset - staticData.bytes.count
            ))
        }
        staticData.appendFixed(Int32(-1))
    }
    let bulkOutputOffset = bulkContext.map { _ in alignWASMOffset(biomeScratchEnd, to: 16) }
    let bulkOutputEnd: Int
    if let bulkContext, let bulkOutputOffset {
        let (valueCount, valueCountOverflow) = bulkContext.sampleCount.multipliedReportingOverflow(
            by: program.outputs.count
        )
        let outputStride = bulkOutputType == .i32 ? MemoryLayout<Int32>.size : MemoryLayout<Double>.size
        let (byteCount, byteCountOverflow) = valueCount.multipliedReportingOverflow(by: outputStride)
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
    let usesPairedSIMD = useBulkSIMD
        && bulkContext.map { $0.yCount >= 2 || $0.xCount >= 2 } == true
        && supportsWASMPairedSIMD(program)

    let baseTypeCount = 3
    var types = WASMEncoder()
    types.appendUnsigned(baseTypeCount + (bulkContext == nil ? 0 : 1) + (usesPairedSIMD ? 1 : 0))
    appendFunctionType(parameters: [.i32, .i32, .i32, .i32], results: [.f64], to: &types)
    appendFunctionType(parameters: [.i32, .f64, .f64, .f64], results: [.f64], to: &types)
    let mainFunctionTypeIndex = 2
    appendFunctionType(
        parameters: program.inputTypes.map(wasmValueType),
        results: outputTypes.map(wasmValueType),
        to: &types
    )
    let bulkFunctionTypeIndex = bulkContext.map { _ in baseTypeCount }
    if bulkContext != nil {
        appendFunctionType(parameters: [.i32, .i32, .i32], results: [.i32], to: &types)
    }
    let pairedSIMDFunctionTypeIndex = usesPairedSIMD ? baseTypeCount + 1 : nil
    if usesPairedSIMD {
        appendFunctionType(
            parameters: [.i32, .i32, .i32, .i32, .i32, .i32],
            results: [.v128],
            to: &types
        )
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

    let helperFunctionCount = embedsNoiseSampler ? 1 : 0
    let perlinFunctionIndex = importCount
    let mainFunctionIndex = importCount + helperFunctionCount
    let pairedSIMDFunctionIndex = usesPairedSIMD ? mainFunctionIndex + 1 : nil
    let bulkFunctionIndex = bulkContext.map { _ in mainFunctionIndex + 1 + (usesPairedSIMD ? 1 : 0) }

    var functions = WASMEncoder()
    functions.appendUnsigned(helperFunctionCount + 1 + (usesPairedSIMD ? 1 : 0) + (bulkContext == nil ? 0 : 1))
    if embedsNoiseSampler {
        functions.appendUnsigned(1) // perlin
    }
    functions.appendUnsigned(mainFunctionTypeIndex)
    if let pairedSIMDFunctionTypeIndex {
        functions.appendUnsigned(pairedSIMDFunctionTypeIndex)
    }
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
        case .divideSignedInt32(let input, let divisor):
            appendLocalGet(input, to: &body)
            appendIntConstant(divisor, to: &body)
            body.append(0x6d) // i32.div_s
        case .multiplyInt32(let input, let multiplier):
            appendLocalGet(input, to: &body)
            appendIntConstant(multiplier, to: &body)
            body.append(0x6c) // i32.mul
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
        case .spline(let coordinate, let locations, let pointValues, let derivatives):
            func appendPoint() {
                appendLocalGet(coordinate, to: &body)
                body.append(0xb6) // f32.demote_f64
            }
            func appendValue(_ index: Int) {
                appendLocalGet(pointValues[index], to: &body)
                body.append(0xb6) // f32.demote_f64
            }
            func appendOutside(_ index: Int) {
                appendValue(index)
                guard derivatives[index] != 0 else { return }
                appendFloatConstant(derivatives[index], to: &body)
                appendPoint()
                appendFloatConstant(locations[index], to: &body)
                body.append(0x93) // f32.sub
                body.append(0x94) // f32.mul
                body.append(0x92) // f32.add
            }
            func appendInterval(_ index: Int) {
                let width = locations[index + 1] - locations[index]
                // value = lower + delta * (upper - lower)
                appendValue(index)
                appendPoint()
                appendFloatConstant(locations[index], to: &body)
                body.append(0x93)
                appendFloatConstant(width, to: &body)
                body.append(0x95)
                appendValue(index + 1)
                appendValue(index)
                body.append(0x93)
                body.append(0x94)
                body.append(0x92)

                // delta * (1 - delta)
                appendPoint()
                appendFloatConstant(locations[index], to: &body)
                body.append(0x93)
                appendFloatConstant(width, to: &body)
                body.append(0x95)
                appendFloatConstant(1, to: &body)
                appendPoint()
                appendFloatConstant(locations[index], to: &body)
                body.append(0x93)
                appendFloatConstant(width, to: &body)
                body.append(0x95)
                body.append(0x93)
                body.append(0x94)

                // tangent = p + delta * (q - p); repeat p/q rather than reserving scratch locals.
                func appendP() {
                    appendFloatConstant(derivatives[index] * width, to: &body)
                    appendValue(index + 1)
                    appendValue(index)
                    body.append(0x93)
                    body.append(0x93)
                }
                func appendQ() {
                    appendFloatConstant(-derivatives[index + 1] * width, to: &body)
                    appendValue(index + 1)
                    appendValue(index)
                    body.append(0x93)
                    body.append(0x92)
                }
                appendP()
                appendPoint()
                appendFloatConstant(locations[index], to: &body)
                body.append(0x93)
                appendFloatConstant(width, to: &body)
                body.append(0x95)
                appendQ()
                appendP()
                body.append(0x93)
                body.append(0x94)
                body.append(0x92)
                body.append(0x94) // delta product * tangent
                body.append(0x92) // value + tangent term
            }
            func appendIntervals(from index: Int) {
                let last = locations.count - 1
                guard index < last else {
                    appendOutside(last)
                    return
                }
                appendPoint()
                appendFloatConstant(locations[index + 1], to: &body)
                body.append(0x5d) // f32.lt
                body.append(0x04) // if (result f32)
                body.append(0x7d) // f32
                appendInterval(index)
                body.append(0x05) // else
                appendIntervals(from: index + 1)
                body.append(0x0b)
            }
            appendPoint()
            appendFloatConstant(locations[0], to: &body)
            body.append(0x5d) // f32.lt
            body.append(0x04) // if (result f32)
            body.append(0x7d) // f32
            appendOutside(0)
            body.append(0x05) // else
            appendIntervals(from: 0)
            body.append(0x0b)
            body.append(0xbb) // f64.promote_f32
        case .searchBiome(let index, let point, let initialBestDistance, let initialBestNode, let returnNodeIndex):
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
                initialBestDistance: initialBestDistance,
                initialBestNode: initialBestNode,
                alternativeNodeOffset: alternativeNodeOffset,
                returnNodeIndex: returnNodeIndex,
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
    code.appendUnsigned(helperFunctionCount + 1 + (usesPairedSIMD ? 1 : 0) + (bulkContext == nil ? 0 : 1))
    if embedsNoiseSampler {
        let perlinBody = makeWASMPerlinFunctionBody(
            gradientTableOffset: perlinGradientTableOffset!
        )
        code.appendUnsigned(perlinBody.count)
        code.append(contentsOf: perlinBody)
    }
    code.appendUnsigned(body.bytes.count)
    code.append(contentsOf: body.bytes)
    if usesPairedSIMD {
        let pairedSIMDBody = makeWASMPairedSIMDFunctionBody(
            program: program,
            embeddedNoiseLayouts: embeddedNoiseLayouts,
            densitySamplerFunctionIndex: densitySamplerFunctionIndex,
            noiseSamplerFunctionIndex: noiseSamplerFunctionIndex,
            perlinFunctionIndex: perlinFunctionIndex,
            biomeTreeLayouts: biomeTreeLayouts,
            alternativeNodeOffset: alternativeNodeOffset
        )
        code.appendUnsigned(pairedSIMDBody.count)
        code.append(contentsOf: pairedSIMDBody)
    }
    if let bulkContext, let bulkOutputOffset {
        let bulkBody = makeWASMBulkFunctionBody(
            bufferContext: bulkContext,
            outputOffset: bulkOutputOffset,
            scalarFunctionIndex: mainFunctionIndex,
            outputValueCount: program.outputs.count,
            outputType: bulkOutputType!,
            pairedSIMDFunctionIndex: pairedSIMDFunctionIndex,
            alternativeNodeOffset: alternativeNodeOffset
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
