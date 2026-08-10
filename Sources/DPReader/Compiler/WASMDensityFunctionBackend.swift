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

private func appendBiomeSquaredDistance(
    node: BiomeSearchIRNode,
    point: [Int],
    accumulatorLocal: Int,
    deltaLocal: Int,
    to body: inout WASMEncoder
) {
    appendInt64Constant(0, to: &body)
    appendLocalSet(accumulatorLocal, to: &body)
    for dimension in [2, 3, 5, 4, 0, 1, 6] {
        appendLocalGet(point[dimension], to: &body)
        appendInt64Constant(node.minimums[dimension], to: &body)
        body.append(0x53) // i64.lt_s
        body.append(0x04) // if (result i64)
        body.append(WASMValueType.i64.rawValue)
        appendInt64Constant(node.minimums[dimension], to: &body)
        appendLocalGet(point[dimension], to: &body)
        body.append(0x7d) // i64.sub
        body.append(0x05) // else
        appendLocalGet(point[dimension], to: &body)
        appendInt64Constant(node.maximums[dimension], to: &body)
        body.append(0x55) // i64.gt_s
        body.append(0x04) // if (result i64)
        body.append(WASMValueType.i64.rawValue)
        appendLocalGet(point[dimension], to: &body)
        appendInt64Constant(node.maximums[dimension], to: &body)
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
}

private func appendBiomeSearchVisit(
    tree: BiomeSearchIRTree,
    nodeIndex: Int,
    point: [Int],
    resultLocal: Int,
    bestDistanceLocal: Int,
    candidateDistanceLocal: Int,
    deltaLocal: Int,
    to body: inout WASMEncoder
) {
    let node = tree.nodes[nodeIndex]
    if node.isLeaf {
        appendBiomeSquaredDistance(
            node: node,
            point: point,
            accumulatorLocal: candidateDistanceLocal,
            deltaLocal: deltaLocal,
            to: &body
        )
        appendLocalGet(candidateDistanceLocal, to: &body)
        appendLocalGet(bestDistanceLocal, to: &body)
        body.append(0x57) // i64.le_s
        body.append(0x04) // if
        body.append(0x40) // empty block type
        appendLocalGet(candidateDistanceLocal, to: &body)
        appendLocalSet(bestDistanceLocal, to: &body)
        appendIntConstant(node.valueIndex, to: &body)
        appendLocalSet(resultLocal, to: &body)
        appendLocalGet(candidateDistanceLocal, to: &body)
        body.append(0x50) // i64.eqz
        body.append(0x04) // if
        body.append(0x40) // empty block type
        appendLocalGet(resultLocal, to: &body)
        body.append(0x0f) // return
        body.append(0x0b) // end
        body.append(0x0b) // end
        return
    }

    for childIndex in node.childIndexStart..<(node.childIndexStart + node.childCount) {
        appendBiomeSquaredDistance(
            node: tree.nodes[childIndex],
            point: point,
            accumulatorLocal: candidateDistanceLocal,
            deltaLocal: deltaLocal,
            to: &body
        )
        appendLocalGet(candidateDistanceLocal, to: &body)
        appendLocalGet(bestDistanceLocal, to: &body)
        body.append(0x57) // i64.le_s
        body.append(0x04) // if
        body.append(0x40) // empty block type
        appendBiomeSearchVisit(
            tree: tree,
            nodeIndex: childIndex,
            point: point,
            resultLocal: resultLocal,
            bestDistanceLocal: bestDistanceLocal,
            candidateDistanceLocal: candidateDistanceLocal,
            deltaLocal: deltaLocal,
            to: &body
        )
        body.append(0x0b) // end
    }
}

func buildDensityFunctionWASMModule(
    _ program: DensityFunctionIRProgram,
    exportName: String = "sample"
) throws -> [UInt8] {
    var module = WASMEncoder()
    module.append(contentsOf: [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])

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
            localRuns[localRuns.count - 1].count += 3
        } else {
            localRuns.append((3, .i64))
        }
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
            appendInt64Constant(Int64.max, to: &body)
            appendLocalSet(bestDistanceLocal, to: &body)
            appendIntConstant(-1, to: &body)
            appendLocalSet(resultLocal, to: &body)
            let tree = program.biomeSearchTrees[index]
            if tree.nodes[tree.rootIndex].isLeaf {
                appendIntConstant(tree.nodes[tree.rootIndex].valueIndex, to: &body)
                appendLocalSet(resultLocal, to: &body)
            } else {
                appendBiomeSearchVisit(
                    tree: tree,
                    nodeIndex: tree.rootIndex,
                    point: point,
                    resultLocal: resultLocal,
                    bestDistanceLocal: bestDistanceLocal,
                    candidateDistanceLocal: candidateDistanceLocal,
                    deltaLocal: deltaLocal,
                    to: &body
                )
            }
            appendLocalGet(resultLocal, to: &body)
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
    return module.bytes
}
