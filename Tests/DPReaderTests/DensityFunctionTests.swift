import Foundation
import Testing
@testable import DPReader

fileprivate enum TestingError: Error {
    case jsonNotAnObjectError

    case splineNotAnObjectError
    case splineValueNotNumberError
}

// ----- SERIALIZATION (ENCODING) TESTS -----

@Test func testEncodingForReference() async throws {
    let densityFunction = ReferenceDensityFunction(target: "minecraft:continentalness")
    let encoder = JSONEncoder()
    let data = try encoder.encode(densityFunction)
    #expect(try checkJSON(data, "\"minecraft:continentalness\""))
}

/// Don't use the full notation; only use the shorthand (it's more legible).
@Test func testEncodingForConstant() async throws {
    let densityFunction = ConstantDensityFunction(value: 0.5)
    let encoder = JSONEncoder()
    let data = try encoder.encode(densityFunction)
    #expect(try checkJSON(data, 0.5))
}

@Test func testEncodingForUnaryOperation() async throws {
    let input = ConstantDensityFunction(value: 3.5)
    let abs = UnaryDensityFunction(operand: input, type: .ABS)
    let square = UnaryDensityFunction(operand: input, type: .SQUARE)
    let cube = UnaryDensityFunction(operand: input, type: .CUBE)
    let halfNegative = UnaryDensityFunction(operand: input, type: .HALF_NEGATIVE)
    let quarterNegative = UnaryDensityFunction(operand: input, type: .QUARTER_NEGATIVE)
    let squeeze = UnaryDensityFunction(operand: input, type: .SQUEEZE)
    let invert = UnaryDensityFunction(operand: input, type: .INVERT)
    let encoder = JSONEncoder()
    let absData = try encoder.encode(abs)
    let squareData = try encoder.encode(square)
    let cubeData = try encoder.encode(cube)
    let halfNegativeData = try encoder.encode(halfNegative)
    let quarterNegativeData = try encoder.encode(quarterNegative)
    let squeezeData = try encoder.encode(squeeze)
    let invertData = try encoder.encode(invert)
    #expect(try checkJSON(absData, [
        "type": "minecraft:abs",
        "argument": 3.5
    ]))
    #expect(try checkJSON(squareData, [
        "type": "minecraft:square",
        "argument": 3.5
    ]))
    #expect(try checkJSON(cubeData, [
        "type": "minecraft:cube",
        "argument": 3.5
    ]))
    #expect(try checkJSON(halfNegativeData, [
        "type": "minecraft:half_negative",
        "argument": 3.5
    ]))
    #expect(try checkJSON(quarterNegativeData, [
        "type": "minecraft:quarter_negative",
        "argument": 3.5
    ]))
    #expect(try checkJSON(squeezeData, [
        "type": "minecraft:squeeze",
        "argument": 3.5
    ]))
    #expect(try checkJSON(invertData, [
        "type": "minecraft:invert",
        "argument": 3.5
    ]))
}

@Test func testEncodingForBinaryOperation() async throws {
    let a = ConstantDensityFunction(value: 1.5)
    let b = ConstantDensityFunction(value: 2.0)
    let add = BinaryDensityFunction(firstOperand: a, secondOperand: b, type: .ADD)
    let multiply = BinaryDensityFunction(firstOperand: a, secondOperand: b, type: .MULTIPLY)
    let maximum = BinaryDensityFunction(firstOperand: a, secondOperand: b, type: .MAXIMUM)
    let minimum = BinaryDensityFunction(firstOperand: a, secondOperand: b, type: .MINIMUM)
    let encoder = JSONEncoder()
    let addData = try encoder.encode(add)
    let mulData = try encoder.encode(multiply)
    let maxData = try encoder.encode(maximum)
    let minData = try encoder.encode(minimum)
    #expect(try checkJSON(addData, [
        "type": "minecraft:add",
        "argument1": 1.5,
        "argument2": 2.0
    ]))
    #expect(try checkJSON(mulData, [
        "type": "minecraft:mul",
        "argument1": 1.5,
        "argument2": 2.0
    ]))
    #expect(try checkJSON(maxData, [
        "type": "minecraft:max",
        "argument1": 1.5,
        "argument2": 2.0
    ]))
    #expect(try checkJSON(minData, [
        "type": "minecraft:min",
        "argument1": 1.5,
        "argument2": 2.0
    ]))
}

@Test func testEncodingForClamp() async throws {
    let input = ConstantDensityFunction(value: 0.7)
    let clamp = ClampDensityFunction(input: input, lowerBound: -1.0, upperBound: 1.0)
    let encoder = JSONEncoder()
    let data = try encoder.encode(clamp)
    #expect(try checkJSON(data, [
        "type": "minecraft:clamp",
        "input": 0.7,
        "min": -1.0,
        "max": 1.0
    ]))
}

@Test func testEncodingForYClampedGradient() async throws {
    let grad = YClampedGradient(fromY: 0, toY: 64, fromValue: -1.0, toValue: 1.0)
    let encoder = JSONEncoder()
    let data = try encoder.encode(grad)
    #expect(try checkJSON(data, [
        "type": "minecraft:y_clamped_gradient",
        "from_y": 0,
        "to_y": 64,
        "from_value": -1.0,
        "to_value": 1.0
    ]))
}

@Test func testEncodingForRangeChoice() async throws {
    let input = ConstantDensityFunction(value: 0.5)
    let inRange = ConstantDensityFunction(value: 10.0)
    let outRange = ConstantDensityFunction(value: -10.0)
    let rangeChoice = RangeChoice(inputChoice: input, minInclusive: 0.0, maxExclusive: 1.0, whenInRange: inRange, whenOutOfRange: outRange)
    let encoder = JSONEncoder()
    let data = try encoder.encode(rangeChoice)
    #expect(try checkJSON(data, [
        "type": "minecraft:range_choice",
        "min_inclusive": 0.0,
        "max_exclusive": 1.0,
        "input": 0.5,
        "when_in_range": 10.0,
        "when_out_of_range": -10.0
    ]))
}

@Test func testEncodingForShift() async throws {
    let shift = ShiftDensityFunction(noiseKey: "minecraft:some_noise", shiftType: .SHIFT_ALL)
    let shiftA = ShiftDensityFunction(noiseKey: "minecraft:noise_a", shiftType: .SHIFT_XZ)
    let shiftB = ShiftDensityFunction(noiseKey: "minecraft:noise_b", shiftType: .SHIFT_ZX)
    let encoder = JSONEncoder()
    let data = try encoder.encode(shift)
    let dataA = try encoder.encode(shiftA)
    let dataB = try encoder.encode(shiftB)
    #expect(try checkJSON(data, [
        "type": "minecraft:shift",
        "argument": "minecraft:some_noise"
    ]))
    #expect(try checkJSON(dataA, [
        "type": "minecraft:shift_a",
        "argument": "minecraft:noise_a"
    ]))
    #expect(try checkJSON(dataB, [
        "type": "minecraft:shift_b",
        "argument": "minecraft:noise_b"
    ]))
}

@Test func testEncodingForNoise() async throws {
    let noise = NoiseDensityFunction(noiseKey: "minecraft:noise", scaleXZ: 0.25, scaleY: 0.5)
    let encoder = JSONEncoder()
    let data = try encoder.encode(noise)
    #expect(try checkJSON(data, [
        "type": "minecraft:noise",
        "xz_scale": 0.25,
        "y_scale": 0.5,
        "noise": "minecraft:noise"
    ]))
}

@Test func testEncodingForShiftedNoise() async throws {
    let sx = ConstantDensityFunction(value: 1.0)
    let sy = ConstantDensityFunction(value: 2.0)
    let sz = ConstantDensityFunction(value: 3.0)
    let shifted = ShiftedNoise(noiseKey: "minecraft:noise", shiftX: sx, shiftY: sy, shiftZ: sz, scaleXZ: 0.25, scaleY: 0.5)
    let encoder = JSONEncoder()
    let data = try encoder.encode(shifted)
    print(String(data: data, encoding: .utf8)!)
    #expect(try checkJSON(data, [
        "type": "minecraft:shifted_noise",
        "shift_x": 1.0,
        "shift_y": 2.0,
        "shift_z": 3.0,
        "xz_scale": 0.25,
        "y_scale": 0.5,
        "noise": "minecraft:noise"
    ]))
}

@Test func testEncodingForCaches() async throws {
    let interpolated = CacheMarker(type: .interpolated, wrapping: ConstantDensityFunction(value: 0.5))
    let flatCache = CacheMarker(type: .flatCache, wrapping: ConstantDensityFunction(value: 0.5))
    let cache2D = CacheMarker(type: .cache2D, wrapping: ConstantDensityFunction(value: 0.5))
    let cacheOnce = CacheMarker(type: .cacheOnce, wrapping: ConstantDensityFunction(value: 0.5))
    let cacheAllInCell = CacheMarker(type: .cacheAllInCell, wrapping: ConstantDensityFunction(value: 0.5))

    let encoder = JSONEncoder()
    let interpolatedData = try encoder.encode(interpolated)
    let flatCacheData = try encoder.encode(flatCache)
    let cache2DData = try encoder.encode(cache2D)
    let cacheOnceData = try encoder.encode(cacheOnce)
    let cacheAllInCellData = try encoder.encode(cacheAllInCell)

    #expect(try checkJSON(interpolatedData, [
        "type": "minecraft:interpolated",
        "argument": 0.5
    ]))
    #expect(try checkJSON(flatCacheData, [
        "type": "minecraft:flat_cache",
        "argument": 0.5
    ]))
    #expect(try checkJSON(cache2DData, [
        "type": "minecraft:cache_2d",
        "argument": 0.5
    ]))
    #expect(try checkJSON(cacheOnceData, [
        "type": "minecraft:cache_once",
        "argument": 0.5
    ]))
    #expect(try checkJSON(cacheAllInCellData, [
        "type": "minecraft:cache_all_in_cell",
        "argument": 0.5
    ]))
}

// "Zero states" are the density functions that don't have anything in their JSON format other than their type.
// `blend_density` is also in here just because.
@Test func testEncodingForZeroStates() async throws {
    let blendAlpha = BlendAlpha()
    let blendOffset = BlendOffset()
    let blendDensity = BlendDensity(wrapping: ConstantDensityFunction(value: 2.0))
    let beardifier = BeardifierMarker()
    let endIslands = EndIslandsDensityFunction()

    let encoder = JSONEncoder()
    let blendAlphaData = try encoder.encode(blendAlpha)
    let blendOffsetData = try encoder.encode(blendOffset)
    let blendDensityData = try encoder.encode(blendDensity)
    let beardifierData = try encoder.encode(beardifier)
    let endIslandsData = try encoder.encode(endIslands)

    print(String(data: blendDensityData, encoding: .utf8) ?? "none")
    #expect(try checkJSON(blendAlphaData, ["type": "minecraft:blend_alpha"]))
    #expect(try checkJSON(blendOffsetData, ["type": "minecraft:blend_offset"]))
    #expect(try checkJSON(blendDensityData, [
        "type": "minecraft:blend_density",
        "argument": 2.0
    ]))
    #expect(try checkJSON(beardifierData, ["type": "minecraft:beardifier"]))
    #expect(try checkJSON(endIslandsData, ["type": "minecraft:end_islands"]))
}

@Test func testEncodingForWeirdScaledSampler() async throws {
    let input = ConstantDensityFunction(value: 1.0)
    let samplerScaleTunnels = WeirdScaledSampler(type: .scaleTunnels, withInput: input, withNoiseFromKey: "minecraft:noise")
    let samplerScaleCaves = WeirdScaledSampler(type: .scaleCaves, withInput: input, withNoiseFromKey: "minecraft:noise")
    let encoder = JSONEncoder()
    let dataTunnels = try encoder.encode(samplerScaleTunnels)
    let dataCaves = try encoder.encode(samplerScaleCaves)
    #expect(try checkJSON(dataTunnels, [
        "type": "minecraft:weird_scaled_sampler",
        "rarity_value_mapper": "type_1",
        "input": 1.0,
        "noise": "minecraft:noise"
    ]))
    #expect(try checkJSON(dataCaves, [
        "type": "minecraft:weird_scaled_sampler",
        "rarity_value_mapper": "type_2",
        "input": 1.0,
        "noise": "minecraft:noise"
    ]))
}

fileprivate func createTestSpline(sampledAt value: Double) -> SplineSegment {
    let input = ConstantDensityFunction(value: value)
    let locations: [Float] = [0.0, 1.0, 2.0]
    let values: [SplineSegment] = [
        .number(1.0),
        .number(-1.0),
        .number(2.0)
    ]
    let derivatives: [Float] = [1.0, 1.0, -1.0]
    return .object(SplineObject(withInput: input, locations: locations, values: values, derivatives: derivatives))
}

@Test func testEncodingForSpline() async throws {
    let spline = createTestSpline(sampledAt: 1.5)
    let splineFunc = SplineDensityFunction(withSpline: spline)
    let encoder = JSONEncoder()
    let data = try encoder.encode(splineFunc)
    #expect(try checkJSON(data, [
        "type": "minecraft:spline",
        "spline": [
            "coordinate": 1.5,
            "points": [
                [
                    "location": 0.0,
                    "value": 1.0,
                    "derivative": 1.0
                ],
                [
                    "location": 1.0,
                    "value": -1.0,
                    "derivative": 1.0
                ],
                [
                    "location": 2.0,
                    "value": 2.0,
                    "derivative": -1.0
                ]
            ]
        ]
    ]))
}

@Test func testEncodingForFindTopSurface() async throws {
    let sampledDensityFunction = YClampedGradient(fromY: 0, toY: 256, fromValue: -10.0, toValue: 10.0)
    let upperBoundDensityFunction = ConstantDensityFunction(value: 256.0)
    let findTopSurface = FindTopSurface(density: sampledDensityFunction, upperBound: upperBoundDensityFunction, lowerBound: 0, cellHeight: 8)
    let encoder = JSONEncoder()
    let data = try encoder.encode(findTopSurface)
    print(String(data: data, encoding: .utf8) ?? "nil")
    #expect(try checkJSON(data, [
        "type": "minecraft:find_top_surface",
        "density": [
            "type": "minecraft:y_clamped_gradient",
            "from_y": 0,
            "to_y": 256,
            "from_value": -10.0,
            "to_value": 10.0
        ],
        "upper_bound": 256.0,
        "lower_bound": 0,
        "cell_height": 8
    ]))
}

// ----- DESERIALIZATION (DECODING) TESTS -----

@Test func testDecodingForReference() async throws {
    let data = """
        "minecraft:erosion"
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let densityFunction = try decoder.decode(DensityFunctionInitializer.self, from: data).value
    #expect((densityFunction as! ReferenceDensityFunction).targetKey.name == "minecraft:erosion")
}

@Test func testDecodingForConstant() async throws {
    let shorthandData = """
        0.5
    """.data(using: .utf8)!
    let fullData = """
        {
            "type": "minecraft:constant",
            "value": 0.5
        }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let shorthandDensityFunction = try decoder.decode(DensityFunctionInitializer.self, from: shorthandData).value
    let fullDensityFunction = try decoder.decode(DensityFunctionInitializer.self, from: fullData).value
    #expect((shorthandDensityFunction as! ConstantDensityFunction).testingAttributes.value == 0.5)
    #expect((fullDensityFunction as! ConstantDensityFunction).testingAttributes.value == 0.5)
}

@Test func testDecodingForUnaryOperation() async throws {
    let absData = """
        {"type": "minecraft:abs", "argument": 3.5}
    """.data(using: .utf8)!
    let squareData = """
        {"type": "minecraft:square", "argument": 3.5}
    """.data(using: .utf8)!
    let cubeData = """
        {"type": "minecraft:cube", "argument": 3.5}
    """.data(using: .utf8)!
    let halfNegativeData = """
        {"type": "minecraft:half_negative", "argument": 3.5}
    """.data(using: .utf8)!
    let quarterNegativeData = """
        {"type": "minecraft:quarter_negative", "argument": 3.5}
    """.data(using: .utf8)!
    let squeezeData = """
        {"type": "minecraft:squeeze", "argument": 3.5}
    """.data(using: .utf8)!
    let invertData = """
        {"type": "minecraft:invert", "argument": 3.5}
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let absDensity = try decoder.decode(DensityFunctionInitializer.self, from: absData).value
    let squareDensity = try decoder.decode(DensityFunctionInitializer.self, from: squareData).value
    let cubeDensity = try decoder.decode(DensityFunctionInitializer.self, from: cubeData).value
    let halfNegativeDensity = try decoder.decode(DensityFunctionInitializer.self, from: halfNegativeData).value
    let quarterNegativeDensity = try decoder.decode(DensityFunctionInitializer.self, from: quarterNegativeData).value
    let squeezeDensity = try decoder.decode(DensityFunctionInitializer.self, from: squeezeData).value
    let invertDensity = try decoder.decode(DensityFunctionInitializer.self, from: invertData).value

    let absUnary = absDensity as! UnaryDensityFunction
    let squareUnary = squareDensity as! UnaryDensityFunction
    let cubeUnary = cubeDensity as! UnaryDensityFunction
    let halfNegativeUnary = halfNegativeDensity as! UnaryDensityFunction
    let quarterNegativeUnary = quarterNegativeDensity as! UnaryDensityFunction
    let squeezeUnary = squeezeDensity as! UnaryDensityFunction
    let invertUnary = invertDensity as! UnaryDensityFunction

    #expect(absUnary.testingAttributes.operation == UnaryDensityFunction.OperationType.ABS)
    #expect(squareUnary.testingAttributes.operation == UnaryDensityFunction.OperationType.SQUARE)
    #expect(cubeUnary.testingAttributes.operation == UnaryDensityFunction.OperationType.CUBE)
    #expect(halfNegativeUnary.testingAttributes.operation == UnaryDensityFunction.OperationType.HALF_NEGATIVE)
    #expect(quarterNegativeUnary.testingAttributes.operation == UnaryDensityFunction.OperationType.QUARTER_NEGATIVE)
    #expect(squeezeUnary.testingAttributes.operation == UnaryDensityFunction.OperationType.SQUEEZE)
    #expect(invertUnary.testingAttributes.operation == UnaryDensityFunction.OperationType.INVERT)

    #expect((absUnary.testingAttributes.operand as! ConstantDensityFunction).testingAttributes.value == 3.5)
    #expect((squareUnary.testingAttributes.operand as! ConstantDensityFunction).testingAttributes.value == 3.5)
    #expect((cubeUnary.testingAttributes.operand as! ConstantDensityFunction).testingAttributes.value == 3.5)
    #expect((halfNegativeUnary.testingAttributes.operand as! ConstantDensityFunction).testingAttributes.value == 3.5)
    #expect((quarterNegativeUnary.testingAttributes.operand as! ConstantDensityFunction).testingAttributes.value == 3.5)
    #expect((squeezeUnary.testingAttributes.operand as! ConstantDensityFunction).testingAttributes.value == 3.5)
    #expect((invertUnary.testingAttributes.operand as! ConstantDensityFunction).testingAttributes.value == 3.5)
}

@Test func testDecodingForBinaryOperation() async throws {
    // Only test the "add" variant here because the decoder selects variants based on the "type" key and the OperationType raw values must match.
    let data = """
    {
        "type": "minecraft:add",
        "argument1": 1.5,
        "argument2": 2.0
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let densityFunction = try decoder.decode(DensityFunctionInitializer.self, from: data).value
    let binary = densityFunction as! BinaryDensityFunction
    #expect(binary.testingAttributes.operation == BinaryDensityFunction.OperationType.ADD)
    #expect((binary.testingAttributes.first as! ConstantDensityFunction).testingAttributes.value == 1.5)
    #expect((binary.testingAttributes.second as! ConstantDensityFunction).testingAttributes.value == 2.0)
}

@Test func testDecodingForClamp() async throws {
    let data = """
    {
        "type": "minecraft:clamp",
        "input": 3.0,
        "min": -5.0,
        "max": 5.0
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let df = try decoder.decode(DensityFunctionInitializer.self, from: data).value
    let clamp = df as! ClampDensityFunction
    #expect((clamp.testingAttributes.input as! ConstantDensityFunction).testingAttributes.value == 3.0)
    #expect(clamp.testingAttributes.lowerBound == -5.0)
    #expect(clamp.testingAttributes.upperBound == 5.0)
}

@Test func testDecodingForYClampedGradient() async throws {
    let data = """
    {
        "type": "minecraft:y_clamped_gradient",
        "from_y": -10,
        "to_y": 20,
        "from_value": -0.5,
        "to_value": 0.75
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let df = try decoder.decode(DensityFunctionInitializer.self, from: data).value
    let grad = df as! YClampedGradient
    #expect(grad.testingAttributes.fromY == -10)
    #expect(grad.testingAttributes.toY == 20)
    #expect(grad.testingAttributes.fromValue == -0.5)
    #expect(grad.testingAttributes.toValue == 0.75)
}

@Test func testDecodingForRangeChoice() async throws {
    let data = """
    {
        "type": "minecraft:range_choice",
        "min_inclusive": 0.0,
        "max_exclusive": 1.0,
        "input": 0.5,
        "when_in_range": 2.0,
        "when_out_of_range": 3.0
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let df = try decoder.decode(DensityFunctionInitializer.self, from: data).value
    let rc = df as! RangeChoice
    #expect((rc.testingAttributes.inputChoice as! ConstantDensityFunction).testingAttributes.value == 0.5)
    #expect(rc.testingAttributes.minInclusive == 0.0)
    #expect(rc.testingAttributes.maxExclusive == 1.0)
    #expect((rc.testingAttributes.whenInRange as! ConstantDensityFunction).testingAttributes.value == 2.0)
    #expect((rc.testingAttributes.whenOutOfRange as! ConstantDensityFunction).testingAttributes.value == 3.0)
}

@Test func testDecodingForShift() async throws {
    let data = """
    {
        "type": "minecraft:shift",
        "argument": "minecraft:example_noise"
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let df = try decoder.decode(DensityFunctionInitializer.self, from: data).value
    let shift = df as! ShiftDensityFunction
    #expect(shift.testingAttributes.shiftType == ShiftDensityFunction.ShiftType.SHIFT_ALL)
    #expect(shift.testingAttributes.noise.key.name == "minecraft:example_noise")
}

@Test func testDecodingForNoise() async throws {
    let data = """
    {
        "type": "minecraft:noise",
        "xz_scale": 0.25,
        "y_scale": 0.5,
        "noise": "minecraft:noise_example"
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let df = try decoder.decode(DensityFunctionInitializer.self, from: data).value
    let noise = df as! NoiseDensityFunction
    #expect(noise.testingAttributes.scaleXZ == 0.25)
    #expect(noise.testingAttributes.scaleY == 0.5)
    #expect(noise.testingAttributes.noise.key.name == "minecraft:noise_example")
}

@Test func testDecodingForShiftedNoise() async throws {
    let data = """
    {
        "type": "minecraft:shifted_noise",
        "shift_x": 1.0,
        "shift_y": 2.0,
        "shift_z": 3.0,
        "xz_scale": 0.25,
        "y_scale": 0.5,
        "noise": "minecraft:shifted_noise_example"
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let df = try decoder.decode(DensityFunctionInitializer.self, from: data).value
    let sn = df as! ShiftedNoise
    #expect((sn.testingAttributes.shiftX as! ConstantDensityFunction).testingAttributes.value == 1.0)
    #expect((sn.testingAttributes.shiftY as! ConstantDensityFunction).testingAttributes.value == 2.0)
    #expect((sn.testingAttributes.shiftZ as! ConstantDensityFunction).testingAttributes.value == 3.0)
    #expect(sn.testingAttributes.scaleXZ == 0.25)
    #expect(sn.testingAttributes.scaleY == 0.5)
    // noise is an UnbakedNoise created with the registry key string
    #expect(sn.testingAttributes.noise.key.name == "minecraft:shifted_noise_example")
}

@Test func testDecodingForCaches() async throws {
    let interpolatedData = """
    {
        "type": "minecraft:interpolated",
        "argument": 0.5
    }
    """.data(using: .utf8)!
    let flatCacheData = """
    {
        "type": "minecraft:flat_cache",
        "argument": 0.5
    }
    """.data(using: .utf8)!
    let cache2DData = """
    {
        "type": "minecraft:cache_2d",
        "argument": 0.5
    }
    """.data(using: .utf8)!
    let cacheOnceData = """
    {
        "type": "minecraft:cache_once",
        "argument": 0.5
    }
    """.data(using: .utf8)!
    let cacheAllInCellData = """
    {
        "type": "minecraft:cache_all_in_cell",
        "argument": 0.5
    }
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    let interpolated = try decoder.decode(DensityFunctionInitializer.self, from: interpolatedData).value
    let flatCache = try decoder.decode(DensityFunctionInitializer.self, from: flatCacheData).value
    let cache2D = try decoder.decode(DensityFunctionInitializer.self, from: cache2DData).value
    let cacheOnce = try decoder.decode(DensityFunctionInitializer.self, from: cacheOnceData).value
    let cacheAllInCell = try decoder.decode(DensityFunctionInitializer.self, from: cacheAllInCellData).value

    #expect(interpolated is CacheMarker)
    #expect(flatCache is CacheMarker)
    #expect(cache2D is CacheMarker)
    #expect(cacheOnce is CacheMarker)
    #expect(cacheAllInCell is CacheMarker)

    #expect((interpolated as! CacheMarker).type == .interpolated)
    #expect((flatCache as! CacheMarker).type == .flatCache)
    #expect((cache2D as! CacheMarker).type == .cache2D)
    #expect((cacheOnce as! CacheMarker).type == .cacheOnce)
    #expect((cacheAllInCell as! CacheMarker).type == .cacheAllInCell)

    #expect((interpolated as! CacheMarker).argument is ConstantDensityFunction)
    #expect(((interpolated as! CacheMarker).argument as! ConstantDensityFunction).testingAttributes.value == 0.5)
}

// "Zero states" are the density functions that don't have anything in their JSON format other than their type.
// `blend_density` is also in here just because.
@Test func testDecodingForZeroStates() async throws {
    let blendAlphaData = """
    {"type": "minecraft:blend_alpha"}
    """.data(using: .utf8)!
    let blendOffsetData = """
    {"type": "minecraft:blend_offset"}
    """.data(using: .utf8)!
    let blendDensityData = """
    {
        "type": "minecraft:blend_density",
        "argument": 2.0
    }
    """.data(using: .utf8)!
    let beardifierData = """
    {"type": "minecraft:beardifier"}
    """.data(using: .utf8)!
    let endIslandsData = """
    {"type": "minecraft:end_islands"}
    """.data(using: .utf8)!

    let decoder = JSONDecoder()
    let blendAlpha = try decoder.decode(DensityFunctionInitializer.self, from: blendAlphaData).value
    let blendOffset = try decoder.decode(DensityFunctionInitializer.self, from: blendOffsetData).value
    let blendDensity = try decoder.decode(DensityFunctionInitializer.self, from: blendDensityData).value
    let beardifier = try decoder.decode(DensityFunctionInitializer.self, from: beardifierData).value
    let endIslands = try decoder.decode(DensityFunctionInitializer.self, from: endIslandsData).value

    #expect(blendAlpha is BlendAlpha)
    #expect(blendOffset is BlendOffset)
    #expect(blendDensity is BlendDensity)
    #expect(beardifier is BeardifierMarker)
    #expect(endIslands is EndIslandsDensityFunction)

    // Only type-checking here because I'm lazy.
    #expect((blendDensity as! BlendDensity).argument is ConstantDensityFunction)
}

@Test func testDecodingForWeirdScaledSampler() async throws {
    let type1Data = """
    {
        "type": "minecraft:weird_scaled_sampler",
        "rarity_value_mapper": "type_1",
        "input": 1.0,
        "noise": "minecraft:noise"
    }
    """.data(using: .utf8)!
    let type2Data = """
    {
        "type": "minecraft:weird_scaled_sampler",
        "rarity_value_mapper": "type_2",
        "input": 1.0,
        "noise": "minecraft:noise"
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let samplerType1 = try decoder.decode(DensityFunctionInitializer.self, from: type1Data).value
    let samplerType2 = try decoder.decode(DensityFunctionInitializer.self, from: type2Data).value
    let ws1 = samplerType1 as! WeirdScaledSampler
    let ws2 = samplerType2 as! WeirdScaledSampler
    #expect(ws1.testingAttributes.type == .scaleTunnels)
    #expect(ws2.testingAttributes.type == .scaleCaves)
    #expect((ws1.testingAttributes.input as! ConstantDensityFunction).testingAttributes.value == 1.0)
    #expect((ws2.testingAttributes.input as! ConstantDensityFunction).testingAttributes.value == 1.0)
    #expect(ws1.testingAttributes.noise.key.name == "minecraft:noise")
    #expect(ws2.testingAttributes.noise.key.name == "minecraft:noise")
}

@Test func testDecodingForSpline() async throws {
    let splineData = """
    {
        "type": "minecraft:spline",
        "spline": {
            "coordinate": 1.5,
            "points": [
                {
                    "location": 0.0,
                    "value": 1.0,
                    "derivative": 1.0
                },
                {
                    "location": 1.0,
                    "value": -1.0,
                    "derivative": 1.0
                },
                {
                    "location": 2.0,
                    "value": 2.0,
                    "derivative": -1.0
                }
            ]
        }
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let df = try decoder.decode(DensityFunctionInitializer.self, from: splineData).value
    let splineFunc = df as! SplineDensityFunction
    let spline = splineFunc.testingAttributes.spline
    guard case .object(let splineObject) = spline else {
        throw TestingError.splineNotAnObjectError
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
        throw TestingError.splineValueNotNumberError
    }
    #expect(firstValue == 1.0)
    #expect(derivatives[0] == 1.0)
    #expect(locations[1] == 1.0)
    guard case .number(let secondValue) = values[1] else {
        throw TestingError.splineValueNotNumberError
    }
    #expect(secondValue == -1.0)
    #expect(derivatives[1] == 1.0)
    #expect(locations[2] == 2.0)
    guard case .number(let thirdValue) = values[2] else {
        throw TestingError.splineValueNotNumberError
    }
    #expect(thirdValue == 2.0)
    #expect(derivatives[2] == -1.0)
}

@Test func testDecodingForFindTopSurface() async throws {
    let data = """
    {
        "type": "minecraft:find_top_surface",
        "density": {
            "type": "minecraft:y_clamped_gradient",
            "from_y": 0,
            "to_y": 256,
            "from_value": -10.0,
            "to_value": 10.0
        },
        "upper_bound": 256.0,
        "lower_bound": 0,
        "cell_height": 8
    }
    """.data(using: .utf8)!
    let decoder = JSONDecoder()
    let df = try decoder.decode(DensityFunctionInitializer.self, from: data).value
    let fts = df as! FindTopSurface
    let density = fts.testingAttributes.density as! YClampedGradient
    #expect(density.testingAttributes.fromY == 0)
    #expect(density.testingAttributes.toY == 256)
    #expect(density.testingAttributes.fromValue == -10.0)
    #expect(density.testingAttributes.toValue == 10.0)
    let upperBound = fts.testingAttributes.upperBound as! ConstantDensityFunction
    #expect(upperBound.testingAttributes.value == 256.0)
    #expect(fts.testingAttributes.lowerBound == 0)
    #expect(fts.testingAttributes.cellHeight == 8)
}

// ----- OUTPUT TESTS -----

private func checkDouble(_ actualValue: Double, _ roundedExpectedValue: Int) -> Bool {
    let roundedActualValue = Int((actualValue * 1_000_000).rounded(FloatingPointRoundingRule.toNearestOrEven))
    guard roundedExpectedValue == roundedActualValue else {
        print("Error in checkDouble: expected value", roundedExpectedValue, "did not match actual value", actualValue, "(rounded to", roundedActualValue, ")!")
        return false
    }
    return true
}

@Test func testOutputForReference() async throws {
    let referencedDensityFunction = ConstantDensityFunction(value: 20.0)
    let registry = Registry<DensityFunction>()
    let registryKey = RegistryKey<DensityFunction>(referencing: "example:test")
    registry.register(referencedDensityFunction, forKey: registryKey)
    let referenceDensityFunction = ReferenceDensityFunction(targetKey: registryKey)
    referenceDensityFunction.setDensityFunctionRegistry(registry)
    #expect(referenceDensityFunction.sample(at: PosInt3D(x: 0, y: 0, z: 0)) == 20.0)
}

@Test func testOutputForConstant() async throws {
    let densityFunction1 = ConstantDensityFunction(value: 0.5)
    let densityFunction2 = ConstantDensityFunction(value: -3.25)
    let densityFunction3 = ConstantDensityFunction(value: 10000.0)
    #expect(densityFunction1.sample(at: PosInt3D(x: -5, y: 20, z: 42)) == 0.5)
    #expect(densityFunction2.sample(at: PosInt3D(x: 0, y: 0, z: 0)) == -3.25)
    #expect(densityFunction3.sample(at: PosInt3D(x: 20, y: -4, z: 83)) == 10000.0)
}

// Copy of `squeeze` from `UnaryDensityFunction`.
private func squeeze(_ x: Double) -> Double {
    let e = clamp(value: x, lowerBound: -1.0, upperBound: 1.0)
    return e / 2.0 - e * e * e / 24.0
}

@Test func testOutputForUnaryOperation() async throws {
    let baseDensityFunction = ConstantDensityFunction(value: -0.75)

    let absDensityFunction = UnaryDensityFunction(operand: baseDensityFunction, type: .ABS)
    let squareDensityFunction = UnaryDensityFunction(operand: baseDensityFunction, type: .SQUARE)
    let cubeDensityFunction = UnaryDensityFunction(operand: baseDensityFunction, type: .CUBE)
    let halfNegativeDensityFunction = UnaryDensityFunction(operand: baseDensityFunction, type: .HALF_NEGATIVE)
    let quarterNegativeDensityFunction = UnaryDensityFunction(operand: baseDensityFunction, type: .QUARTER_NEGATIVE)
    let squeezeDensityFunction = UnaryDensityFunction(operand: baseDensityFunction, type: .SQUEEZE)
    let invertDensityFunction = UnaryDensityFunction(operand: baseDensityFunction, type: .INVERT)

    let samplingPos = PosInt3D(x: 0, y: 0, z: 0)
    #expect(absDensityFunction.sample(at: samplingPos) == 0.75)
    #expect(squareDensityFunction.sample(at: samplingPos) == 0.5625)
    #expect(cubeDensityFunction.sample(at: samplingPos) == -0.421875)
    #expect(halfNegativeDensityFunction.sample(at: samplingPos) == -0.375)
    #expect(quarterNegativeDensityFunction.sample(at: samplingPos) == -0.1875)
    #expect(squeezeDensityFunction.sample(at: samplingPos) == squeeze(-0.75))
    // Have to use `checkDouble` because `-1.333333` isn't exact.
    #expect(checkDouble(invertDensityFunction.sample(at: samplingPos), -1333333))
}

@Test func testOutputForBinaryOperation() async throws {
    let firstDensityFunction = ConstantDensityFunction(value: -0.5)
    let secondDensityFunction = ConstantDensityFunction(value: 0.75)
    
    let addDensityFunction = BinaryDensityFunction(firstOperand: firstDensityFunction, secondOperand: secondDensityFunction, type: .ADD)
    let multiplyDensityFunction = BinaryDensityFunction(firstOperand: firstDensityFunction, secondOperand: secondDensityFunction, type: .MULTIPLY)
    let maximumDensityFunction = BinaryDensityFunction(firstOperand: firstDensityFunction, secondOperand: secondDensityFunction, type: .MAXIMUM)
    let minimumDensityFunction = BinaryDensityFunction(firstOperand: firstDensityFunction, secondOperand: secondDensityFunction, type: .MINIMUM)

    let samplingPos = PosInt3D(x: 0, y: 0, z: 0)
    #expect(addDensityFunction.sample(at: samplingPos) == 0.25)
    #expect(multiplyDensityFunction.sample(at: samplingPos) == -0.375)
    #expect(maximumDensityFunction.sample(at: samplingPos) == 0.75)
    #expect(minimumDensityFunction.sample(at: samplingPos) == -0.5)
}

@Test func testOutputForClamp() async throws {
    let densityFunction1 = ClampDensityFunction(input: ConstantDensityFunction(value: 0.5), lowerBound: 0.0, upperBound: 1.0)
    let densityFunction2 = ClampDensityFunction(input: ConstantDensityFunction(value: -0.5), lowerBound: 0.0, upperBound: 1.0)
    let densityFunction3 = ClampDensityFunction(input: ConstantDensityFunction(value: 1.5), lowerBound: 0.0, upperBound: 1.0)

    let samplingPos = PosInt3D(x: 0, y: 0, z: 0)
    #expect(densityFunction1.sample(at: samplingPos) == 0.5)
    #expect(densityFunction2.sample(at: samplingPos) == 0.0)
    #expect(densityFunction3.sample(at: samplingPos) == 1.0)
}

@Test func testOutputForYClampedGradient() async throws {
    let gradient = YClampedGradient(fromY: 0, toY: 256, fromValue: -256.0, toValue: 256.0)
    #expect(gradient.sample(at: PosInt3D(x: 0, y: 128, z: 0)) == 0.0)
    #expect(gradient.sample(at: PosInt3D(x: 0, y: 512, z: 0)) == 256.0)
    #expect(gradient.sample(at: PosInt3D(x: 0, y: -256, z: 0)) == -256.0)
}

@Test func testOutputForRangeChoice() async throws {
    let inRange = ConstantDensityFunction(value: 10.0)
    let outRange = ConstantDensityFunction(value: -10.0)

    let inputInside = ConstantDensityFunction(value: 0.5)
    let rcInside = RangeChoice(inputChoice: inputInside, minInclusive: 0.0, maxExclusive: 1.0, whenInRange: inRange, whenOutOfRange: outRange)
    #expect(rcInside.sample(at: PosInt3D(x: 0, y: 0, z: 0)) == 10.0)

    let inputEdge = ConstantDensityFunction(value: 1.0)
    let rcEdge = RangeChoice(inputChoice: inputEdge, minInclusive: 0.0, maxExclusive: 1.0, whenInRange: inRange, whenOutOfRange: outRange)
    #expect(rcEdge.sample(at: PosInt3D(x: 0, y: 0, z: 0)) == -10.0)

    let inputOutside = ConstantDensityFunction(value: -5.0)
    let rcOutside = RangeChoice(inputChoice: inputOutside, minInclusive: 0.0, maxExclusive: 1.0, whenInRange: inRange, whenOutOfRange: outRange)
    #expect(rcOutside.sample(at: PosInt3D(x: 0, y: 0, z: 0)) == -10.0)
}

// Helper deterministic noise for Shift / ShiftedNoise tests.
fileprivate struct TestNoise: DensityFunctionNoise {
    let key: RegistryKey<NoiseDefinition>
    init(name: String = "test:dummy") {
        self.key = RegistryKey<NoiseDefinition>(referencing: name)
    }
    func sample(x: Double, y: Double, z: Double) -> Double {
        // Simple additive sampler so expected values are easy to compute.
        return x + y + z
    }
}

@Test func testOutputForShift() async throws {
    let noise = TestNoise()
    let shiftAll = ShiftDensityFunction(noise: noise, shiftType: .SHIFT_ALL)
    let shiftXZ = ShiftDensityFunction(noise: noise, shiftType: .SHIFT_XZ)
    let shiftZX = ShiftDensityFunction(noise: noise, shiftType: .SHIFT_ZX)

    let pos = PosInt3D(x: 1, y: 2, z: 3)
    // With TestNoise.sample(x,y,z) = x + y + z and ShiftDensityFunction logic:
    // SHIFT_ALL: 4 * noise.sample(pos*0.25) = pos.x + pos.y + pos.z
    #expect(shiftAll.sample(at: pos) == 6.0)
    // SHIFT_XZ: 4 * noise.sample(x*0.25, 0, z*0.25) = pos.x + pos.z
    #expect(shiftXZ.sample(at: pos) == 4.0)
    // SHIFT_ZX: 4 * noise.sample(z*0.25, x*0.25, 0) = pos.z + pos.x
    #expect(shiftZX.sample(at: pos) == 4.0)
}

@Test func testOutputForNoise() async throws {
    let noise = TestNoise()
    let noiseDF = NoiseDensityFunction(noise: noise, scaleXZ: 0.75, scaleY: 2.5)

    // x' = pos.x * 0.75 = 10 * 0.75 = 7.5
    // y' = pos.y * 2.5 = 20 * 2.5 = 50
    // z' = pos.z * 0.75 = 30 * 0.75 = 22.5
    // x' + y' + z' = 80
    let pos = PosInt3D(x: 10, y: 20, z: 30)
    #expect(noiseDF.sample(at: pos) == 80)
}

@Test func testOutputForShiftedNoise() async throws {
    let noise = TestNoise()
    let sx = ConstantDensityFunction(value: 1.0)
    let sy = ConstantDensityFunction(value: 2.0)
    let sz = ConstantDensityFunction(value: 3.0)
    let shifted = ShiftedNoise(noise: noise, shiftX: sx, shiftY: sy, shiftZ: sz, scaleXZ: 0.25, scaleY: 0.5)

    // Choose a sampling position and compute expected by hand:
    // x' = pos.x * 0.25 + shiftX = 10 * 0.25 + 1 = 3.5
    // y' = pos.y * 0.5  + shiftY = 20 * 0.5 + 2 = 12.0
    // z' = pos.z * 0.25 + shiftZ = 30 * 0.25 + 3 = 10.5
    // noise.sample = x' + y' + z' = 3.5 + 12.0 + 10.5 = 26.0
    let pos = PosInt3D(x: 10, y: 20, z: 30)
    #expect(shifted.sample(at: pos) == 26.0)
}

// We assume that cache markers & blending functions work because they're not complicated.

fileprivate struct SimplexBaker: DensityFunctionBaker {
    func bake(interpolatedNoise: InterpolatedNoise) throws -> InterpolatedNoise {
        throw Errors.stubCalled
    }

    func bake(noise: any DensityFunctionNoise) throws -> BakedNoise {
        throw Errors.stubCalled
    }

    func bake(referenceDensityFunction: ReferenceDensityFunction) throws -> any DensityFunction {
        throw Errors.stubCalled
    }

    func bake(cacheMarker: CacheMarker) throws -> any DensityFunction {
        throw Errors.stubCalled
    }

    func bake(beardifier: BeardifierMarker) throws -> any DensityFunction {
        throw Errors.stubCalled
    }

    func bake(simplexNoise: DensityFunctionSimplexNoise) throws -> DensityFunctionSimplexNoise {
        var random: any Random = CheckedRandom(seed: 3259802309)
        return DensityFunctionSimplexNoise(withRandom: &random)
    }

    private enum Errors: Error {
        case stubCalled
    }
}

@Test func testOutputForEndIslands() async throws {
    let baker = SimplexBaker()
    let endIslands = try EndIslandsDensityFunction().bake(withBaker: baker)
    // Calculated from xpple's fork of Cubiomes.
    #expect(checkDouble(endIslands.sample(at: PosInt3D(x: 1523, y: 0, z: -231)), 122129))
    #expect(checkDouble(endIslands.sample(at: PosInt3D(x: -53210, y: 0, z: 5302781)), -508434))
    #expect(checkDouble(endIslands.sample(at: PosInt3D(x: 0, y: 0, z: 0)), 562500))
    #expect(checkDouble(endIslands.sample(at: PosInt3D(x: 532810, y: 0, z: 53892)), -222000))
    #expect(checkDouble(endIslands.sample(at: PosInt3D(x: -39258, y: 0, z: -5320183)), -782084))
    #expect(checkDouble(endIslands.sample(at: PosInt3D(x: 25382932, y: 0, z: -23512349)), 3533))
    #expect(checkDouble(endIslands.sample(at: PosInt3D(x: -5329015, y: 0, z: 123592)), -451483))
    #expect(checkDouble(endIslands.sample(at: PosInt3D(x: 5335825, y: 0, z: 12395823)), -23438))
    #expect(checkDouble(endIslands.sample(at: PosInt3D(x: -329591853, y: 0, z: -2052560996)), 562500))
}

fileprivate struct MultiplicativeTestNoise: DensityFunctionNoise {
    let key: RegistryKey<NoiseDefinition>
    init(name: String = "test:dummy") {
        self.key = RegistryKey<NoiseDefinition>(referencing: name)
    }
    func sample(x: Double, y: Double, z: Double) -> Double {
        return x * y * z
    }
}

@Test func testOutputForWeirdScaledSampler() async throws {
    // We use multiplication instead of addition here so that the effects of scaling are visible.
    let noise = MultiplicativeTestNoise()

    let firstTunnelBranchConstant = ConstantDensityFunction(value: -1.0) // 0.75
    let secondTunnelBranchConstant = ConstantDensityFunction(value: -0.25) // 1.0
    let thirdTunnelBranchConstant = ConstantDensityFunction(value: 0.25) // 1.5
    let fourthTunnelBranchConstant = ConstantDensityFunction(value: 1.0) // 2.0
    
    let firstCaveBranchConstant = ConstantDensityFunction(value: -1.0) // 0.5
    let secondCaveBranchConstant = ConstantDensityFunction(value: -0.6) // 0.75
    let thirdCaveBranchConstant = ConstantDensityFunction(value: 0.0) // 1.0
    let fourthCaveBranchConstant = ConstantDensityFunction(value: 0.6) // 2.0
    let fifthCaveBranchConstant = ConstantDensityFunction(value: 1.0) // 3.0

    let firstTunnelBranchSampler = WeirdScaledSampler(type: .scaleTunnels, withInput: firstTunnelBranchConstant, withNoise: noise)
    let secondTunnelBranchSampler = WeirdScaledSampler(type: .scaleTunnels, withInput: secondTunnelBranchConstant, withNoise: noise)
    let thirdTunnelBranchSampler = WeirdScaledSampler(type: .scaleTunnels, withInput: thirdTunnelBranchConstant, withNoise: noise)
    let fourthTunnelBranchSampler = WeirdScaledSampler(type: .scaleTunnels, withInput: fourthTunnelBranchConstant, withNoise: noise)

    let firstCaveBranchSampler = WeirdScaledSampler(type: .scaleCaves, withInput: firstCaveBranchConstant, withNoise: noise)
    let secondCaveBranchSampler = WeirdScaledSampler(type: .scaleCaves, withInput: secondCaveBranchConstant, withNoise: noise)
    let thirdCaveBranchSampler = WeirdScaledSampler(type: .scaleCaves, withInput: thirdCaveBranchConstant, withNoise: noise)
    let fourthCaveBranchSampler = WeirdScaledSampler(type: .scaleCaves, withInput: fourthCaveBranchConstant, withNoise: noise)
    let fifthCaveBranchSampler = WeirdScaledSampler(type: .scaleCaves, withInput: fifthCaveBranchConstant, withNoise: noise)

    // noise.sample(samplingPos) = 16 * 32 * 48 = 24576
    let samplingPos = PosInt3D(x: 16, y: 32, z: 48)

    #expect(firstTunnelBranchSampler.sample(at: samplingPos) == 0.75 * 24576 / 0.75 / 0.75 / 0.75)
    #expect(secondTunnelBranchSampler.sample(at: samplingPos) == 24576)
    #expect(thirdTunnelBranchSampler.sample(at: samplingPos) == 1.5 * 24576 / 1.5 / 1.5 / 1.5)
    #expect(fourthTunnelBranchSampler.sample(at: samplingPos) == 2.0 * 24576 / 2.0 / 2.0 / 2.0)

    #expect(firstCaveBranchSampler.sample(at: samplingPos) == 0.5 * 24576 / 0.5 / 0.5 / 0.5)
    #expect(secondCaveBranchSampler.sample(at: samplingPos) == 0.75 * 24576 / 0.75 / 0.75 / 0.75)
    #expect(thirdCaveBranchSampler.sample(at: samplingPos) == 24576)
    #expect(fourthCaveBranchSampler.sample(at: samplingPos) == 2.0 * 24576 / 2.0 / 2.0 / 2.0)
    #expect(fifthCaveBranchSampler.sample(at: samplingPos) == 3.0 * 24576 / 3.0 / 3.0 / 3.0)
}

// I'm kind of just assuming that this one works.
@Test func testOutputForSpline() async throws {
    let spline = createTestSpline(sampledAt: 1.5)
    let splineFunc = SplineDensityFunction(withSpline: spline)
    let samplingPos = PosInt3D(x: 0, y: 0, z: 0)
    #expect(splineFunc.sample(at: samplingPos) == 2.5)
}

fileprivate struct YInvertedTestNoise: DensityFunctionNoise {
    let key: RegistryKey<NoiseDefinition>
    init(name: String = "test:dummy") {
        self.key = RegistryKey<NoiseDefinition>(referencing: name)
    }
    func sample(x: Double, y: Double, z: Double) -> Double {
        return x - y + z
    }
}

@Test func testOutputForFindTopSurface() async throws {
    let sampledDensityFunction = NoiseDensityFunction(noise: YInvertedTestNoise(), scaleXZ: 1.0, scaleY: 1.0)
    let upperBoundDensityFunction = ConstantDensityFunction(value: 256.0)
    let findTopSurface = FindTopSurface(density: sampledDensityFunction, upperBound: upperBoundDensityFunction, lowerBound: 0, cellHeight: 8)

    // We use InvertedYTestNoise, which is just an additive sampler with negative Y,
    // so that its output increases the further down you go.
    // The highest y where noise.sample(x,y,z) >= 0 is y = -(x + z)
    
    // This one's 24 and not 30 because the cell height is 8.
    #expect(findTopSurface.sample(at: PosInt3D(x: 10, y: 0, z: 20)) == 24)
    // This one would be -25, but it goes below the boundary.
    #expect(findTopSurface.sample(at: PosInt3D(x: -50, y: 0, z: 25)) == 0)
    #expect(findTopSurface.sample(at: PosInt3D(x: 0, y: 0, z: 0)) == 0)
}