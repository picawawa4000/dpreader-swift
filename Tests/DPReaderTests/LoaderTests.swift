import Testing
import Foundation
@testable import DPReader

private func testReference(densityFunction: DensityFunction, expectedID: String) -> Bool {
    return densityFunction is ReferenceDensityFunction && (densityFunction as! ReferenceDensityFunction).targetKey.name == expectedID
}
private func testConstant(densityFunction: DensityFunction, expectedValue: Double) -> Bool {
    return densityFunction is ConstantDensityFunction && (densityFunction as! ConstantDensityFunction).testingAttributes.value == expectedValue
}

@Test func testLoadingForNoises() async throws {
    let packURL = URL(filePath: "Tests/Resources/Datapacks/Noises/noises")
    let dataPack = try DataPack(fromRootPath: packURL, loadingOptions: [.loadNoises])

    guard let noise = dataPack.noiseRegistry.get(RegistryKey(referencing: "test:example")) else {
        throw Errors.noiseNotFound("test:example")
    }
    #expect(noise.testingAttributes.firstOctave == -10)
    #expect(noise.testingAttributes.amplitudes == [1.0, 0.25, 0.0, 0.5])
}

// Testing loading for:
// - Reference
// - Constant
// - RangeChoice
// - ShiftedNoise
// - Clamp
// - YClampedGradient
@Test func testLoadingForMonotypeDensityFunctions() async throws {
    let packURL = URL(filePath: "Tests/Resources/Datapacks/DensityFunctions/monotype")
    let dataPack = try DataPack(fromRootPath: packURL, loadingOptions: [.loadDensityFunctions])

    guard let continentalness = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:continentalness")) else {
        throw Errors.densityFunctionNotFound("test:continentalness")
    }
    guard let rcContinentalness = continentalness as? RangeChoice else {
        throw Errors.densityFunctionWrongType("test:continentalness -> RangeChoice")
    }
    #expect(rcContinentalness.testingAttributes.minInclusive == 0.5)
    #expect(rcContinentalness.testingAttributes.maxExclusive == 1.5)
    #expect(testReference(densityFunction: rcContinentalness.testingAttributes.inputChoice, expectedID: "test:dummy/shifted_noise"))
    #expect(testReference(densityFunction: rcContinentalness.testingAttributes.whenInRange, expectedID: "test:dummy/clamp"))
    #expect(testReference(densityFunction: rcContinentalness.testingAttributes.whenOutOfRange, expectedID: "test:dummy/y_clamped_gradient"))

    guard let iShiftedNoise = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:dummy/shifted_noise")) else {
        throw Errors.densityFunctionNotFound("test:shifted_noise")
    }
    guard let shiftedNoise = iShiftedNoise as? ShiftedNoise else {
        throw Errors.densityFunctionWrongType("test:shifted_noise -> ShiftedNoise")
    }
    #expect(testConstant(densityFunction: shiftedNoise.testingAttributes.shiftX, expectedValue: 1.5))
    #expect(testConstant(densityFunction: shiftedNoise.testingAttributes.shiftY, expectedValue: 3.0))
    #expect(testConstant(densityFunction: shiftedNoise.testingAttributes.shiftZ, expectedValue: 5.0))
    #expect(shiftedNoise.testingAttributes.scaleXZ == 0.5)
    #expect(shiftedNoise.testingAttributes.scaleY == 0.75)
    #expect(shiftedNoise.testingAttributes.noise.key.name == "test:continents")

    guard let iClamp = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:dummy/clamp")) else {
        throw Errors.densityFunctionNotFound("test:clamp")
    }
    guard let clamp = iClamp as? ClampDensityFunction else {
        throw Errors.densityFunctionWrongType("test:clamp -> ClampDensityFunction")
    }
    #expect(testConstant(densityFunction: clamp.testingAttributes.input, expectedValue: 0.5))
    #expect(clamp.testingAttributes.lowerBound == 0.0)
    #expect(clamp.testingAttributes.upperBound == 1.0)

    guard let iYClampedGradient = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:dummy/y_clamped_gradient")) else {
        throw Errors.densityFunctionNotFound("test:y_clamped_gradient")
    }
    guard let yClampedGradient = iYClampedGradient as? YClampedGradient else {
        throw Errors.densityFunctionWrongType("test:y_clamped_gradient -> YClampedGradient")
    }
    #expect(yClampedGradient.testingAttributes.fromY == 10)
    #expect(yClampedGradient.testingAttributes.toY == 50)
    #expect(yClampedGradient.testingAttributes.fromValue == -0.5)
    #expect(yClampedGradient.testingAttributes.toValue == 0.75)
}

// Testing loading for:
// - Unary
@Test func testLoadingForUnaryDensityFunctions() async throws {
    let packURL = URL(filePath: "Tests/Resources/Datapacks/DensityFunctions/unary")
    let dataPack = try DataPack(fromRootPath: packURL, loadingOptions: [.loadDensityFunctions])

    guard let iAbs = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:abs")) else {
        throw Errors.densityFunctionNotFound("test:abs")
    }
    guard let abs = iAbs as? UnaryDensityFunction else {
        throw Errors.densityFunctionWrongType("test:abs -> UnaryDensityFunction")
    }
    #expect(abs.testingAttributes.operation == .ABS)
    #expect(testConstant(densityFunction: abs.testingAttributes.operand, expectedValue: 0.5))

    guard let iSquare = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:square")) else {
        throw Errors.densityFunctionNotFound("test:square")
    }
    guard let square = iSquare as? UnaryDensityFunction else {
        throw Errors.densityFunctionWrongType("test:square -> UnaryDensityFunction")
    }
    #expect(square.testingAttributes.operation == .SQUARE)
    #expect(testConstant(densityFunction: square.testingAttributes.operand, expectedValue: 0.5))

    guard let iCube = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:cube")) else {
        throw Errors.densityFunctionNotFound("test:cube")
    }
    guard let cube = iCube as? UnaryDensityFunction else {
        throw Errors.densityFunctionWrongType("test:cube -> UnaryDensityFunction")
    }
    #expect(cube.testingAttributes.operation == .CUBE)
    #expect(testConstant(densityFunction: cube.testingAttributes.operand, expectedValue: 0.5))

    guard let iHalfNegative = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:half_negative")) else {
        throw Errors.densityFunctionNotFound("test:half_negative")
    }
    guard let halfNegative = iHalfNegative as? UnaryDensityFunction else {
        throw Errors.densityFunctionWrongType("test:half_negative -> UnaryDensityFunction")
    }
    #expect(halfNegative.testingAttributes.operation == .HALF_NEGATIVE)
    #expect(testConstant(densityFunction: halfNegative.testingAttributes.operand, expectedValue: 0.5))

    guard let iQuarterNegative = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:quarter_negative")) else {
        throw Errors.densityFunctionNotFound("test:quarter_negative")
    }
    guard let quarterNegative = iQuarterNegative as? UnaryDensityFunction else {
        throw Errors.densityFunctionWrongType("test:quarter_negative -> UnaryDensityFunction")
    }
    #expect(quarterNegative.testingAttributes.operation == .QUARTER_NEGATIVE)
    #expect(testConstant(densityFunction: quarterNegative.testingAttributes.operand, expectedValue: 0.5))

    guard let iSqueeze = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:squeeze")) else {
        throw Errors.densityFunctionNotFound("test:squeeze")
    }
    guard let squeeze = iSqueeze as? UnaryDensityFunction else {
        throw Errors.densityFunctionWrongType("test:squeeze -> UnaryDensityFunction")
    }
    #expect(squeeze.testingAttributes.operation == .SQUEEZE)
    #expect(testConstant(densityFunction: squeeze.testingAttributes.operand, expectedValue: 0.5))

    guard let iInvert = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:invert")) else {
        throw Errors.densityFunctionNotFound("test:invert")
    }
    guard let invert = iInvert as? UnaryDensityFunction else {
        throw Errors.densityFunctionWrongType("test:invert -> UnaryDensityFunction")
    }
    #expect(invert.testingAttributes.operation == .INVERT)
    #expect(testConstant(densityFunction: invert.testingAttributes.operand, expectedValue: 0.5))
}

// Testing loading for:
// - Binary
@Test func testLoadingForBinaryDensityFunctions() async throws {
    let packURL = URL(filePath: "Tests/Resources/Datapacks/DensityFunctions/binary")
    let dataPack = try DataPack(fromRootPath: packURL, loadingOptions: [.loadDensityFunctions])

    guard let iAdd = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:add")) else {
        throw Errors.densityFunctionNotFound("test:add")
    }
    guard let add = iAdd as? BinaryDensityFunction else {
        throw Errors.densityFunctionWrongType("test:add -> BinaryDensityFunction")
    }
    #expect(add.testingAttributes.operation == .ADD)
    #expect(testConstant(densityFunction: add.testingAttributes.first, expectedValue: -0.5))
    #expect(testConstant(densityFunction: add.testingAttributes.second, expectedValue: 0.75))

    guard let iMultiply = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:mul")) else {
        throw Errors.densityFunctionNotFound("test:mul")
    }
    guard let multiply = iMultiply as? BinaryDensityFunction else {
        throw Errors.densityFunctionWrongType("test:mul -> BinaryDensityFunction")
    }
    #expect(multiply.testingAttributes.operation == .MULTIPLY)
    #expect(testConstant(densityFunction: multiply.testingAttributes.first, expectedValue: -0.5))
    #expect(testConstant(densityFunction: multiply.testingAttributes.second, expectedValue: 0.75))

    guard let iMinimum = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:min")) else {
        throw Errors.densityFunctionNotFound("test:min")
    }
    guard let minimum = iMinimum as? BinaryDensityFunction else {
        throw Errors.densityFunctionWrongType("test:min -> BinaryDensityFunction")
    }
    #expect(minimum.testingAttributes.operation == .MINIMUM)
    #expect(testConstant(densityFunction: minimum.testingAttributes.first, expectedValue: -0.5))
    #expect(testConstant(densityFunction: minimum.testingAttributes.second, expectedValue: 0.75))

    guard let iMaximum = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:max")) else {
        throw Errors.densityFunctionNotFound("test:max")
    }
    guard let maximum = iMaximum as? BinaryDensityFunction else {
        throw Errors.densityFunctionWrongType("test:max -> BinaryDensityFunction")
    }
    #expect(maximum.testingAttributes.operation == .MAXIMUM)
    #expect(testConstant(densityFunction: maximum.testingAttributes.first, expectedValue: -0.5))
    #expect(testConstant(densityFunction: maximum.testingAttributes.second, expectedValue: 0.75))
}

// Testing loading for:
// - Shift
@Test func testLoadingForShiftDensityFunctions() async throws {
    let packURL = URL(filePath: "Tests/Resources/Datapacks/DensityFunctions/shift")
    let dataPack = try DataPack(fromRootPath: packURL, loadingOptions: [.loadDensityFunctions])

    guard let iShiftA = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:shift_a")) else {
        throw Errors.densityFunctionNotFound("test:shift_a")
    }
    guard let shiftA = iShiftA as? ShiftDensityFunction else {
        throw Errors.densityFunctionWrongType("test:shift_a -> ShiftDensityFunction")
    }
    #expect(shiftA.testingAttributes.shiftType == .SHIFT_XZ)
    #expect(shiftA.testingAttributes.noise.key.name == "test:continents")

    guard let iShiftB = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:shift_b")) else {
        throw Errors.densityFunctionNotFound("test:shift_a")
    }
    guard let shiftB = iShiftB as? ShiftDensityFunction else {
        throw Errors.densityFunctionWrongType("test:shift_b -> ShiftDensityFunction")
    }
    #expect(shiftB.testingAttributes.shiftType == .SHIFT_ZX)
    #expect(shiftB.testingAttributes.noise.key.name == "test:continents")

    guard let iShift = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:shift")) else {
        throw Errors.densityFunctionNotFound("test:shift")
    }
    guard let shift = iShift as? ShiftDensityFunction else {
        throw Errors.densityFunctionWrongType("test:shift -> ShiftDensityFunction")
    }
    #expect(shift.testingAttributes.shiftType == .SHIFT_ALL)
    #expect(shift.testingAttributes.noise.key.name == "test:continents")
}

private enum Errors: Error {
    case densityFunctionNotFound(String)
    case densityFunctionWrongType(String)

    case noiseNotFound(String)
}