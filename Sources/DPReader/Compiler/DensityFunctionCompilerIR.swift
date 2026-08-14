import Foundation

enum DensityFunctionIRValueType: Equatable {
    case i32
    case i64
    case f64
    case condition
}

enum DensityFunctionIRComparison {
    case equal
    case lessThan
    case lessThanOrEqual
    case greaterThan
    case greaterThanOrEqual
}

enum DensityFunctionIRInstruction {
    case constant(Double)
    case constantInt32(Int32)
    case constantInt64(Int64)
    case convertSignedIntToDouble(Int)
    case convertDoubleToSignedInt64(Int)
    case add(Int, Int)
    case subtract(Int, Int)
    case multiply(Int, Int)
    case divide(Int, Int)
    case negate(Int)
    case compare(DensityFunctionIRComparison, Int, Int)
    case and(Int, Int)
    case select(condition: Int, whenTrue: Int, whenFalse: Int)
    case sampleDensity(index: Int, x: Int, y: Int, z: Int)
    case sampleNoise(index: Int, x: Int, y: Int, z: Int)
    case searchBiome(
        index: Int,
        point: [Int],
        initialBestDistance: Int?,
        initialBestNode: Int?,
        returnNodeIndex: Bool
    )

    var resultType: DensityFunctionIRValueType {
        switch self {
        case .compare, .and:
            return .condition
        case .constantInt32, .searchBiome:
            return .i32
        case .constantInt64, .convertDoubleToSignedInt64:
            return .i64
        case .convertSignedIntToDouble, .constant, .add, .subtract, .multiply, .divide,
             .negate, .select, .sampleDensity, .sampleNoise:
            return .f64
        }
    }
}

final class DensityFunctionIRProgram: @unchecked Sendable {
    static let xInput = 0
    static let yInput = 1
    static let zInput = 2

    let inputTypes: [DensityFunctionIRValueType]
    let instructions: [DensityFunctionIRInstruction]
    let outputs: [Int]
    var output: Int { self.outputs[0] }
    let densityFunctions: [any DensityFunction]
    let noises: [any DensityFunctionNoise]
    let biomeSearchTrees: [BiomeSearchIRTree]

    init(
        inputTypes: [DensityFunctionIRValueType] = [.i32, .i32, .i32],
        instructions: [DensityFunctionIRInstruction],
        output: Int,
        densityFunctions: [any DensityFunction],
        noises: [any DensityFunctionNoise],
        biomeSearchTrees: [BiomeSearchIRTree] = []
    ) {
        self.inputTypes = inputTypes
        self.instructions = instructions
        self.outputs = [output]
        self.densityFunctions = densityFunctions
        self.noises = noises
        self.biomeSearchTrees = biomeSearchTrees
    }

    init(
        inputTypes: [DensityFunctionIRValueType] = [.i32, .i32, .i32],
        instructions: [DensityFunctionIRInstruction],
        outputs: [Int],
        densityFunctions: [any DensityFunction],
        noises: [any DensityFunctionNoise],
        biomeSearchTrees: [BiomeSearchIRTree] = []
    ) {
        precondition(!outputs.isEmpty)
        self.inputTypes = inputTypes
        self.instructions = instructions
        self.outputs = outputs
        self.densityFunctions = densityFunctions
        self.noises = noises
        self.biomeSearchTrees = biomeSearchTrees
    }
}

private final class DensityFunctionIRBuilder {
    private let registry: Registry<DensityFunction>
    private var instructions: [DensityFunctionIRInstruction] = []
    private var densityFunctions: [any DensityFunction] = []
    private var noises: [any DensityFunctionNoise] = []
    private var compiledValues: [ObjectIdentifier: Int] = [:]
    private var referenceStack: [String] = []

    init(registry: Registry<DensityFunction>) {
        self.registry = registry
    }

    func build(_ root: any DensityFunction) throws -> DensityFunctionIRProgram {
        try self.build([root])
    }

    func build(_ roots: [any DensityFunction]) throws -> DensityFunctionIRProgram {
        precondition(!roots.isEmpty)
        let outputs = try roots.map { try self.compile($0) }
        return DensityFunctionIRProgram(
            instructions: self.instructions,
            outputs: outputs,
            densityFunctions: self.densityFunctions,
            noises: self.noises
        )
    }

    private func append(_ instruction: DensityFunctionIRInstruction) -> Int {
        let value = 3 + self.instructions.count
        self.instructions.append(instruction)
        return value
    }

    private func constant(_ value: Double) -> Int {
        self.append(.constant(value))
    }

    private func compile(_ function: any DensityFunction) throws -> Int {
        if let reference = function as? ReferenceDensityFunction {
            let key = reference.targetKey.name
            guard !self.referenceStack.contains(key) else {
                throw DensityFunctionCompilationError.badDensityFunction(
                    "Cyclic density function reference: \((self.referenceStack + [key]).joined(separator: " -> "))"
                )
            }
            guard let target = self.registry.get(reference.targetKey) else {
                throw DensityFunctionCompilationError.badDensityFunction("Missing referenced density function: \(key)")
            }
            self.referenceStack.append(key)
            defer { _ = self.referenceStack.popLast() }
            return try self.compile(target)
        }

        let identity = ObjectIdentifier(function as AnyObject)
        if let existing = self.compiledValues[identity] {
            return existing
        }

        let value = try self.compileUncached(function)
        self.compiledValues[identity] = value
        return value
    }

    private func compileUncached(_ function: any DensityFunction) throws -> Int {
        if let constant = function as? ConstantDensityFunction {
            return self.constant(constant.constantValue)
        }
        if let unary = function as? UnaryDensityFunction {
            let input = try self.compile(unary.inputOperand)
            switch unary.operationType {
            case .ABS:
                let zero = self.constant(0.0)
                let negative = self.append(.compare(.lessThan, input, zero))
                return self.append(.select(
                    condition: negative,
                    whenTrue: self.append(.negate(input)),
                    whenFalse: input
                ))
            case .SQUARE:
                return self.append(.multiply(input, input))
            case .CUBE:
                return self.append(.multiply(input, self.append(.multiply(input, input))))
            case .HALF_NEGATIVE, .QUARTER_NEGATIVE:
                let zero = self.constant(0.0)
                let negative = self.append(.compare(.lessThan, input, zero))
                let factor = self.constant(unary.operationType == .HALF_NEGATIVE ? 0.5 : 0.25)
                let scaled = self.append(.multiply(input, factor))
                return self.append(.select(condition: negative, whenTrue: scaled, whenFalse: input))
            case .SQUEEZE:
                let negativeOne = self.constant(-1.0)
                let one = self.constant(1.0)
                let below = self.append(.compare(.lessThan, input, negativeOne))
                let clampedLow = self.append(.select(condition: below, whenTrue: negativeOne, whenFalse: input))
                let above = self.append(.compare(.greaterThan, clampedLow, one))
                let clamped = self.append(.select(condition: above, whenTrue: one, whenFalse: clampedLow))
                let half = self.append(.multiply(clamped, self.constant(0.5)))
                let square = self.append(.multiply(clamped, clamped))
                let cube = self.append(.multiply(clamped, square))
                return self.append(.subtract(half, self.append(.divide(cube, self.constant(24.0)))))
            case .INVERT:
                return self.append(.divide(self.constant(1.0), input))
            }
        }
        if let binary = function as? BinaryDensityFunction {
            let first = try self.compile(binary.firstOperand)
            let second = try self.compile(binary.secondOperand)
            switch binary.operationType {
            case .ADD:
                return self.append(.add(first, second))
            case .MULTIPLY:
                let zero = self.constant(0.0)
                let firstIsZero = self.append(.compare(.equal, first, zero))
                let multiplied = self.append(.multiply(first, second))
                return self.append(.select(condition: firstIsZero, whenTrue: zero, whenFalse: multiplied))
            case .MINIMUM:
                let firstIsLess = self.append(.compare(.lessThan, first, second))
                return self.append(.select(condition: firstIsLess, whenTrue: first, whenFalse: second))
            case .MAXIMUM:
                let firstIsGreater = self.append(.compare(.greaterThan, first, second))
                return self.append(.select(condition: firstIsGreater, whenTrue: first, whenFalse: second))
            }
        }
        if let clampFunction = function as? ClampDensityFunction {
            let input = try self.compile(clampFunction.clampedInput)
            let lower = self.constant(clampFunction.minimumValue)
            let upper = self.constant(clampFunction.maximumValue)
            let below = self.append(.compare(.lessThan, input, lower))
            let clampedLow = self.append(.select(condition: below, whenTrue: lower, whenFalse: input))
            let above = self.append(.compare(.greaterThan, clampedLow, upper))
            return self.append(.select(condition: above, whenTrue: upper, whenFalse: clampedLow))
        }
        if let gradient = function as? YClampedGradient {
            let attributes = gradient.testingAttributes
            let y = self.append(.convertSignedIntToDouble(DensityFunctionIRProgram.yInput))
            let fromY = self.constant(Double(attributes.fromY))
            let toY = self.constant(Double(attributes.toY))
            let delta = self.append(.divide(
                self.append(.subtract(y, fromY)),
                self.append(.subtract(toY, fromY))
            ))
            let fromValue = self.constant(gradient.minimumOutputValue)
            let toValue = self.constant(gradient.maximumOutputValue)
            let interpolated = self.append(.add(
                fromValue,
                self.append(.multiply(
                    delta,
                    self.append(.subtract(toValue, fromValue))
                ))
            ))
            let below = self.append(.compare(.lessThanOrEqual, delta, self.constant(0.0)))
            let above = self.append(.compare(.greaterThanOrEqual, delta, self.constant(1.0)))
            let clampedHigh = self.append(.select(condition: above, whenTrue: toValue, whenFalse: interpolated))
            return self.append(.select(condition: below, whenTrue: fromValue, whenFalse: clampedHigh))
        }
        if let rangeChoice = function as? RangeChoice {
            let input = try self.compile(rangeChoice.inputChoiceFunction)
            let minimum = self.constant(rangeChoice.minimumInclusive)
            let maximum = self.constant(rangeChoice.maximumExclusive)
            let atLeastMinimum = self.append(.compare(.greaterThanOrEqual, input, minimum))
            let belowMaximum = self.append(.compare(.lessThan, input, maximum))
            let inRange = self.append(.and(atLeastMinimum, belowMaximum))
            let whenInRange = try self.compile(rangeChoice.whenInRangeOutput)
            let whenOutOfRange = try self.compile(rangeChoice.whenOutOfRangeOutput)
            return self.append(.select(condition: inRange, whenTrue: whenInRange, whenFalse: whenOutOfRange))
        }
        if let noise = function as? NoiseDensityFunction {
            let x = self.append(.convertSignedIntToDouble(DensityFunctionIRProgram.xInput))
            let y = self.append(.convertSignedIntToDouble(DensityFunctionIRProgram.yInput))
            let z = self.append(.convertSignedIntToDouble(DensityFunctionIRProgram.zInput))
            let sampleX = self.append(.multiply(x, self.constant(noise.xzScaleValue)))
            let sampleY = self.append(.multiply(y, self.constant(noise.yScaleValue)))
            let sampleZ = self.append(.multiply(z, self.constant(noise.xzScaleValue)))
            let noiseIndex = self.noises.count
            self.noises.append(noise.noiseSampler)
            return self.append(.sampleNoise(index: noiseIndex, x: sampleX, y: sampleY, z: sampleZ))
        }
        if let shift = function as? ShiftDensityFunction {
            let attributes = shift.testingAttributes
            let x = self.append(.convertSignedIntToDouble(DensityFunctionIRProgram.xInput))
            let y = self.append(.convertSignedIntToDouble(DensityFunctionIRProgram.yInput))
            let z = self.append(.convertSignedIntToDouble(DensityFunctionIRProgram.zInput))
            let quarter = self.constant(0.25)
            let zero = self.constant(0.0)
            let sampleX: Int
            let sampleY: Int
            let sampleZ: Int
            switch attributes.shiftType {
            case .SHIFT_ALL:
                sampleX = self.append(.multiply(x, quarter))
                sampleY = self.append(.multiply(y, quarter))
                sampleZ = self.append(.multiply(z, quarter))
            case .SHIFT_XZ:
                sampleX = self.append(.multiply(x, quarter))
                sampleY = zero
                sampleZ = self.append(.multiply(z, quarter))
            case .SHIFT_ZX:
                sampleX = self.append(.multiply(z, quarter))
                sampleY = self.append(.multiply(x, quarter))
                sampleZ = zero
            }
            let noiseIndex = self.noises.count
            self.noises.append(attributes.noise)
            let sampled = self.append(.sampleNoise(
                index: noiseIndex,
                x: sampleX,
                y: sampleY,
                z: sampleZ
            ))
            return self.append(.multiply(sampled, self.constant(4.0)))
        }
        if let shifted = function as? ShiftedNoise {
            let shiftX = try self.compile(shifted.shiftXFunction)
            let shiftY = try self.compile(shifted.shiftYFunction)
            let shiftZ = try self.compile(shifted.shiftZFunction)
            let x = self.append(.convertSignedIntToDouble(DensityFunctionIRProgram.xInput))
            let y = self.append(.convertSignedIntToDouble(DensityFunctionIRProgram.yInput))
            let z = self.append(.convertSignedIntToDouble(DensityFunctionIRProgram.zInput))
            let sampleX = self.append(.add(
                self.append(.multiply(x, self.constant(shifted.xzScaleValue))),
                shiftX
            ))
            let sampleY = self.append(.add(
                self.append(.multiply(y, self.constant(shifted.yScaleValue))),
                shiftY
            ))
            let sampleZ = self.append(.add(
                self.append(.multiply(z, self.constant(shifted.xzScaleValue))),
                shiftZ
            ))
            let noiseIndex = self.noises.count
            self.noises.append(shifted.noiseSampler)
            return self.append(.sampleNoise(index: noiseIndex, x: sampleX, y: sampleY, z: sampleZ))
        }
        if function is BlendAlpha {
            return self.constant(1.0)
        }
        if function is BlendOffset || function is BeardifierMarker {
            return self.constant(0.0)
        }
        if let blend = function as? BlendDensity {
            return try self.compile(blend.argumentFunction)
        }
        if let marker = function as? CacheMarker {
            return try self.compile(marker.argument)
        }
        if let wrapper = function as? ChunkPositionCache {
            return try self.compile(wrapper.wrappedDensityFunction)
        }

        let functionIndex = self.densityFunctions.count
        self.densityFunctions.append(function)
        return self.append(.sampleDensity(
            index: functionIndex,
            x: DensityFunctionIRProgram.xInput,
            y: DensityFunctionIRProgram.yInput,
            z: DensityFunctionIRProgram.zInput
        ))
    }
}

func buildDensityFunctionIR(
    densityFunction: any DensityFunction,
    registry: Registry<DensityFunction>
) throws -> DensityFunctionIRProgram {
    try DensityFunctionIRBuilder(registry: registry).build(densityFunction)
}

func buildDensityFunctionIR(
    densityFunctions: [any DensityFunction],
    registry: Registry<DensityFunction>
) throws -> DensityFunctionIRProgram {
    try DensityFunctionIRBuilder(registry: registry).build(densityFunctions)
}

private enum DensityFunctionIRRuntimeValue {
    case i32(Int32)
    case i64(Int64)
    case f64(Double)
    case condition(Bool)
}

private func evaluateDensityFunctionIR(
    _ program: DensityFunctionIRProgram,
    inputs: [DensityFunctionIRRuntimeValue]
) -> DensityFunctionIRRuntimeValue {
    precondition(inputs.count == program.inputTypes.count, "Incorrect IR input count.")
    var values = inputs
    values.reserveCapacity(inputs.count + program.instructions.count)

    func int(_ index: Int) -> Int32 {
        guard case .i32(let value) = values[index] else { preconditionFailure("Expected i32 IR value.") }
        return value
    }
    func double(_ index: Int) -> Double {
        guard case .f64(let value) = values[index] else { preconditionFailure("Expected f64 IR value.") }
        return value
    }
    func int64(_ index: Int) -> Int64 {
        guard case .i64(let value) = values[index] else { preconditionFailure("Expected i64 IR value.") }
        return value
    }
    func condition(_ index: Int) -> Bool {
        guard case .condition(let value) = values[index] else { preconditionFailure("Expected condition IR value.") }
        return value
    }

    for instruction in program.instructions {
        let result: DensityFunctionIRRuntimeValue
        switch instruction {
        case .constant(let value): result = .f64(value)
        case .constantInt32(let value): result = .i32(value)
        case .constantInt64(let value): result = .i64(value)
        case .convertSignedIntToDouble(let input): result = .f64(Double(int(input)))
        case .convertDoubleToSignedInt64(let input): result = .i64(Int64(double(input)))
        case .add(let lhs, let rhs): result = .f64(double(lhs) + double(rhs))
        case .subtract(let lhs, let rhs): result = .f64(double(lhs) - double(rhs))
        case .multiply(let lhs, let rhs): result = .f64(double(lhs) * double(rhs))
        case .divide(let lhs, let rhs): result = .f64(double(lhs) / double(rhs))
        case .negate(let input): result = .f64(-double(input))
        case .compare(let comparison, let lhs, let rhs):
            let left = double(lhs)
            let right = double(rhs)
            let comparisonResult: Bool = switch comparison {
            case .equal: left == right
            case .lessThan: left < right
            case .lessThanOrEqual: left <= right
            case .greaterThan: left > right
            case .greaterThanOrEqual: left >= right
            }
            result = .condition(comparisonResult)
        case .and(let lhs, let rhs): result = .condition(condition(lhs) && condition(rhs))
        case .select(let conditionValue, let whenTrue, let whenFalse):
            result = .f64(condition(conditionValue) ? double(whenTrue) : double(whenFalse))
        case .sampleDensity(let index, let sampleX, let sampleY, let sampleZ):
            result = .f64(program.densityFunctions[index].sample(at: PosInt3D(
                x: int(sampleX),
                y: int(sampleY),
                z: int(sampleZ)
            )))
        case .sampleNoise(let index, let sampleX, let sampleY, let sampleZ):
            result = .f64(program.noises[index].sample(
                x: double(sampleX),
                y: double(sampleY),
                z: double(sampleZ)
            ))
        case .searchBiome(let index, let point, let initialBestDistance, let initialBestNode, let returnNodeIndex):
            precondition(point.count == 7, "Biome search IR requires seven parameters.")
            result = .i32(program.biomeSearchTrees[index].search(
                point.map(int64),
                initialBestDistance: initialBestDistance.map { int64($0) } ?? Int64.max,
                initialBestNode: initialBestNode.map { int($0) } ?? -1,
                returnNodeIndex: returnNodeIndex
            ))
        }
        values.append(result)
    }

    return values[program.output]
}

func evaluateDensityFunctionIR(
    _ program: DensityFunctionIRProgram,
    x: Int32,
    y: Int32,
    z: Int32
) -> Double {
    guard case .f64(let result) = evaluateDensityFunctionIR(
        program,
        inputs: [.i32(x), .i32(y), .i32(z)]
    ) else {
        preconditionFailure("Density function IR did not produce f64.")
    }
    return result
}

func evaluateBiomeIDIR(
    _ program: DensityFunctionIRProgram,
    x: Int32,
    y: Int32,
    z: Int32
) -> Int32 {
    guard case .i32(let result) = evaluateDensityFunctionIR(
        program,
        inputs: [.i32(x), .i32(y), .i32(z)]
    ) else {
        preconditionFailure("Biome ID IR did not produce i32.")
    }
    return result
}

func evaluateBiomeSearchIR(
    _ program: DensityFunctionIRProgram,
    point: NoisePoint,
    initialBestDistance: Int64 = Int64.max,
    initialBestNode: Int32 = -1
) -> Int32 {
    guard case .i32(let result) = evaluateDensityFunctionIR(
        program,
        inputs: [
            .f64(point.temperature),
            .f64(point.humidity),
            .f64(point.continentalness),
            .f64(point.erosion),
            .f64(point.weirdness),
            .f64(point.depth),
            .i64(initialBestDistance),
            .i32(initialBestNode)
        ]
    ) else {
        preconditionFailure("Biome search IR did not produce i32.")
    }
    return result
}
