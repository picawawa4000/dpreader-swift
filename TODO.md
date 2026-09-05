# TODO

These are generally small issues throughout the code. More specific issues will have a comment with `TODO:` at the beginning in the code.

## Blocks

- The `Block` class needs to be deleted, and `BlockState` needs to be replaced with `BlockStateDefinition` so that we can support non-vanilla blocks and stop relying on `Blocks`.

## Issues

- Post-113.0 noises are (most likely) not correct.

## Tests

- Loading & output tests for anything & everything related to loot.

## Optimisations

- World generators should only have to compile their functions once, not after every reseed.

## Cleanup

- De-vibecode-ify `VanillaChunkTerrainSampler.swift`, and merge it into `WorldGenerator.swift`.
- Do the same for the compiler (which is really quite a mess).
  - Specifically, the WASM runtime implementation is... not great.
