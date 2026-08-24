# Core Data Types

Core value types used to represent registry entries, chunks, blocks, positions, and NBT data.

DPReader uses these constructs to store information about data packs and worlds. Many of them mirror concepts used by Minecraft.

## Topics

### Registries

Registries store values loaded from data packs and address them with namespaced keys.

- ``Registry``
- ``RegistryKey``
- ``RegistryReferenceList``

### Chunks

Chunks are 16-by-16 columns of the world and are the fundamental units of full-resolution world generation.

- ``ProtoChunk``
- ``ProtoChunkSection``
- ``PalettedChunkBlockStorage``

### Blocks

``BlockState`` stores an arbitrary namespaced block ID directly alongside its properties. ``Blocks`` provides shared states used by the built-in structure generators; it is not a block registry.

- ``BlockState``
- ``Blocks``

### Positions and Volumes

- ``PosDouble3D``
- ``PosInt2D``
- ``PosInt3D``
- ``BoundingBox``

### NBT

DPReader's custom NBT encoders and decoders work with Swift's `Codable` types.

- ``NBTDecoder``
- ``NBTEncoder``
- ``NBTTag``
- ``TagDefinition``
- ``TagValue``

### Other Data Types

- ``JSONValue``
- ``VerticalAnchor``
