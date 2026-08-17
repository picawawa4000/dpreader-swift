# Structures

Structures are large points of interest that are generated in Minecraft worlds.

## Topics

### Structure Sets

Structure sets determine what structures get placed in the world and where.

- ``StructureSet``
- ``WeightedDirectStructurePoolAliasGroup``
- ``WeightedStructure``
- ``WeightedStructurePoolAliasTarget``

### Structure Types

Structure types determine what blocks make up a given structure.

- ``Structure``
- ``JigsawStructureSettings``
- ``MineshaftStructureSettings``
- ``MineshaftType``
- ``NetherFossilStructureSettings``
- ``OceanRuinStructureSettings``
- ``OceanRuinTemperature``
- ``RuinedPortalStructureSettings``
- ``RuinedPortalSetup``
- ``RuinedPortalPlacement``
- ``StructureSpawnOverride``
- ``StructureTerrainAdaptation``
- ``StructurePoolAlias``
- ``DirectStructurePoolAlias``
- ``RandomGroupStructurePoolAlias``
- ``RandomStructurePoolAlias``
- ``StructureSpawnBoundingBox``

### Structure Placements

Structure placements determine where structures are located in the world.

- ``StructurePlacementSampler``
- ``StructurePlacementSample``
- ``StructurePlacement``
- ``ConcentricRingsStructurePlacement``
- ``RandomSpreadStructurePlacement``
- ``RandomSpreadStructurePlacementFrequencyReductionMethod``
- ``RandomSpreadStructurePlacementSpreadType``
- ``StructureStartHeightmap``
- ``StructureStartValidationContext``
- ``StructurePlacementExclusionZone``
- ``StructureHeightProvider``
- ``ValidatedStructureStart``
- ``ResolvedStructurePlacementSample``

### Structure Templates

Structure templates are 3D volumes of blocks that are pasted into the world when loading most structures.

- ``StructureFile``
- ``StructureFileBlock``
- ``StructureFileEntity``
- ``StructureFilePaletteElement``
- ``StructureTemplate``
- ``StructureTemplateBlock``
- ``StructureTemplateEntity``
- ``StructureTemplateDecodingError``

### Structure Generation

These types are responsible for generating structures.

- ``StructureGenerationContext``
- ``StructureMarker``
- ``StructureBlockVolume``
- ``StructurePiece``
- ``StructureGenerationError``
- ``StructureGeneratedResult``
- ``PieceGraph``
- ``CardinalDirection``
- ``LocalDirection``
- ``DesertPyramid``
- ``DesertPyramidGenerationResult``
- ``DesertPyramidLootMarker``
- ``DesertPyramidPieceGraph``
- ``OceanMonument``
- ``OceanMonumentGenerationContext``
- ``OceanMonumentGenerationResult``
- ``OceanMonumentGraphPiece``
- ``OceanMonumentPieceGraph``
- ``OceanMonumentPieceKind``
- ``Stronghold``
- ``StrongholdGenerationResult``
- ``StrongholdLootChestMarker``
- ``StrongholdPieceGraph``
- ``WoodlandMansion``
- ``WoodlandMansionGenerationResult``
- ``WoodlandMansionLootChestMarker``
- ``WoodlandMansionRoomPlacement``
- ``WoodlandMansionPieceGraph``
