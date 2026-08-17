# Data

Generic data-related constructs used by DPReader.

DPReader uses these constructs to store information about data packs and worlds. Many of them work similarly to the methods used by Minecraft.

## Topics

### Registries

Registries are the types used to store information about what has been loaded from datapacks. They are conceptually similar to maps.

- ``Registry``
- ``RegistryKey``
- ``RegistryReferenceList``

### Chunks

Chunks are 16x16 areas of the world. They are the fundamental units of world generation.

- ``ProtoChunk``
- ``ProtoChunkSection``
- ``PalettedChunkBlockStorage``

### Blocks

Minecraft (at least as of now) has a hardcoded list of blocks that it uses in world generation. Therefore, DPReader uses an immutable enumeration to store all blocks in the game.

- ``Block``
- ``BlockState``
- ``BlockStateDefinition``
- ``Blocks``

### Positions and Volumes

- ``PosDouble3D``
- ``PosInt2D``
- ``PosInt3D``
- ``BoundingBox``

### NBT

DPReader implements custom NBT encoders and decoders that conform to the appropriate Swift standard library types, meaning that they can be used to encode and decode any type that conforms to ``Codable``.

- ``NBTDecoder``
- ``NBTEncoder``
- ``NBTTag``
- ``TagDefinition``
- ``TagValue``

### Random Data Types

These are data types that are used frequently in DPReader and that don't really make sense to cover anywhere else. Some of them are part of JSON files in datapacks, while others are just random DPReader internals.

- ``JSONValue``
- ``RegistryReferenceList``
- ``VerticalAnchor``
