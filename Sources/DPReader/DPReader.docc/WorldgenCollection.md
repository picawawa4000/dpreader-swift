# World Generation

DPReader's world generation facilities.

These are the facilities that DPReader uses to generate worlds based on the data loaded from datapacks. For an overview of how to use them, see <doc:Worldgen>.

## Topics

### Basic Types

- ``WorldGenerator``
- ``WorldSeed``

### Terrain LOD

In addition to directly generating chunks at a 1:1 scale, DPReader can generate blocks using lower scales at higher distances from a given point (a technique known as level-of-detail, or LOD, generation), which helps to conserve memory and improve performance in applications such as rendering. It can also stream those LODs to be consumed by a separate function, which can further reduce memory pressure.

- ``TerrainLODChunk``
- ``TerrainLODChunkKey``
- ``TerrainLODColumn``
- ``TerrainLODPayloadOptions``
- ``TerrainLODProgress``
- ``TerrainLODResult``
- ``TerrainLODSamplePayload``
- ``TerrainSurfaceLODCell``
- ``TerrainSurfaceLODChunk``
- ``TerrainSurfaceLODResult``

### Biome Search Trees

- ``BiomeSearchTree``
- ``NoiseHypercube``
- ``NoisePoint``
- ``ParameterRange``
- ``buildBiomeSearchTree(from:entries:packFormat:)``
- ``getPredefinedBiomeSearchTreeData(for:packFormat:)``
- ``BiomeSearchTreeError``
