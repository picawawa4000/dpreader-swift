import Foundation

private enum WASMValueType: UInt8 {
    case i32 = 0x7f
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

func buildDensityFunctionWASMModule(_ program: DensityFunctionIRProgram) throws -> [UInt8] {
    var module = WASMEncoder()
    module.append(contentsOf: [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])

    var types = WASMEncoder()
    types.appendUnsigned(3)
    appendFunctionType(parameters: [.i32, .i32, .i32, .i32], results: [.f64], to: &types)
    appendFunctionType(parameters: [.i32, .f64, .f64, .f64], results: [.f64], to: &types)
    appendFunctionType(parameters: [.i32, .i32, .i32], results: [.f64], to: &types)
    module.appendSection(id: 1, contents: types.bytes)

    var imports = WASMEncoder()
    imports.appendUnsigned(2)
    imports.appendName("dpreader")
    imports.appendName("sample_density")
    imports.append(0x00)
    imports.appendUnsigned(0)
    imports.appendName("dpreader")
    imports.appendName("sample_noise")
    imports.append(0x00)
    imports.appendUnsigned(1)
    module.appendSection(id: 2, contents: imports.bytes)

    var functions = WASMEncoder()
    functions.appendUnsigned(1)
    functions.appendUnsigned(2)
    module.appendSection(id: 3, contents: functions.bytes)

    var exports = WASMEncoder()
    exports.appendUnsigned(1)
    exports.appendName("sample")
    exports.append(0x00)
    exports.appendUnsigned(2)
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
    body.appendUnsigned(localRuns.count)
    for run in localRuns {
        body.appendUnsigned(run.count)
        body.append(run.type.rawValue)
    }

    for (instructionIndex, instruction) in program.instructions.enumerated() {
        switch instruction {
        case .constant(let value):
            appendDoubleConstant(value, to: &body)
        case .convertSignedIntToDouble(let input):
            appendLocalGet(input, to: &body)
            body.append(0xb7)
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
            body.appendUnsigned(0)
        case .sampleNoise(let index, let x, let y, let z):
            appendIntConstant(Int32(index), to: &body)
            appendLocalGet(x, to: &body)
            appendLocalGet(y, to: &body)
            appendLocalGet(z, to: &body)
            body.append(0x10)
            body.appendUnsigned(1)
        }
        appendLocalSet(3 + instructionIndex, to: &body)
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
