# Surface Rules

Surface rules define what blocks get placed on world surfaces.

Minecraft uses surface rules to implement biome-specific modifications to the surface of worlds, such as sand in deserts and snow in snowy biomes.

After generating raw terrain with ``WorldGenerator/generateInto(_:at:)``, call ``WorldGenerator/applySurfaceRules(to:at:)``. The chunk then exposes the selected materials through ``ProtoChunk/block(atLocal:)``. Carving remains a separate subsequent step.

## Topics

### Block Placers

- ``SurfaceRule``
- ``SurfaceRuleBandlands``
- ``SurfaceRuleBlock``
- ``SurfaceRuleSequence``

### Conditions

- ``SurfaceRuleCondition``
- ``SurfaceRuleAbovePreliminarySurface``
- ``SurfaceRuleBiomeCondition``
- ``SurfaceRuleConditionRule``
- ``SurfaceRuleHoleCondition``
- ``SurfaceRuleNoiseThresholdCondition``
- ``SurfaceRuleNotCondition``
- ``SurfaceRuleSteepCondition``
- ``SurfaceRuleStoneDepthCondition``
- ``SurfaceRuleStoneDepthSurfaceType``
- ``SurfaceRuleTemperatureCondition``
- ``SurfaceRuleVerticalGradientCondition``
- ``SurfaceRuleWaterCondition``
- ``SurfaceRuleYAboveCondition``

### Helpers

- ``SurfaceRuleConditionInitializer``
- ``SurfaceRuleInitializer``
