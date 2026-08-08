import Foundation
import Testing
@testable import DPReader

private func checkDouble(_ actualValue: Double, _ expectedValue: Double) -> Bool {
    let roundedActualValue = Int64((actualValue * 1_000_000_000).rounded(FloatingPointRoundingRule.toNearestOrEven))
    let roundedExpectedValue = Int64((expectedValue * 1_000_000_000).rounded(FloatingPointRoundingRule.toNearestOrEven))
    guard roundedExpectedValue == roundedActualValue else {
        print("Error in checkDouble: expected value", expectedValue, "(rounded to", roundedExpectedValue, ")", "did not match actual value", actualValue, "(rounded to", roundedActualValue, ")!")
        return false
    }
    return true
}

private final class CountingDensityFunction: DensityFunction {
    private(set) var sampleCount = 0

    func sample(at pos: PosInt3D) -> Double {
        self.sampleCount += 1
        return Double(pos.x + pos.y + pos.z)
    }

    func bake(withBaker baker: any DensityFunctionBaker) throws -> any DensityFunction {
        return self
    }

    init() {}

    init(from decoder: any Decoder) throws {
        fatalError("CountingDensityFunction is test-only.")
    }

    func encode(to encoder: any Encoder) throws {
        fatalError("CountingDensityFunction is test-only.")
    }
}

private func assertCompiledSampleMatches(
    _ densityFunction: any DensityFunction,
    label: String,
    at pos: PosInt3D,
    registry: Registry<DensityFunction> = Registry()
) throws {
    let sampledValue = densityFunction.sample(at: pos)
    let compiledFunction = try compile(densityFunction: densityFunction, registry: registry)
    let compiledValue = compiledFunction(pos.x, pos.y, pos.z)
    #expect(checkDouble(sampledValue, compiledValue), "\(label) did not match between interpreted and compiled execution")
}

private func assertCompiledBufferMatches(
    _ densityFunction: any DensityFunction,
    label: String,
    bufferContext: CompiledDensityFunctionBufferContext,
    basePos: PosInt3D,
    registry: Registry<DensityFunction> = Registry()
) throws {
    let compiledFunction = try compile(
        densityFunction: densityFunction,
        bufferContext: bufferContext,
        registry: registry
    )
    var buffer = [Double](repeating: 0.0, count: bufferContext.sampleCount)
    withUnsafePointer(to: bufferContext) { contextPointer in
        buffer.withUnsafeMutableBufferPointer { bufferPointer in
            compiledFunction(UnsafeRawPointer(contextPointer), basePos.x, basePos.y, basePos.z, bufferPointer.baseAddress)
        }
    }

    var index = 0
    var zOffset: Int32 = 0
    while zOffset < bufferContext.zCount {
        var xOffset: Int32 = 0
        while xOffset < bufferContext.xCount {
            var yOffset: Int32 = 0
            while yOffset < bufferContext.yCount {
                let pos = PosInt3D(
                    x: basePos.x + xOffset * bufferContext.xStep,
                    y: basePos.y + yOffset * bufferContext.yStep,
                    z: basePos.z + zOffset * bufferContext.zStep
                )
                #expect(checkDouble(densityFunction.sample(at: pos), buffer[index]), "\(label) buffer mismatch at \(pos)")
                index += 1
                yOffset += 1
            }
            xOffset += 1
        }
        zOffset += 1
    }
}

@Test func testCompiledDensityFunctionCorrectness() throws {
    let basicDensityFunction = BinaryDensityFunction(
        firstOperand: UnaryDensityFunction(operand: ConstantDensityFunction(value: -1.5), type: .SQUARE),
        secondOperand: UnaryDensityFunction(operand: ConstantDensityFunction(value: 0.5), type: .SQUEEZE),
        type: .MINIMUM
    )
    print("sampling...")
    let realValue = basicDensityFunction.sample(at: PosInt3D(x: 0, y: 0, z: 0))
    print("compiling...")
    let compiledFunction = try compile(densityFunction: basicDensityFunction)
    print("executing...")
    let compiledValue = compiledFunction(0, 0, 0)
    print("done!")
    #expect(checkDouble(realValue, compiledValue))
}

@Test func testCompiledDensityFunctionBufferedCorrectness() throws {
    let densityFunction = BinaryDensityFunction(
        firstOperand: YClampedGradient(fromY: -4, toY: 7, fromValue: -1.0, toValue: 2.0),
        secondOperand: EndIslandsDensityFunction(),
        type: .ADD
    )
    try assertCompiledBufferMatches(
        densityFunction,
        label: "buffered",
        bufferContext: CompiledDensityFunctionBufferContext(xCount: 3, yCount: 4, zCount: 2, xStep: 2, yStep: 3, zStep: 5),
        basePos: PosInt3D(x: -7, y: -4, z: 11)
    )
}

@Test func testCompiledDensityFunctionBufferedWorldScaleCachesCorrectness() throws {
    let densityFunction = BinaryDensityFunction(
        firstOperand: WorldScaleFlatCache(
            wrapping: BinaryDensityFunction(
                firstOperand: EndIslandsDensityFunction(),
                secondOperand: ConstantDensityFunction(value: 0.25),
                type: .ADD
            )
        ),
        secondOperand: WorldScaleCache2D(
            wrapping: YClampedGradient(fromY: -4, toY: 8, fromValue: -2.0, toValue: 3.0)
        ),
        type: .ADD
    )

    try assertCompiledBufferMatches(
        densityFunction,
        label: "buffered_world_scale_caches",
        bufferContext: CompiledDensityFunctionBufferContext(xCount: 6, yCount: 5, zCount: 7),
        basePos: PosInt3D(x: -6, y: -4, z: -5)
    )
}

@Test func testCompiledDensityFunctionBufferedChunkCachesCorrectness() throws {
    let bounds = ChunkSamplingBounds(chunkPos: PosInt2D(x: 0, z: 0), minY: -8, height: 16)
    let densityFunction = BinaryDensityFunction(
        firstOperand: ChunkFlatCache(
            wrapping: BinaryDensityFunction(
                firstOperand: EndIslandsDensityFunction(),
                secondOperand: ConstantDensityFunction(value: -0.5),
                type: .ADD
            ),
            bounds: bounds
        ),
        secondOperand: BinaryDensityFunction(
            firstOperand: ChunkCache2D(
                wrapping: YClampedGradient(fromY: -8, toY: 8, fromValue: -1.0, toValue: 1.0),
                bounds: bounds
            ),
            secondOperand: ChunkInterpolatedCache(
                wrapping: BinaryDensityFunction(
                    firstOperand: EndIslandsDensityFunction(),
                    secondOperand: YClampedGradient(fromY: -8, toY: 8, fromValue: -0.75, toValue: 0.75),
                    type: .ADD
                ),
                bounds: bounds,
                horizontalCellBlockCount: 4,
                verticalCellBlockCount: 4
            ),
            type: .ADD
        ),
        type: .ADD
    )

    try assertCompiledBufferMatches(
        densityFunction,
        label: "buffered_chunk_caches",
        bufferContext: CompiledDensityFunctionBufferContext(xCount: 16, yCount: 16, zCount: 16),
        basePos: PosInt3D(x: 0, y: -8, z: 0)
    )
}

@Test func testCompiledDensityFunctionBufferedSharedSubexpressionCaching() throws {
    let shared = CountingDensityFunction()
    let densityFunction = BinaryDensityFunction(
        firstOperand: shared,
        secondOperand: shared,
        type: .ADD
    )
    let bufferContext = CompiledDensityFunctionBufferContext(xCount: 4, yCount: 3, zCount: 2)
    let compiledFunction = try compile(densityFunction: densityFunction, bufferContext: bufferContext)
    var buffer = [Double](repeating: 0.0, count: bufferContext.sampleCount)

    withUnsafePointer(to: bufferContext) { contextPointer in
        buffer.withUnsafeMutableBufferPointer { bufferPointer in
            compiledFunction(UnsafeRawPointer(contextPointer), 5, -2, 7, bufferPointer.baseAddress)
        }
    }

    #expect(shared.sampleCount == bufferContext.sampleCount)
}

@Test func testCompiledDensityFunctionBufferedProfilingFusesSimpleTransforms() throws {
    let shared = CountingDensityFunction()
    let densityFunction = UnaryDensityFunction(
        operand: BinaryDensityFunction(
            firstOperand: BinaryDensityFunction(
                firstOperand: shared,
                secondOperand: ConstantDensityFunction(value: 1.5),
                type: .ADD
            ),
            secondOperand: ConstantDensityFunction(value: -2.0),
            type: .MULTIPLY
        ),
        type: .ABS
    )
    let bufferContext = CompiledDensityFunctionBufferContext(xCount: 4, yCount: 3, zCount: 2)
    let profilingState = BufferedDensityFunctionProfilingState()
    let compiledFunction = try compile(
        densityFunction: densityFunction,
        bufferContext: bufferContext,
        options: BufferedDensityFunctionCompilationOptions(profilingState: profilingState)
    )
    var buffer = [Double](repeating: 0.0, count: bufferContext.sampleCount)

    withUnsafePointer(to: bufferContext) { contextPointer in
        buffer.withUnsafeMutableBufferPointer { bufferPointer in
            compiledFunction(UnsafeRawPointer(contextPointer), 5, -2, 7, bufferPointer.baseAddress)
        }
    }

    #expect(shared.sampleCount == bufferContext.sampleCount)

    let report = try #require(profilingState.latestReport())
    #expect(report.nodes.count == 1)
    #expect(report.nodes.contains { node in
        node.kind == "scalar_fallback"
            && node.label.contains("CountingDensityFunction")
            && node.label.contains("add(1.5)")
            && node.label.contains("mul(-2.0)")
            && node.label.contains("unary.minecraft:abs")
    })
    #expect(report.fusedTransformCount == 3)
    #expect(report.nodes.allSatisfy { $0.outputValueCount == bufferContext.sampleCount })
}

@Test func testCompiledDensityFunctionCoverage() throws {
    let pos = PosInt3D(x: 7, y: 18, z: -11)

    let referenceTarget = ConstantDensityFunction(value: 2.75)
    let referenceRegistry = Registry<DensityFunction>()
    referenceRegistry.register(referenceTarget, forKey: RegistryKey(referencing: "test:compiled_reference"))
    let reference = ReferenceDensityFunction(target: "test:compiled_reference")
    reference.setDensityFunctionRegistry(referenceRegistry)

    let spline = SplineDensityFunction(
        withSpline: .object(
            SplineObject(
                withInput: YClampedGradient(fromY: 0, toY: 32, fromValue: 0.0, toValue: 1.0),
                locations: [0.0, 1.0],
                values: [.number(-1.0), .number(2.0)],
                derivatives: [0.0, 0.0]
            )
        )
    )

    var random = CheckedRandom(seed: 0)
    let oldBlendedNoise = InterpolatedNoise(
        random: &random,
        xzScale: 0.25,
        yScale: 0.5,
        xzFactor: 80.0,
        yFactor: 160.0,
        smearScaleMultiplier: 8.0
    )

    let densityFunctions: [(String, any DensityFunction)] = [
        ("clamp", ClampDensityFunction(input: ConstantDensityFunction(value: 2.5), lowerBound: -1.0, upperBound: 1.0)),
        ("y_clamped_gradient", YClampedGradient(fromY: 0, toY: 32, fromValue: -1.0, toValue: 2.0)),
        ("range_choice", RangeChoice(
            inputChoice: YClampedGradient(fromY: 0, toY: 32, fromValue: -1.0, toValue: 2.0),
            minInclusive: 0.2,
            maxExclusive: 0.8,
            whenInRange: UnaryDensityFunction(operand: ConstantDensityFunction(value: -3.0), type: .ABS),
            whenOutOfRange: BinaryDensityFunction(
                firstOperand: ConstantDensityFunction(value: 0.5),
                secondOperand: ConstantDensityFunction(value: 2.0),
                type: .ADD
            )
        )),
        ("shift", ShiftDensityFunction(noiseKey: "test:missing_noise", shiftType: .SHIFT_ALL)),
        ("noise", NoiseDensityFunction(noiseKey: "test:missing_noise", scaleXZ: 0.25, scaleY: 0.5)),
        ("shifted_noise", ShiftedNoise(
            noiseKey: "test:missing_noise",
            shiftX: ConstantDensityFunction(value: 1.0),
            shiftY: ConstantDensityFunction(value: -2.0),
            shiftZ: ConstantDensityFunction(value: 0.5),
            scaleXZ: 0.25,
            scaleY: 0.75
        )),
        ("cache_marker", CacheMarker(
            type: .cacheOnce,
            wrapping: BinaryDensityFunction(
                firstOperand: ConstantDensityFunction(value: 2.0),
                secondOperand: ConstantDensityFunction(value: 4.0),
                type: .MULTIPLY
            )
        )),
        ("blend_alpha", BlendAlpha()),
        ("blend_offset", BlendOffset()),
        ("blend_density", BlendDensity(wrapping: ConstantDensityFunction(value: -4.5))),
        ("beardifier", BeardifierMarker()),
        ("end_islands", EndIslandsDensityFunction()),
        ("weird_scaled_sampler", WeirdScaledSampler(
            type: .scaleTunnels,
            withInput: ConstantDensityFunction(value: 0.25),
            withNoiseFromKey: "test:missing_noise"
        )),
        ("spline", spline),
        ("find_top_surface", FindTopSurface(
            density: YClampedGradient(fromY: 0, toY: 16, fromValue: -1.0, toValue: 1.0),
            upperBound: ConstantDensityFunction(value: 16.0),
            lowerBound: 0,
            cellHeight: 4
        )),
        ("old_blended_noise", oldBlendedNoise)
    ]

    try assertCompiledSampleMatches(reference, label: "reference", at: pos, registry: referenceRegistry)
    for (label, densityFunction) in densityFunctions {
        try assertCompiledSampleMatches(densityFunction, label: label, at: pos)
    }
}

@Test func testCompiledDensityFunctionSplineBinarySearchCoverage() throws {
    let spline = SplineDensityFunction(
        withSpline: .object(
            SplineObject(
                withInput: YClampedGradient(fromY: -16, toY: 32, fromValue: -1.5, toValue: 2.5),
                locations: [-1.0, -0.25, 0.25, 1.0, 2.0],
                values: [
                    .number(-2.0),
                    .number(-0.5),
                    .number(0.75),
                    .number(1.25),
                    .number(2.0)
                ],
                derivatives: [0.0, -0.2, 0.4, 0.0, 0.3]
            )
        )
    )
    let positions = [
        PosInt3D(x: 0, y: -16, z: 0),
        PosInt3D(x: 0, y: -8, z: 0),
        PosInt3D(x: 0, y: 8, z: 0),
        PosInt3D(x: 0, y: 24, z: 0),
        PosInt3D(x: 0, y: 40, z: 0)
    ]

    for (index, pos) in positions.enumerated() {
        try assertCompiledSampleMatches(spline, label: "spline_binary_search_\(index)", at: pos)
    }
}

@Test func testCompiledDensityFunctionReferenceMustExistInRegistry() {
    do {
        _ = try compile(
            densityFunction: ReferenceDensityFunction(target: "test:missing_reference"),
            registry: Registry()
        )
        Issue.record("Expected missing registry reference compilation to fail.")
    } catch DensityFunctionCompilationError.badDensityFunction(let message) {
        #expect(message == "Missing referenced density function: test:missing_reference")
    } catch {
        Issue.record("Unexpected error: \(error)")
    }
}
