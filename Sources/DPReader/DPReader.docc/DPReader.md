# ``DPReader``

A Swift library for loading Minecraft data packs and reproducing selected world-generation, structure, and loot algorithms.

Load a ``DataPack`` to access its registries, then pass one or more packs to a ``WorldGenerator`` or one of the structure-generation APIs. Registry identifiers use Minecraft namespaced IDs such as `minecraft:overworld`.

## Topics

### Pack Loading

- ``DataPack``
- ``DataPackRegistryLoadingOptions``

### Pack Versioning

- ``Version``
- ``VersionRange``
- ``VersionedSchemaFeature``
- ``PackVersioning``

### Data

- <doc:CoreData>

### Loot

- <doc:LootTables>

### World Generation

- <doc:Worldgen>
- <doc:WorldgenCollection>
- <doc:DensityFunctions>
- <doc:Structures>
- <doc:SurfaceRules>
- <doc:Dimensions>

### Deterministic Utilities

- <doc:RNG>
- <doc:DFCompiler>
