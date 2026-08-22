# How to Generate Worlds

Load the data packs that define the dimension, biomes, noises, density functions, and noise settings you want to use. Later packs take precedence over earlier packs when registries are merged.

```swift
import DPReader
import Foundation

let vanilla = try DataPack(fromRootPath: URL(fileURLWithPath: "/path/to/vanilla-pack"))
let generator = try WorldGenerator(
    withWorldSeed: 12345,
    usingDataPacks: [vanilla],
    usingSettings: RegistryKey<NoiseSettings>(referencing: "minecraft:overworld")
)
```

Generate one chunk by creating a ``ProtoChunk`` and supplying its chunk coordinates. `generateInto(_:at:)` configures the chunk's vertical range and populates terrain plus exact and quart-resolution biome data.

```swift
let chunk = ProtoChunk()
try generator.generateInto(chunk, at: PosInt2D(x: 0, z: 0))

let localPosition = PosInt3D(x: 8, y: 64 - chunk.minY, z: 8)
let isSolid = chunk.isTerrain(atLocal: localPosition)
let biome = chunk.biome(atLocal: localPosition)
```

For point queries, use ``WorldGenerator/sampleBlockBiome(at:in:)`` or the climate sampling APIs. For maps and renderers that do not require full block resolution, see ``WorldGenerator/sampleLOD(from:radius:startingRadius:radiusStep:maxCellSizePower:threadCount:payloads:progressHandler:chunkHandler:)`` and ``WorldGenerator/sampleSurfaceLOD(from:radius:startingRadius:radiusStep:maxCellSizePower:threadCount:progressHandler:chunkHandler:)``.

> Important: A `WorldGenerator` can be reused with a different seed through ``WorldGenerator/setWorldSeed(_:)``. A single generator synchronizes terrain generation internally, but individual ``ProtoChunk`` instances are not concurrency-safe.

## Topics

### Setup

- ``DataPack``
- ``DataPackRegistryLoadingOptions``
- ``WorldGenerator``
- ``RegistryKey``
- ``NoiseSettings``

### Chunk Generation

- ``ProtoChunk``
- ``ProtoChunkSection``
- ``PosInt2D``
- ``PosInt3D``

### Additional Sampling

- <doc:WorldgenCollection>
- <doc:Structures>
