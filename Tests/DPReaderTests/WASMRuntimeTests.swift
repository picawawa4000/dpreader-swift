import Testing
@testable import DPReader

private struct HostRuntimeTestNoise: DensityFunctionNoise {
    let key = RegistryKey<NoiseDefinition>(referencing: "test:host_runtime")

    func sample(x: Double, y: Double, z: Double) -> Double {
        x * 0.25 + y * 0.5 - z * 0.75
    }
}

private struct TestHostWASMRuntime: WASMRuntime {
    func instantiateDensityFunction(
        module: [UInt8],
        exportName: String,
        imports: WASMDensityFunctionImports
    ) throws -> WASMDensityFunctionInvocation {
        precondition(module.prefix(8) == [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])
        precondition(exportName == "sample")
        return { x, y, z in
            Double(x + y + z) + imports.sampleNoise(0, Double(x), Double(y), Double(z))
        }
    }

    func instantiateBiomeSearch(
        module: [UInt8],
        exportName: String
    ) throws -> WASMBiomeSearchInvocation {
        precondition(module.prefix(8) == [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])
        precondition(exportName == "search")
        return { temperature, _, _, _, _, _ in temperature < 0 ? 0 : 1 }
    }
}

@Test func testWASMBackendUsesHostRuntimeForDensityInvocation() throws {
    let densityFunction = ShiftDensityFunction(noise: HostRuntimeTestNoise(), shiftType: .SHIFT_XZ)
    let compiled = try compile(
        densityFunction: densityFunction,
        strategy: .wasm,
        runtime: TestHostWASMRuntime()
    )

    let expected = Double(2 + 3 + 4) + HostRuntimeTestNoise().sample(x: 2, y: 3, z: 4)
    #expect(compiled(2, 3, 4) == expected)
}

@Test func testWASMBackendUsesHostRuntimeForBiomeInvocation() throws {
    let keyA = RegistryKey<Biome>(referencing: "test:a")
    let keyB = RegistryKey<Biome>(referencing: "test:b")
    let zero = ParameterRange(min: 0, max: 0)
    let tree = try BiomeSearchTree(entries: [
        (
            NoiseHypercube(
                temperature: ParameterRange(min: -10_000, max: -1),
                humidity: zero,
                continentalness: zero,
                erosion: zero,
                depth: zero,
                weirdness: zero,
                offset: zero
            ),
            keyA
        ),
        (
            NoiseHypercube(
                temperature: ParameterRange(min: 0, max: 10_000),
                humidity: zero,
                continentalness: zero,
                erosion: zero,
                depth: zero,
                weirdness: zero,
                offset: zero
            ),
            keyB
        )
    ])
    let compiled = try tree.compile(strategy: .wasm, runtime: TestHostWASMRuntime())

    #expect(compiled(NoisePoint(
        temperature: -0.5,
        humidity: 0,
        continentalness: 0,
        erosion: 0,
        weirdness: 0,
        depth: 0
    )) == keyA)
    #expect(compiled(NoisePoint(
        temperature: 0.5,
        humidity: 0,
        continentalness: 0,
        erosion: 0,
        weirdness: 0,
        depth: 0
    )) == keyB)
}
