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
    palette: [RegistryKey<Biome>],
    cache: StructureValidationBiomeCache?
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
        for (index, biome) in biomes.enumerated() {
            appendBiomeIDHash(try #require(paletteIDs[biome]), to: &hash)
            guard workload.scale == 1, let cache else { continue }
            let sampleX = origin.x + Int32(index % Int(workload.sampleSide))
            let sampleZ = origin.z + Int32(index / Int(workload.sampleSide))
            cache.insert(biome, at: PosInt3D(x: sampleX, y: origin.y, z: sampleZ))
        }
    }
    return (DispatchTime.now().uptimeNanoseconds - start, hash)
}

private final class StructureValidationBiomeCache {
    private struct Key: Hashable {
        let x: Int32
        let y: Int32
        let z: Int32
    }

    private struct Value {
        let biome: RegistryKey<Biome>
        let originatedInTile: Bool
    }

    private var values: [Key: Value] = [:]
    private(set) var generatedTileHits = 0
    private(set) var structureHits = 0
    private(set) var misses = 0

    func insert(_ biome: RegistryKey<Biome>, at position: PosInt3D) {
        self.values[Key(x: position.x, y: position.y, z: position.z)] = Value(
            biome: biome,
            originatedInTile: true
        )
    }

    func biome(at position: PosInt3D, generator: WorldGenerator, dimension: RegistryKey<DPReader.Dimension>) throws -> RegistryKey<Biome>? {
        let key = Key(x: position.x, y: position.y, z: position.z)
        if let cached = self.values[key] {
            if cached.originatedInTile {
                self.generatedTileHits += 1
            } else {
                self.structureHits += 1
            }
            return cached.biome
        }
        self.misses += 1
        let biome = try generator.sampleBiome(at: position, in: dimension)
        if let biome {
            self.values[key] = Value(biome: biome, originatedInTile: false)
        }
        return biome
    }
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

private final class StructureValidationBenchmarkMetrics {
    struct StructureSetMetrics {
        var nanos: UInt64 = 0
        var candidates = 0
        var valid = 0
    }

    var biomeNanos: UInt64 = 0
    var terrainNanos: UInt64 = 0
    var biomeSamples = 0
    var terrainSamples = 0
    var biomeCacheHits = 0
    var generatedTileBiomeCacheHits = 0
    var biomeCacheMisses = 0
    var structureSets: [String: StructureSetMetrics] = [:]
}

private func benchmarkValidatedStructureStarts(
    sampler: StructurePlacementSampler,
    context: StructureStartValidationContext,
    terrain: GeneratedStructureHeightmapSampler,
    metrics: StructureValidationBenchmarkMetrics,
    structureSets: [(key: RegistryKey<StructureSet>, value: StructureSet)],
    workload: BiomeTileWorkload
) throws -> (
    nanos: UInt64,
    candidateCount: Int,
    validCount: Int,
    terrainColumnFills: Int,
    biomeNanos: UInt64,
    terrainNanos: UInt64,
    biomeSamples: Int,
    terrainSamples: Int,
    terrainConstructionNanos: UInt64,
    terrainInterpolationNanos: UInt64,
    terrainCacheHits: Int,
    terrainCacheMisses: Int,
    biomeCacheHits: Int,
    generatedTileBiomeCacheHits: Int,
    biomeCacheMisses: Int,
    hash: UInt32
) {
    var candidateCount = 0
    var validCount = 0
    var hash: UInt32 = 2_166_136_261
    let minimumBlockX = workload.tileOrigins.map(\.x).min()!
    let minimumBlockZ = workload.tileOrigins.map(\.z).min()!
    let maximumBlockX = workload.tileOrigins.map(\.x).max()! + workload.tileWorldSide - 1
    let maximumBlockZ = workload.tileOrigins.map(\.z).max()! + workload.tileWorldSide - 1
    let minimumChunkX = floorDiv(minimumBlockX, by: 16)
    let minimumChunkZ = floorDiv(minimumBlockZ, by: 16)
    let maximumChunkX = floorDiv(maximumBlockX, by: 16)
    let maximumChunkZ = floorDiv(maximumBlockZ, by: 16)

    func validate(_ sample: StructurePlacementSample) throws {
        candidateCount += 1
        appendBiomeIDHash(sample.chunkPos.x, to: &hash)
        appendBiomeIDHash(sample.chunkPos.z, to: &hash)
        let structureStart = DispatchTime.now().uptimeNanoseconds
        let structure = try sampler.resolveStructure(for: sample, validatingWith: context)
        let structureNanos = DispatchTime.now().uptimeNanoseconds - structureStart
        var setMetrics = metrics.structureSets[sample.structureSetKey.name] ?? .init()
        setMetrics.nanos += structureNanos
        setMetrics.candidates += 1
        if let structure {
            validCount += 1
            setMetrics.valid += 1
            for byte in structure.name.utf8 {
                hash ^= UInt32(byte)
                hash &*= 16_777_619
            }
        }
        metrics.structureSets[sample.structureSetKey.name] = setMetrics
    }

    let initialTerrainColumns = terrain.terrainDensityColumnEvaluationCount
    let initialBiomeNanos = metrics.biomeNanos
    let initialTerrainNanos = metrics.terrainNanos
    let initialBiomeSamples = metrics.biomeSamples
    let initialTerrainSamples = metrics.terrainSamples
    let initialTerrainConstructionNanos = terrain.terrainChunkSamplerConstructionNanos
    let initialTerrainInterpolationNanos = terrain.terrainInterpolationNanos
    let initialTerrainCacheHits = terrain.terrainHeightCacheHits
    let initialTerrainCacheMisses = terrain.terrainHeightCacheMisses
    let initialBiomeCacheHits = metrics.biomeCacheHits
    let initialGeneratedTileBiomeCacheHits = metrics.generatedTileBiomeCacheHits
    let initialBiomeCacheMisses = metrics.biomeCacheMisses
    let start = DispatchTime.now().uptimeNanoseconds
    for entry in structureSets {
        switch entry.value.placement {
        case .randomSpread(let placement):
            let minimumRegionX = floorDiv(minimumChunkX, by: Int32(placement.spacing))
            let maximumRegionX = floorDiv(maximumChunkX, by: Int32(placement.spacing))
            let minimumRegionZ = floorDiv(minimumChunkZ, by: Int32(placement.spacing))
            let maximumRegionZ = floorDiv(maximumChunkZ, by: Int32(placement.spacing))
            for regionZ in minimumRegionZ...maximumRegionZ {
                for regionX in minimumRegionX...maximumRegionX {
                    if let sample = try sampler.sampleStructureSet(
                        inRegion: PosInt2D(x: regionX, z: regionZ), for: entry.key
                    ), sample.chunkPos.x >= minimumChunkX, sample.chunkPos.x <= maximumChunkX,
                       sample.chunkPos.z >= minimumChunkZ, sample.chunkPos.z <= maximumChunkZ {
                        try validate(sample)
                    }
                }
            }
        case .concentricRings:
            for sample in try sampler.sampleAllPlacements(for: entry.key)
            where sample.chunkPos.x >= minimumChunkX && sample.chunkPos.x <= maximumChunkX
                && sample.chunkPos.z >= minimumChunkZ && sample.chunkPos.z <= maximumChunkZ {
                try validate(sample)
            }
        }
    }
    return (
        DispatchTime.now().uptimeNanoseconds - start,
        candidateCount,
        validCount,
        terrain.terrainDensityColumnEvaluationCount - initialTerrainColumns,
        metrics.biomeNanos - initialBiomeNanos,
        metrics.terrainNanos - initialTerrainNanos,
        metrics.biomeSamples - initialBiomeSamples,
        metrics.terrainSamples - initialTerrainSamples,
        terrain.terrainChunkSamplerConstructionNanos - initialTerrainConstructionNanos,
        terrain.terrainInterpolationNanos - initialTerrainInterpolationNanos,
        terrain.terrainHeightCacheHits - initialTerrainCacheHits,
        terrain.terrainHeightCacheMisses - initialTerrainCacheMisses,
        metrics.biomeCacheHits - initialBiomeCacheHits,
        metrics.generatedTileBiomeCacheHits - initialGeneratedTileBiomeCacheHits,
        metrics.biomeCacheMisses - initialBiomeCacheMisses,
        hash
    )
}

private func benchmarkBiomeTileWASMModulesInNode(
    modules: [[UInt8]],
    workloads: [BiomeTileWorkload]
) throws -> [(nanos: UInt64, setupNanos: UInt64, hash: UInt32)]? {
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
      const bytes = fs.readFileSync(path);
      const setupStart = process.hrtime.bigint();
      const module = new WebAssembly.Module(bytes);
      if (WebAssembly.Module.imports(module).length !== 0) throw new Error('unexpected WASM imports');
      const instance = new WebAssembly.Instance(module, {});
      const tileSide = tileSides[workloadIndex];
      const minimum = -4 * tileSide;
      instance.exports.sample_bulk(minimum, 256, minimum);
      const setupNanos = process.hrtime.bigint() - setupStart;
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
      return [process.hrtime.bigint() - start, setupNanos, hash >>> 0];
    });
    process.stdout.write(results.map((result, index) => `${index} ${result[0]} ${result[1]} ${result[2]}`).join('\\n'));
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
        #expect(fields.count == 4)
        #expect(Int(fields[0]) == expectedIndex)
        return (
            nanos: try #require(UInt64(fields[1])),
            setupNanos: try #require(UInt64(fields[2])),
            hash: try #require(UInt32(fields[3]))
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

    let pack = try DataPack(fromRootPath: vanillaDataPath)
    let generator = try WorldGenerator(
        withWorldSeed: 987_654_321,
        usingDataPacks: [pack],
        usingSettings: RegistryKey(referencing: "minecraft:overworld"),
        useBiomeSearchAlternative: true
    )
    let dimension = RegistryKey<DPReader.Dimension>(referencing: "minecraft:overworld")
    let structureSampler = StructurePlacementSampler(withWorldSeed: 987_654_321, usingDataPacks: [pack])
    let terrainSettings = try generator.terrainSettingsForTesting()
    let structureTerrain = GeneratedStructureHeightmapSampler(
        worldGenerator: generator,
        seaLevel: 63,
        minimumWorldY: Int32(terrainSettings.minY),
        maximumWorldY: Int32(terrainSettings.minY + terrainSettings.height - 1),
        dimension: dimension
    )
    let structureMetrics = StructureValidationBenchmarkMetrics()
    let biomeCache = StructureValidationBiomeCache()
    let structureContext = StructureStartValidationContext(
        dimension: dimension,
        seaLevel: 63,
        minimumWorldY: Int32(terrainSettings.minY),
        maximumWorldY: Int32(terrainSettings.minY + terrainSettings.height - 1),
        worldSurfaceIsAtLeastSeaLevel: true,
        prefersHeightBeforeBiomeValidation: true,
        heightmapSampler: { heightmap, x, z in
            structureMetrics.terrainSamples += 1
            let start = DispatchTime.now().uptimeNanoseconds
            defer { structureMetrics.terrainNanos += DispatchTime.now().uptimeNanoseconds - start }
            return try structureTerrain.height(heightmap, x, z)
        },
        biomeSampler: { position in
            structureMetrics.biomeSamples += 1
            let start = DispatchTime.now().uptimeNanoseconds
            defer { structureMetrics.biomeNanos += DispatchTime.now().uptimeNanoseconds - start }
            let initialHits = biomeCache.structureHits
            let initialGeneratedTileHits = biomeCache.generatedTileHits
            let initialMisses = biomeCache.misses
            let biome = try biomeCache.biome(at: position, generator: generator, dimension: dimension)
            structureMetrics.biomeCacheHits += biomeCache.structureHits - initialHits
            structureMetrics.generatedTileBiomeCacheHits += biomeCache.generatedTileHits - initialGeneratedTileHits
            structureMetrics.biomeCacheMisses += biomeCache.misses - initialMisses
            return biome
        }
    )
    let structureSets = try pack.structureSetRegistry.entries().filter {
        try structureSampler.structureSetCanGenerate($0.key, in: dimension)
    }
    // Concentric-ring placements depend only on configuration and seed. Populate their sampler
    // cache once instead of charging this stable setup to the first tile workload.
    for entry in structureSets {
        if case .concentricRings = entry.value.placement {
            _ = try structureSampler.sampleAllPlacements(for: entry.key)
        }
    }
    var wasmSamplers: [CompiledNoiseRouterBiomeBulkSampler] = []
    var wasmSetupNanos: [UInt64] = []
    for workload in realWorldBiomeTileWorkloads {
        let volume = CompiledDensityFunctionBufferContext(
            xCount: workload.sampleSide,
            yCount: 1,
            zCount: workload.sampleSide,
            xStep: workload.scale,
            yStep: 1,
            zStep: workload.scale
        )
        let setupStart = DispatchTime.now().uptimeNanoseconds
        wasmSamplers.append(try generator.makeBiomeIDBulkSampler(
            for: volume,
            in: dimension,
            strategy: .wasm
        ))
        wasmSetupNanos.append(DispatchTime.now().uptimeNanoseconds - setupStart)
    }

    var referenceHashes: [UInt32] = []
    var uncompiledNanos: [UInt64] = []
    for (workload, sampler) in zip(realWorldBiomeTileWorkloads, wasmSamplers) {
        let result = try benchmarkUncompiledBiomeTiles(
            generator: generator,
            workload: workload,
            dimension: dimension,
            palette: sampler.palette,
            cache: biomeCache
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

    let structureResults = try realWorldBiomeTileWorkloads.map {
        try benchmarkValidatedStructureStarts(
            sampler: structureSampler,
            context: structureContext,
            terrain: structureTerrain,
            metrics: structureMetrics,
            structureSets: structureSets,
            workload: $0
        )
    }

    #if canImport(CLLVM)
    var llvmSetupNanos: [UInt64] = []
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
        let setupStart = DispatchTime.now().uptimeNanoseconds
        let sampler = try generator.makeBiomeIDBulkSampler(
            for: volume,
            in: dimension,
            strategy: .llvm
        )
        llvmSetupNanos.append(DispatchTime.now().uptimeNanoseconds - setupStart)
        llvmResults.append(benchmarkCompiledBiomeTiles(sampler: sampler, workload: workload))
    }
    #expect(llvmResults.map(\.hash) == referenceHashes)
    #endif

    for index in realWorldBiomeTileWorkloads.indices {
        let workload = realWorldBiomeTileWorkloads[index]
        #if canImport(CLLVM)
        let llvmText = "LLVM \(llvmResults[index].nanos) ns (setup \(llvmSetupNanos[index]) ns)"
        #else
        let llvmText = "LLVM unavailable"
        #endif
        let wasmText = wasmResults.map {
            "WASM/Node \($0[index].nanos) ns (Swift emit \(wasmSetupNanos[index]) ns; Node compile/init \($0[index].setupNanos) ns)"
        } ?? "WASM/Node unavailable (setup \(wasmSetupNanos[index]) ns)"
        print(
            "benchmarkRealWorldBiomeTileGeneration:", workload.label + ";",
            workload.sampleSide * workload.sampleSide * 64, "samples;",
            "uncompiled", uncompiledNanos[index], "ns;", wasmText + ";", llvmText + ";",
            "structure starts", structureResults[index].nanos, "ns",
            "(\(structureResults[index].candidateCount) candidates; \(structureResults[index].validCount) valid;",
            "\(structureResults[index].terrainColumnFills) terrain density column fills);",
            "validation breakdown biome \(structureResults[index].biomeNanos) ns",
            "(\(structureResults[index].biomeSamples) samples; \(structureResults[index].biomeCacheHits) structure hits; \(structureResults[index].generatedTileBiomeCacheHits) tile hits; \(structureResults[index].biomeCacheMisses) misses), terrain \(structureResults[index].terrainNanos) ns",
            "(\(structureResults[index].terrainSamples) height requests; \(structureResults[index].terrainCacheHits) cache hits; \(structureResults[index].terrainCacheMisses) misses; construction \(structureResults[index].terrainConstructionNanos) ns; interpolation \(structureResults[index].terrainInterpolationNanos) ns);",
            "checksums", referenceHashes[index], structureResults[index].hash
        )
    }
    let slowestStructureSets = structureMetrics.structureSets.sorted { $0.value.nanos > $1.value.nanos }.prefix(5)
    print(
        "benchmarkRealWorldBiomeTileGeneration slowest structure sets:",
        slowestStructureSets.map {
            "\($0.key) \($0.value.nanos) ns (\($0.value.candidates) candidates; \($0.value.valid) valid)"
        }.joined(separator: "; ")
    )
}
#endif
