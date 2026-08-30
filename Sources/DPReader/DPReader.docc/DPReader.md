# ``DPReader``

A Swift library for loading Minecraft data packs and reproducing selected world-generation, structure, and loot algorithms.

Load a ``DataPack`` to access its registries, then pass one or more packs to a ``WorldGenerator`` or one of the structure-generation APIs. Registry identifiers use Minecraft namespaced IDs such as `minecraft:overworld`.

## Building and Testing

`swift build` intentionally builds without the `TestVisible` macro package. To run the test suite,
enable the test-only annotations and generated `testingAttributes` accessors explicitly:

```shell
USE_TEST_VISIBLE=1 swift test
```

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
- <doc:BiomeTileGeneration>
- <doc:DensityFunctions>
- <doc:Structures>
- <doc:SurfaceRules>
- <doc:Dimensions>

### Deterministic Utilities

- <doc:RNG>
- <doc:DFCompiler>
