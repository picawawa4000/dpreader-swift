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
    let dataPack = try DataPack(fromRootPath: packURL, loadingOptions: [])

    guard let noise = dataPack.noiseRegistry.get(RegistryKey(referencing: "test:example")) else {
        throw Errors.noiseNotFound("test:example")
    }
    #expect(noise.testingAttributes.firstOctave == -10)
    #expect(noise.testingAttributes.amplitudes == [1.0, 0.25, 0.0, 0.5])
}

@Test func testLoadingForNoiseSettings() async throws {
    let packURL = URL(filePath: "Tests/Resources/Datapacks/NoiseSettings/noise_settings")
    let dataPack = try DataPack(fromRootPath: packURL, loadingOptions: [.noDensityFunctions, .noNoises])

    guard let noiseSettings = dataPack.noiseSettingsRegistry.get(RegistryKey(referencing: "test:example")) else {
        throw Errors.noiseSettingsNotFound("test:example")
    }

    #expect(noiseSettings.legacyRandomSource == false)
    #expect(noiseSettings.minY == -64)
    #expect(noiseSettings.height == 384)
    #expect(noiseSettings.sizeHorizontal == 4)
    #expect(noiseSettings.sizeVertical == 4)

    let router = noiseSettings.noiseRouter
    #expect(testConstant(densityFunction: router.barrier, expectedValue: 1.0))
    #expect(testConstant(densityFunction: router.continents, expectedValue: 2.0))
    #expect(testConstant(densityFunction: router.depth, expectedValue: 3.0))
    #expect(testConstant(densityFunction: router.erosion, expectedValue: 4.0))
    #expect(testConstant(densityFunction: router.finalDensity, expectedValue: 5.0))
    #expect(testConstant(densityFunction: router.fluidLevelFloodedness, expectedValue: 6.0))
    #expect(testConstant(densityFunction: router.fluidLevelSpread, expectedValue: 7.0))
    #expect(testConstant(densityFunction: router.lava, expectedValue: 8.0))
    #expect(testConstant(densityFunction: router.preliminarySurfaceLevel, expectedValue: 9.0))
    #expect(testConstant(densityFunction: router.weirdness, expectedValue: 10.0))
    #expect(testConstant(densityFunction: router.temperature, expectedValue: 11.0))
    #expect(testConstant(densityFunction: router.humidity, expectedValue: 12.0))
    #expect(testConstant(densityFunction: router.veinGap, expectedValue: 13.0))
    #expect(testConstant(densityFunction: router.veinRidged, expectedValue: 14.0))
    #expect(testConstant(densityFunction: router.veinToggle, expectedValue: 15.0))
}

// Testing loading for:
// - Reference
// - Constant
// - RangeChoice
// - ShiftedNoise
// - Clamp
// - YClampedGradient
// - CacheMarker
// - BlendAlpha / BlendOffset / BlendDensity / Beardifier
// - EndIslands
@Test func testLoadingForMonotypeDensityFunctions() async throws {
    let packURL = URL(filePath: "Tests/Resources/Datapacks/DensityFunctions/monotype")
    let dataPack = try DataPack(fromRootPath: packURL, loadingOptions: [.noNoises])

    guard let continentalness = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:continentalness")) else {
        throw Errors.densityFunctionNotFound("test:continentalness")
    }
    guard let rcContinentalness = continentalness as? RangeChoice else {
        throw Errors.densityFunctionWrongType("test:continentalness -> RangeChoice")
    }
    #expect(rcContinentalness.testingAttributes.minInclusive == 0.0)
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

    // flat_cache -> interpolated -> cache_2d -> cache_all_in_cell -> cache_once
    guard let iCached = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:dummy/cached")) else {
        throw Errors.densityFunctionNotFound("test:cached")
    }
    guard let flatCache = iCached as? CacheMarker else {
        throw Errors.densityFunctionWrongType("test:cached.argument[0] -> CacheMarker")
    }
    #expect(flatCache.type == .flatCache)
    guard let interpolated = flatCache.argument as? CacheMarker else {
        throw Errors.densityFunctionWrongType("test:cached.argument[1] -> CacheMarker")
    }
    #expect(interpolated.type == .interpolated)
    guard let cache2D = interpolated.argument as? CacheMarker else {
        throw Errors.densityFunctionWrongType("test:cached.argument[2] -> CacheMarker")
    }
    #expect(cache2D.type == .cache2D)
    guard let cacheAllInCell = cache2D.argument as? CacheMarker else {
        throw Errors.densityFunctionWrongType("test:cached.argument[3] -> CacheMarker")
    }
    #expect(cacheAllInCell.type == .cacheAllInCell)
    guard let cacheOnce = cacheAllInCell.argument as? CacheMarker else {
        throw Errors.densityFunctionWrongType("test:cached.argument[4] -> CacheMarker")
    }
    #expect(cacheOnce.type == .cacheOnce)

    // blend_density -> add -> blend_alpha + add -> blend_offset + beardifier
    guard let blendDensity = cacheOnce.argument as? BlendDensity else {
        throw Errors.densityFunctionWrongType("test:cached.argument[5] -> BlendDensity")
    }
    guard let add1 = blendDensity.argument as? BinaryDensityFunction else {
        throw Errors.densityFunctionWrongType("test:cached.argument[6] -> BinaryDensityFunction")
    }
    guard add1.testingAttributes.first is BlendAlpha else {
        throw Errors.densityFunctionWrongType("test:cached.argument[7] -> BlendAlpha")
    }
    guard let add2 = add1.testingAttributes.second as? BinaryDensityFunction else {
        throw Errors.densityFunctionWrongType("test:cached.argument[8] -> BinaryDensityFunction")
    }
    guard add2.testingAttributes.first is BlendOffset else {
        throw Errors.densityFunctionWrongType("test:cached.argument[9] -> BlendOffset")
    }
    guard add2.testingAttributes.second is BeardifierMarker else {
        throw Errors.densityFunctionWrongType("test:cached.argument[10] -> BeardifierMarker")
    }

    guard let iEndIslands = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:dummy/end_islands")) else {
        throw Errors.densityFunctionNotFound("test:end_islands")
    }
    guard iEndIslands is EndIslandsDensityFunction else {
        throw Errors.densityFunctionWrongType("test:end_islands -> EndIslandsDensityFunction")
    }
}

// Testing loading for:
// - WeirdScaledSampler
// - Spline
// - FindTopSurface
@Test func testLoadingForMonotypeDensityFunctions2() async throws {
    let packURL = URL(filePath: "Tests/Resources/Datapacks/DensityFunctions/monotype")
    let dataPack = try DataPack(fromRootPath: packURL, loadingOptions: [.noNoises])

    guard let iWeirdScaledSampler = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:dummy/weird_scaled_sampler")) else {
        throw Errors.densityFunctionNotFound("test:weird_scaled_sampler")
    }
    guard let weirdScaledSampler = iWeirdScaledSampler as? WeirdScaledSampler else {
        throw Errors.densityFunctionWrongType("test:weird_scaled_sampler -> WeirdScaledSampler")
    }
    #expect((weirdScaledSampler.testingAttributes.input as! ConstantDensityFunction).testingAttributes.value == 0.5)
    #expect(weirdScaledSampler.testingAttributes.noise.key.name == "test:continents")
    #expect(weirdScaledSampler.testingAttributes.type == .scaleTunnels)

    guard let iSpline = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:dummy/spline")) else {
        throw Errors.densityFunctionNotFound("test:spline")
    }
    guard let splineFunc = iSpline as? SplineDensityFunction else {
        throw Errors.densityFunctionWrongType("test:spline -> SplineDensityFunction")
    }
    let spline = splineFunc.testingAttributes.spline
    guard case .object(let splineObject) = spline else {
        throw Errors.splineNotAnObjectError
    }
    #expect((splineObject.testingAttributes.input as! ConstantDensityFunction).testingAttributes.value == 1.5)
    let locations = splineObject.testingAttributes.locations
    #expect(locations.count == 3)
    let values = splineObject.testingAttributes.values
    #expect(values.count == 3)
    let derivatives = splineObject.testingAttributes.derivatives
    #expect(derivatives.count == 3)
    #expect(locations[0] == 0.0)
    guard case .number(let firstValue) = values[0] else {
        throw Errors.splineValueNotNumberError
    }
    #expect(firstValue == 1.0)
    #expect(derivatives[0] == 1.0)
    #expect(locations[1] == 1.0)
    guard case .number(let secondValue) = values[1] else {
        throw Errors.splineValueNotNumberError
    }
    #expect(secondValue == -1.0)
    #expect(derivatives[1] == 1.0)
    #expect(locations[2] == 2.0)
    guard case .number(let thirdValue) = values[2] else {
        throw Errors.splineValueNotNumberError
    }
    #expect(thirdValue == 2.0)
    #expect(derivatives[2] == -1.0)

    guard let iFindTopSurface = dataPack.densityFunctionRegistry.get(RegistryKey(referencing: "test:dummy/find_top_surface")) else {
        throw Errors.densityFunctionNotFound("test:find_top_surface")
    }
    guard let findTopSurface = iFindTopSurface as? FindTopSurface else {
        throw Errors.densityFunctionWrongType("test:find_top_surface -> FindTopSurface")
    }
    #expect((findTopSurface.testingAttributes.density as! ConstantDensityFunction).testingAttributes.value == 0.5)
    #expect((findTopSurface.testingAttributes.upperBound as! ConstantDensityFunction).testingAttributes.value == 1.0)
    #expect(findTopSurface.testingAttributes.cellHeight == 3)
    #expect(findTopSurface.testingAttributes.lowerBound == 0)
}

// Testing loading for:
// - Unary
@Test func testLoadingForUnaryDensityFunctions() async throws {
    let packURL = URL(filePath: "Tests/Resources/Datapacks/DensityFunctions/unary")
    let dataPack = try DataPack(fromRootPath: packURL, loadingOptions: [])

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
    let dataPack = try DataPack(fromRootPath: packURL, loadingOptions: [])

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
    let dataPack = try DataPack(fromRootPath: packURL, loadingOptions: [])

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

private func checkDouble(_ actualValue: Double, _ roundedExpectedValue: Int) -> Bool {
    let roundedActualValue = Int((actualValue * 1_000_000).rounded(FloatingPointRoundingRule.toNearestOrEven))
    guard roundedExpectedValue == roundedActualValue else {
        print("Error in checkDouble: expected value", roundedExpectedValue, "did not match actual value", actualValue, "(rounded to", roundedActualValue, ")!")
        return false
    }
    return true
}

@Test func testBakingForNoises() async throws {
    let packURL = URL(filePath: "Tests/Resources/Datapacks/Noises/noises")
    let dataPack = try DataPack(fromRootPath: packURL, loadingOptions: [.noDensityFunctions, .noNoiseSettings])
    let worldGenerator = try WorldGenerator(withWorldSeed: 3447, usingDataPacks: [dataPack], usingSettings: RegistryKey(referencing: "test:example"))
    let bakedNoise: DoublePerlinNoise = try worldGenerator.getBakedNoiseOrThrow(at: RegistryKey<DoublePerlinNoise>(referencing: "test:example"))

    #expect(checkDouble(bakedNoise.sample(x: -65, y: 48, z: 36), -329271))
}

@Test func testBakingForDensityFunctions() async throws {
    let packURL = URL(filePath: "Tests/Resources/Datapacks/DensityFunctions/monotype")
    let dataPack = try DataPack(fromRootPath: packURL, loadingOptions: [])
    let worldGenerator = try WorldGenerator(withWorldSeed: 3447, usingDataPacks: [dataPack], usingSettings: RegistryKey(referencing: "test:example"))
    let bakedShiftedNoiseDensityFunction = try worldGenerator.getDensityFunctionOrThrow(at: RegistryKey<DensityFunction>(referencing: "test:dummy/shifted_noise"))
    let bakedContinentalnessDensityFunction = try worldGenerator.getDensityFunctionOrThrow(at: RegistryKey<DensityFunction>(referencing: "test:continentalness"))

    #expect(checkDouble(bakedShiftedNoiseDensityFunction.sample(at: PosInt3D(x: 532, y: -20, z: 2963)), -509139))
    #expect(checkDouble(bakedShiftedNoiseDensityFunction.sample(at: PosInt3D(x: -9238, y: 35, z: -356)), -334149))
    #expect(checkDouble(bakedShiftedNoiseDensityFunction.sample(at: PosInt3D(x: 32535, y: 200, z: 13923)), 170124))

    #expect(bakedContinentalnessDensityFunction.sample(at: PosInt3D(x: 532, y: -20, z: 2963)) == -0.5)
    #expect(bakedContinentalnessDensityFunction.sample(at: PosInt3D(x: -9238, y: 35, z: -356)) == 0.28125)
    #expect(bakedContinentalnessDensityFunction.sample(at: PosInt3D(x: 32535, y: 200, z: 13923)) == 0.5)
}

fileprivate enum Errors: Error {
    case densityFunctionNotFound(String)
    case densityFunctionWrongType(String)

    case noiseNotFound(String)
    case noiseSettingsNotFound(String)

    case splineNotAnObjectError
    case splineValueNotNumberError
}
