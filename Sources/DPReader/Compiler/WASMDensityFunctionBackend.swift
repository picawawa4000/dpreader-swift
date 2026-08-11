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
    appendLocalGet(resultLocal, to: &body)
    body.append(0x0f) // return
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

func buildDensityFunctionWASMModule(
    _ program: DensityFunctionIRProgram,
    exportName: String = "sample"
) throws -> [UInt8] {
    var module = WASMEncoder()
    module.append(contentsOf: [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])

    var biomeTreeData = WASMEncoder()
    var biomeTreeLayouts: [WASMBiomeTreeLayout] = []
    var maximumBiomeTreeNodeCount = 0
    for tree in program.biomeSearchTrees {
        let nodeBaseOffset = biomeTreeData.bytes.count
        for node in tree.nodes {
            biomeTreeData.appendFixed(node.valueIndex)
            biomeTreeData.appendFixed(Int32(node.childIndexStart))
            biomeTreeData.appendFixed(Int32(node.childCount))
            biomeTreeData.appendFixed(Int32(node.minimums[6] <= 0 && node.maximums[6] >= 0 ? 1 : 0))
            for minimum in node.minimums { biomeTreeData.appendFixed(minimum) }
            for maximum in node.maximums { biomeTreeData.appendFixed(maximum) }
        }
        biomeTreeLayouts.append(WASMBiomeTreeLayout(nodeBaseOffset: nodeBaseOffset, stackOffset: 0))
        maximumBiomeTreeNodeCount = max(maximumBiomeTreeNodeCount, tree.nodes.count)
    }
    let biomeStackOffset = biomeTreeData.bytes.count
    biomeTreeLayouts = biomeTreeLayouts.map {
        WASMBiomeTreeLayout(nodeBaseOffset: $0.nodeBaseOffset, stackOffset: biomeStackOffset)
    }

    let importsDensitySampler = program.instructions.contains { instruction in
        if case .sampleDensity = instruction { return true }
        return false
    }
    let importsNoiseSampler = program.instructions.contains { instruction in
        if case .sampleNoise = instruction { return true }
        return false
    }
    let densitySamplerFunctionIndex = importsDensitySampler ? 0 : nil
    let noiseSamplerFunctionIndex = importsNoiseSampler ? (importsDensitySampler ? 1 : 0) : nil
    let importCount = (importsDensitySampler ? 1 : 0) + (importsNoiseSampler ? 1 : 0)

    var types = WASMEncoder()
    types.appendUnsigned(3)
    appendFunctionType(parameters: [.i32, .i32, .i32, .i32], results: [.f64], to: &types)
    appendFunctionType(parameters: [.i32, .f64, .f64, .f64], results: [.f64], to: &types)
    let outputType: DensityFunctionIRValueType = if program.output < program.inputTypes.count {
        program.inputTypes[program.output]
    } else {
        program.instructions[program.output - program.inputTypes.count].resultType
    }
    appendFunctionType(
        parameters: program.inputTypes.map(wasmValueType),
        results: [wasmValueType(outputType)],
        to: &types
    )
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

    var functions = WASMEncoder()
    functions.appendUnsigned(1)
    functions.appendUnsigned(2)
    module.appendSection(id: 3, contents: functions.bytes)

    if !program.biomeSearchTrees.isEmpty {
        var memories = WASMEncoder()
        memories.appendUnsigned(1)
        memories.append(0x00) // minimum only
        let requiredByteCount = biomeStackOffset + maximumBiomeTreeNodeCount * MemoryLayout<Int32>.size
        memories.appendUnsigned(max(1, (requiredByteCount + 65_535) / 65_536))
        module.appendSection(id: 5, contents: memories.bytes)
    }

    var exports = WASMEncoder()
    exports.appendUnsigned(1)
    exports.appendName(exportName)
    exports.append(0x00)
    exports.appendUnsigned(importCount)
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
            appendIntConstant(Int32(index), to: &body)
            appendLocalGet(x, to: &body)
            appendLocalGet(y, to: &body)
            appendLocalGet(z, to: &body)
            body.append(0x10)
            body.appendUnsigned(noiseSamplerFunctionIndex!)
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
    appendLocalGet(program.output, to: &body)
    body.append(0x0b)

    var code = WASMEncoder()
    code.appendUnsigned(1)
    code.appendUnsigned(body.bytes.count)
    code.append(contentsOf: body.bytes)
    module.appendSection(id: 10, contents: code.bytes)
    if !program.biomeSearchTrees.isEmpty {
        var data = WASMEncoder()
        data.appendUnsigned(1)
        data.append(0x00) // active segment for memory 0
        appendIntConstant(0, to: &data)
        data.append(0x0b) // end offset expression
        data.appendUnsigned(biomeTreeData.bytes.count)
        data.append(contentsOf: biomeTreeData.bytes)
        module.appendSection(id: 11, contents: data.bytes)
    }
    return module.bytes
}
