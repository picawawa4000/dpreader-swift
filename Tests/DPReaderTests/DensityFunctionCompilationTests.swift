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

private struct CompilerTestNoise: DensityFunctionNoise {
    let key = RegistryKey<NoiseDefinition>(referencing: "test:compiler_noise")

    func sample(x: Double, y: Double, z: Double) -> Double {
        x * 0.25 + y * 0.5 - z * 0.75
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
    buffer.withUnsafeMutableBufferPointer { bufferPointer in
        compiledFunction.fill(at: basePos, into: bufferPointer)
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

@Test func testCompiledShiftedNoiseCoordinates() throws {
    let shiftInput = YClampedGradient(fromY: -8, toY: 12, fromValue: -1.5, toValue: 2.5)
    let shiftedNoise = ShiftedNoise(
        noise: CompilerTestNoise(),
        shiftX: BinaryDensityFunction(
            firstOperand: shiftInput,
            secondOperand: ConstantDensityFunction(value: 0.75),
            type: .ADD
        ),
        shiftY: UnaryDensityFunction(operand: shiftInput, type: .HALF_NEGATIVE),
        shiftZ: ClampDensityFunction(input: shiftInput, lowerBound: -0.25, upperBound: 1.25),
        scaleXZ: 0.25,
        scaleY: 0.5
    )

    try assertCompiledSampleMatches(
        shiftedNoise,
        label: "shifted_noise_coordinates",
        at: PosInt3D(x: -7, y: 3, z: 11)
    )
    try assertCompiledBufferMatches(
        shiftedNoise,
        label: "shifted_noise_coordinates",
        bufferContext: CompiledDensityFunctionBufferContext(xCount: 3, yCount: 4, zCount: 2, xStep: 2, yStep: 3, zStep: 5),
        basePos: PosInt3D(x: -7, y: -4, z: 11)
    )
}

@Test func testCompiledDensityFunctionStrategies() throws {
    let coordinateInput = YClampedGradient(fromY: -8, toY: 12, fromValue: -1.5, toValue: 2.5)
    let densityFunction = BinaryDensityFunction(
        firstOperand: ShiftedNoise(
            noise: CompilerTestNoise(),
            shiftX: BinaryDensityFunction(
                firstOperand: ShiftDensityFunction(noise: CompilerTestNoise(), shiftType: .SHIFT_XZ),
                secondOperand: coordinateInput,
                type: .ADD
            ),
            shiftY: UnaryDensityFunction(operand: coordinateInput, type: .HALF_NEGATIVE),
            shiftZ: ClampDensityFunction(input: coordinateInput, lowerBound: -0.25, upperBound: 1.25),
            scaleXZ: 0.25,
            scaleY: 0.5
        ),
        secondOperand: UnaryDensityFunction(
            operand: ConstantDensityFunction(value: -0.5),
            type: .SQUARE
        ),
        type: .ADD
    )
    let frontendProgram = try buildDensityFunctionIR(densityFunction: densityFunction, registry: Registry())
    let wasm = try compile(densityFunction: densityFunction, strategy: .wasm)

    #expect(frontendProgram.densityFunctions.isEmpty)
    #expect(frontendProgram.noises.count == 2)
    #expect(wasm.strategy == .wasm)
    #expect(wasm.wasmModule?.prefix(8) == [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])
#if canImport(CLLVM)
    let llvm = try compile(densityFunction: densityFunction, strategy: .llvm)
    #expect(llvm.strategy == .llvm)
#endif
    for position in [
        PosInt3D(x: -7, y: -4, z: 11),
        PosInt3D(x: 0, y: 3, z: 0),
        PosInt3D(x: 17, y: 15, z: -23)
    ] {
        let expected = densityFunction.sample(at: position)
        #expect(checkDouble(wasm(position.x, position.y, position.z), expected))
#if canImport(CLLVM)
        #expect(checkDouble(llvm(position.x, position.y, position.z), expected))
#endif
    }
}

#if canImport(CLLVM)
@Test func testLLVMSharedSeedNoiseUpdatesWithoutRecompilation() throws {
    var firstRandom = XoroshiroRandom(seed: 11)
    let noise = BakedNoise(
        fromKey: RegistryKey(referencing: "test:shared_llvm_seed_noise"),
        withSampler: DoublePerlinNoise(
            random: &firstRandom,
            firstOctave: -5,
            amplitudes: [1.0, 0.5, 0.25],
            useModernInitialization: true
        ),
        usesSharedSeedStorage: true
    )
    let density = NoiseDensityFunction(noise: noise, scaleXZ: 0.125, scaleY: 0.25)
    let compiled = try compile(densityFunction: density, strategy: .llvm)
    let position = PosInt3D(x: 1_337, y: 47, z: -9_007)
    let firstValue = compiled(position.x, position.y, position.z)
    #expect(firstValue == density.sample(at: position))

    var secondRandom = XoroshiroRandom(seed: 22)
    noise.replaceSampler(with: DoublePerlinNoise(
        random: &secondRandom,
        firstOctave: -5,
        amplitudes: [1.0, 0.5, 0.25],
        useModernInitialization: true
    ))
    let secondValue = compiled(position.x, position.y, position.z)

    #expect(secondValue == density.sample(at: position))
    #expect(secondValue != firstValue)
}
#endif

@Test func testCompiledDensityFunctionBulkStrategiesUseTheSameAPI() throws {
    let densityFunction = BinaryDensityFunction(
        firstOperand: YClampedGradient(fromY: -16, toY: 32, fromValue: -2, toValue: 4),
        secondOperand: ConstantDensityFunction(value: 0.75),
        type: .ADD
    )
    let volume = CompiledDensityFunctionBufferContext(
        xCount: 3,
        yCount: 4,
        zCount: 2,
        xStep: 2,
        yStep: 3,
        zStep: 5
    )
    let basePosition = PosInt3D(x: -7, y: -11, z: 13)
    let wasm = try compile(
        densityFunction: densityFunction,
        bufferContext: volume,
        strategy: .wasm
    )

    #expect(wasm.strategy == .wasm)
    #expect(wasm.wasmModule != nil)
    #if canImport(CLLVM)
    let llvm = try compile(
        densityFunction: densityFunction,
        bufferContext: volume,
        strategy: .llvm
    )
    #expect(llvm.strategy == .llvm)
    #expect(llvm.wasmModule == nil)
    let llvmValues = llvm(at: basePosition)
    let wasmValues = wasm(at: basePosition)
    #expect(zip(llvmValues, wasmValues).allSatisfy { checkDouble($0.0, $0.1) })
    #endif
}

@Test func testUnsupportedDensityFunctionCompilationStrategies() throws {
    let densityFunction = ConstantDensityFunction(value: 1.0)

#if !canImport(CLLVM)
    do {
        _ = try compile(densityFunction: densityFunction, strategy: .llvm)
        Issue.record("LLVM compilation should be unsupported when CLLVM cannot be imported.")
    } catch let error as DensityFunctionCompilationError {
        guard case .unsupportedCompilationStrategy(.llvm) = error else {
            Issue.record("Unexpected disabled LLVM compilation error: \(error)")
            return
        }
    }
#endif

    let wasmBulk = try compile(
        densityFunction: densityFunction,
        bufferContext: CompiledDensityFunctionBufferContext(xCount: 1, yCount: 1, zCount: 1),
        strategy: .wasm
    )
    #expect(wasmBulk.strategy == .wasm)
    #expect(wasmBulk(at: PosInt3D(x: 0, y: 0, z: 0)) == [1.0])

    do {
        _ = try compile(
            densityFunction: densityFunction,
            cellSize: DensityFunctionCellSize(horizontalBlockCount: 4, verticalBlockCount: 4),
            cellVolume: DensityFunctionCellVolume(xCount: 1, yCount: 1, zCount: 1),
            strategy: .wasm
        )
        Issue.record("Cell-volume WASM compilation should be unsupported.")
    } catch let error as DensityFunctionCompilationError {
        guard case .unsupportedCompilationStrategy(.wasm) = error else {
            Issue.record("Unexpected cell-volume WASM compilation error: \(error)")
            return
        }
    }
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

    buffer.withUnsafeMutableBufferPointer { bufferPointer in
        compiledFunction.fill(at: PosInt3D(x: 5, y: -2, z: 7), into: bufferPointer)
    }

    #expect(shared.sampleCount == bufferContext.sampleCount)
}

@Test func testCompiledDensityFunctionCellBulkExecutionModel() throws {
    let flatDelegate = CountingDensityFunction()
    let cache2DDelegate = CountingDensityFunction()
    let flat = CacheMarker(type: .flatCache, wrapping: flatDelegate)
    let cache2D = CacheMarker(type: .cache2D, wrapping: cache2DDelegate)
    let interpolated = CacheMarker(
        type: .interpolated,
        wrapping: YClampedGradient(fromY: -8, toY: 8, fromValue: -2.0, toValue: 2.0)
    )
    let densityFunction = BinaryDensityFunction(
        firstOperand: BinaryDensityFunction(firstOperand: flat, secondOperand: cache2D, type: .ADD),
        secondOperand: interpolated,
        type: .ADD
    )
    let cellSize = DensityFunctionCellSize(sizeHorizontal: 1, sizeVertical: 1)
    let cellVolume = DensityFunctionCellVolume(xCount: 2, yCount: 2, zCount: 1)
    let program = try compile(densityFunction: densityFunction, cellSize: cellSize, cellVolume: cellVolume)

    #expect(program.cacheCount == 2)
    #expect(program.cacheElementsPerCell == 16)
    #expect(program.cacheValueCount == 32)
    #expect(program.outputValueCount == 256)

    var cache = [Double](repeating: .nan, count: program.cacheValueCount)
    var output = [Double](repeating: .nan, count: program.outputValueCount)
    cache.withUnsafeMutableBufferPointer { cacheBuffer in
        var context = CompiledDensityFunctionBulkEvaluationContext(
            cacheValues: cacheBuffer.baseAddress,
            cacheValueCount: cacheBuffer.count
        )
        withUnsafePointer(to: &context) { contextPointer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                program.function(UnsafeRawPointer(contextPointer), 0, -8, 0, outputBuffer.baseAddress)
            }
        }
    }

    var index = 0
    for cellZ in 0..<Int(cellVolume.zCount) {
        for cellX in 0..<Int(cellVolume.xCount) {
            for cellY in 0..<Int(cellVolume.yCount) {
                for localZ in 0..<Int(cellSize.horizontalBlockCount) {
                    for localX in 0..<Int(cellSize.horizontalBlockCount) {
                        for localY in 0..<Int(cellSize.verticalBlockCount) {
                            let x = Int32(cellX * 4 + localX)
                            let y = Int32(-8 + cellY * 4 + localY)
                            let z = Int32(cellZ * 4 + localZ)
                            let flatValue = Double((x / 4) * 4 + (z / 4) * 4)
                            let cache2DValue = Double(x - 8 + z)
                            let interpolatedValue = -2.0 + Double(y + 8) * 0.25
                            #expect(checkDouble(output[index], flatValue + cache2DValue + interpolatedValue))
                            index += 1
                        }
                    }
                }
            }
        }
    }
    #expect(flatDelegate.sampleCount == 32)
    #expect(cache2DDelegate.sampleCount == 32)
}

@Test func testCompiledDensityFunctionCellBulkRejectsMissingReference() throws {
    let reference = ReferenceDensityFunction(target: "test:missing_bulk_reference")
    #expect(throws: DensityFunctionCompilationError.self) {
        _ = try compile(
            densityFunction: reference,
            cellSize: DensityFunctionCellSize(sizeHorizontal: 1, sizeVertical: 1),
            cellVolume: DensityFunctionCellVolume(xCount: 1, yCount: 1, zCount: 1)
        )
    }
}

@Test func testCompiledDensityFunctionCellBulkElidesInterpolatorCaches() throws {
    let densityFunction = CacheMarker(
        type: .interpolated,
        wrapping: CacheMarker(
            type: .flatCache,
            wrapping: CountingDensityFunction()
        )
    )
    let program = try compile(
        densityFunction: densityFunction,
        cellSize: DensityFunctionCellSize(sizeHorizontal: 1, sizeVertical: 1),
        cellVolume: DensityFunctionCellVolume(xCount: 2, yCount: 2, zCount: 2)
    )
    #expect(program.cacheCount == 0)
    #expect(program.cacheValueCount == 0)
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

    buffer.withUnsafeMutableBufferPointer { bufferPointer in
        compiledFunction.fill(at: PosInt3D(x: 5, y: -2, z: 7), into: bufferPointer)
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
