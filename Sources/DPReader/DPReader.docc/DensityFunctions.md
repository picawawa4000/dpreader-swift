# Density Functions

Density functions are functions used by Minecraft to obtain a number from a position.

Minecraft uses density functions for multiple purposes, and they are the most important world generation structure. Most notably, they are used to resolve biomes via the six climates (namely temperature, humidity, continentalness, erosion, depth, and weirdness) and to generate terrain via final density. A list of all density functions used by Minecraft can be found in the description of ``NoiseRouter``.

## Topics

### Basic Types

- ``DensityFunction``

### Density Function Types

- ``BeardifierMarker``
- ``BinaryDensityFunction``
- ``BlendAlpha``
- ``BlendDensity``
- ``BlendOffset``
- ``CacheMarker``
- ``ClampDensityFunction``
- ``ConstantDensityFunction``
- ``EndIslandsDensityFunction``
- ``FindTopSurface``
- ``InterpolatedNoise``
- ``NoiseDensityFunction``
- ``RangeChoice``
- ``ReferenceDensityFunction``
- ``ShiftDensityFunction``
- ``ShiftedNoise``
- ``SplineDensityFunction``
- ``UnaryDensityFunction``
- ``WeirdScaledSampler``
- ``YClampedGradient``

## Noise

Noise is the underlying method that Minecraft uses to turn coordinates into blocks. Almost all noise in Minecraft is routed through density functions.

- ``PerlinNoise``
- ``OctavePerlinNoise``
- ``DoublePerlinNoise``
- ``NoiseDefinition``
- ``ModernNoiseNormalization``
- ``SimplexNoise``

### Helpers

- ``DensityFunctionBaker``
- ``DensityFunctionNoise``
- ``BakedNoise``
- ``UnbakedNoise``
- ``DensityFunctionInitializer``
- ``DensityFunctionSimplexNoise``
- ``DensityFunctionDecodingError``
