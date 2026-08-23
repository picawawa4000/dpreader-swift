# TODO

These are generally small issues throughout the code. More specific issues will have a comment with `TODO:` at the beginning in the code.

## Blocks

- The `Block` class needs to be deleted, and `BlockState` needs to be replaced with `BlockStateDefinition` so that we can support non-vanilla blocks and stop relying on `Blocks`.

## Extensions for Testing

These may not be possible, but if they are, they should be done because they would make the code cleaner.

- Replace all "visible for testing only" functions with extensions in the tests.
- Replace @TestVisible annotations with extensions in the tests (this one's particularly important, because then we won't have to depend on TestVisible anymore, which should expand the range of platforms we can declare support for).

## Tests

- Loading & output tests for anything & everything related to loot.

## Optimisations

- World generators should only have to compile their functions once, not after every reseed.

## Cleanup

- De-vibecode-ify `VanillaChunkTerrainSampler.swift`, and merge it into `WorldGenerator.swift`.
- Do the same for the compiler (which is really quite a mess).
  - Specifically, the WASM runtime implementation is... not great.
