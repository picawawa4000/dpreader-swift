import Foundation
import Testing
@testable import DPReader

#if !(os(WASI) || arch(wasm32))
private struct BiomeTileWorkload {
    let tileWorldSide: Int32
    let scale: Int32

    var sampleSide: Int32 { self.tileWorldSide / self.scale }

    var label: String {
        "8x8 \(self.tileWorldSide)x\(self.tileWorldSide) tiles at 1:\(self.scale)"
    }

    var tileOrigins: [PosInt3D] {
        let minimum = -4 * self.tileWorldSide
        return (0..<8).flatMap { tileZ in
            (0..<8).map { tileX in
                PosInt3D(
                    x: minimum + Int32(tileX) * self.tileWorldSide,
                    y: 256,
                    z: minimum + Int32(tileZ) * self.tileWorldSide
                )
            }
        }
    }
}

private let realWorldBiomeTileWorkloads = [
    BiomeTileWorkload(tileWorldSide: 64, scale: 1),
    BiomeTileWorkload(tileWorldSide: 256, scale: 4),
    BiomeTileWorkload(tileWorldSide: 1_024, scale: 16)
]

private func appendBiomeIDHash(_ biomeID: Int32, to hash: inout UInt32) {
    hash ^= UInt32(bitPattern: biomeID)
    hash &*= 16_777_619
}

private func benchmarkUncompiledBiomeTiles(
    generator: WorldGenerator,
    workload: BiomeTileWorkload,
    dimension: RegistryKey<DPReader.Dimension>,
    palette: [RegistryKey<Biome>]
) throws -> (nanos: UInt64, hash: UInt32) {
    let paletteIDs = Dictionary(uniqueKeysWithValues: palette.enumerated().map { ($0.element, Int32($0.offset)) })
    let firstOrigin = workload.tileOrigins[0]
    _ = try generator.generateBiomesInSquare(
        from: PosInt2D(x: firstOrigin.x, z: firstOrigin.z),
        to: PosInt2D(
            x: firstOrigin.x + workload.tileWorldSide,
            z: firstOrigin.z + workload.tileWorldSide
        ),
        atY: firstOrigin.y,
        in: dimension,
        scale: workload.scale,
        forceNoBaking: true
    )

    var hash: UInt32 = 2_166_136_261
    let start = DispatchTime.now().uptimeNanoseconds
    for origin in workload.tileOrigins {
        let generated = try generator.generateBiomesInSquare(
            from: PosInt2D(x: origin.x, z: origin.z),
            to: PosInt2D(
                x: origin.x + workload.tileWorldSide,
                z: origin.z + workload.tileWorldSide
            ),
            atY: origin.y,
            in: dimension,
            scale: workload.scale,
            forceNoBaking: true
        )
        let biomes = try #require(generated)
        #expect(biomes.count == Int(workload.sampleSide * workload.sampleSide))
        for biome in biomes {
            appendBiomeIDHash(try #require(paletteIDs[biome]), to: &hash)
        }
    }
    return (DispatchTime.now().uptimeNanoseconds - start, hash)
}

private func benchmarkCompiledBiomeTiles(
    sampler: CompiledNoiseRouterBiomeBulkSampler,
    workload: BiomeTileWorkload
) -> (nanos: UInt64, hash: UInt32) {
    var output = [Int32](repeating: 0, count: sampler.bufferContext.sampleCount)
    output.withUnsafeMutableBufferPointer { sampler.fill(at: workload.tileOrigins[0], into: $0) }

    var hash: UInt32 = 2_166_136_261
    let start = DispatchTime.now().uptimeNanoseconds
    output.withUnsafeMutableBufferPointer { buffer in
        for origin in workload.tileOrigins {
            sampler.fill(at: origin, into: buffer)
            for biomeID in buffer {
                appendBiomeIDHash(biomeID, to: &hash)
            }
        }
    }
    return (DispatchTime.now().uptimeNanoseconds - start, hash)
}

private func benchmarkBiomeTileWASMModulesInNode(
    modules: [[UInt8]],
    workloads: [BiomeTileWorkload]
) throws -> [(nanos: UInt64, hash: UInt32)]? {
    let nodeCandidates = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
    guard let nodePath = nodeCandidates.first(where: FileManager.default.fileExists(atPath:)) else {
        return nil
    }
    let moduleURLs = try modules.enumerated().map { index, module -> URL in
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dpreader-biome-tiles-\(index)-\(UUID().uuidString).wasm")
        try Data(module).write(to: url, options: .atomic)
        return url
    }
    defer { moduleURLs.forEach { try? FileManager.default.removeItem(at: $0) } }

    let tileSides = workloads.map(\.tileWorldSide).map(String.init).joined(separator: ",")
    let script = """
    const fs = require('fs');
    const tileSides = [\(tileSides)];
    const results = process.argv.slice(1).map((path, workloadIndex) => {
      const module = new WebAssembly.Module(fs.readFileSync(path));
      if (WebAssembly.Module.imports(module).length !== 0) throw new Error('unexpected WASM imports');
      const instance = new WebAssembly.Instance(module, {});
      const tileSide = tileSides[workloadIndex];
      const minimum = -4 * tileSide;
      instance.exports.sample_bulk(minimum, 256, minimum);
      let hash = 2166136261;
      const start = process.hrtime.bigint();
      for (let tileZ = 0; tileZ < 8; tileZ++) {
        for (let tileX = 0; tileX < 8; tileX++) {
          const pointer = instance.exports.sample_bulk(
            minimum + tileX * tileSide, 256, minimum + tileZ * tileSide
          );
          const ids = new Int32Array(instance.exports.memory.buffer, pointer, 64 * 64);
          for (const id of ids) hash = Math.imul((hash ^ id) >>> 0, 16777619) >>> 0;
        }
      }
      return [process.hrtime.bigint() - start, hash >>> 0];
    });
    process.stdout.write(results.map((result, index) => `${index} ${result[0]} ${result[1]}`).join('\\n'));
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: nodePath)
    process.arguments = ["-e", script] + moduleURLs.map(\.path)
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    try process.run()
    process.waitUntilExit()
    let errorOutput = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    #expect(process.terminationStatus == 0, "Node WASM biome tile benchmark failed: \(errorOutput)")
    guard process.terminationStatus == 0 else { return nil }

    let lines = String(
        decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self
    ).split(separator: "\n")
    return try lines.enumerated().map { expectedIndex, line in
        let fields = line.split(separator: " ")
        #expect(fields.count == 3)
        #expect(Int(fields[0]) == expectedIndex)
        return (
            nanos: try #require(UInt64(fields[1])),
            hash: try #require(UInt32(fields[2]))
        )
    }
}

/// Exercises a map-rendering workload with a constant 64x64 output tile at three world scales.
@Test func benchmarkRealWorldBiomeTileGeneration() throws {
    let vanillaDataPath = URL(fileURLWithPath: #file)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("vanilla/1.21.11")
    guard FileManager.default.fileExists(atPath: vanillaDataPath.path) else { return }

    let generator = try WorldGenerator(
        withWorldSeed: 987_654_321,
        usingDataPacks: [try DataPack(fromRootPath: vanillaDataPath)],
        usingSettings: RegistryKey(referencing: "minecraft:overworld"),
        useBiomeSearchAlternative: true
    )
    let dimension = RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld")
    var wasmSamplers: [CompiledNoiseRouterBiomeBulkSampler] = []
    var wasmCompileNanos: [UInt64] = []
    for workload in realWorldBiomeTileWorkloads {
        let volume = CompiledDensityFunctionBufferContext(
            xCount: workload.sampleSide,
            yCount: 1,
            zCount: workload.sampleSide,
            xStep: workload.scale,
            yStep: 1,
            zStep: workload.scale
        )
        let start = DispatchTime.now().uptimeNanoseconds
        wasmSamplers.append(try generator.makeBiomeIDBulkSampler(
            for: volume,
            in: dimension,
            strategy: .wasm
        ))
        wasmCompileNanos.append(DispatchTime.now().uptimeNanoseconds - start)
    }

    var referenceHashes: [UInt32] = []
    var uncompiledNanos: [UInt64] = []
    for (workload, sampler) in zip(realWorldBiomeTileWorkloads, wasmSamplers) {
        let result = try benchmarkUncompiledBiomeTiles(
            generator: generator,
            workload: workload,
            dimension: dimension,
            palette: sampler.palette
        )
        referenceHashes.append(result.hash)
        uncompiledNanos.append(result.nanos)
    }

    let wasmModules = try wasmSamplers.map { try #require($0.wasmModule) }
    let wasmResults = try benchmarkBiomeTileWASMModulesInNode(
        modules: wasmModules,
        workloads: realWorldBiomeTileWorkloads
    )
    if let wasmResults {
        #expect(wasmResults.map(\.hash) == referenceHashes)
    }

    #if canImport(CLLVM)
    var llvmCompileNanos: [UInt64] = []
    var llvmResults: [(nanos: UInt64, hash: UInt32)] = []
    for workload in realWorldBiomeTileWorkloads {
        let volume = CompiledDensityFunctionBufferContext(
            xCount: workload.sampleSide,
            yCount: 1,
            zCount: workload.sampleSide,
            xStep: workload.scale,
            yStep: 1,
            zStep: workload.scale
        )
        let start = DispatchTime.now().uptimeNanoseconds
        let sampler = try generator.makeBiomeIDBulkSampler(
            for: volume,
            in: dimension,
            strategy: .llvm
        )
        llvmCompileNanos.append(DispatchTime.now().uptimeNanoseconds - start)
        llvmResults.append(benchmarkCompiledBiomeTiles(sampler: sampler, workload: workload))
    }
    #expect(llvmResults.map(\.hash) == referenceHashes)
    #endif

    for index in realWorldBiomeTileWorkloads.indices {
        let workload = realWorldBiomeTileWorkloads[index]
        #if canImport(CLLVM)
        let llvmText = "LLVM \(llvmResults[index].nanos) ns (compile \(llvmCompileNanos[index]) ns)"
        #else
        let llvmText = "LLVM unavailable"
        #endif
        let wasmText = wasmResults.map {
            "WASM/Node \($0[index].nanos) ns (compile \(wasmCompileNanos[index]) ns)"
        } ?? "WASM/Node unavailable (module compilation succeeded in \(wasmCompileNanos[index]) ns)"
        print(
            "benchmarkRealWorldBiomeTileGeneration:", workload.label + ";",
            workload.sampleSide * workload.sampleSide * 64, "samples;",
            "uncompiled", uncompiledNanos[index], "ns;", wasmText + ";", llvmText + ";",
            "checksum", referenceHashes[index]
        )
    }
}
#endif
