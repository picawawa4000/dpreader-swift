# TODO

These are generally small issues throughout the code. More specific issues will have a comment with `TODO:` at the beginning in the code.

## Extensions for Testing

These may not be possible, but if they are, they should be done because they would make the code cleaner.

- Replace all "visible for testing only" functions with extensions in the tests.
- Replace @TestVisible annotations with extensions in the tests (this one's particularly important, because then we won't have to depend on TestVisible anymore, which should expand the range of platforms we can declare support for).

## Tests

- Output tests for the caches (especially `minecraft:interpolated`) and `Beardifier`.
- Loading & output tests for `WeirdScaledSampler`.
- Loading tests for `InterpolatedNoise`.
- Loading & output tests for `SplineDensityFunction`.
- Loading & output tests for anything & everything related to loot.
