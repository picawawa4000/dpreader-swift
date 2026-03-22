# RULES.md

In theory, these guidelines are for AI coding agents. In practice, they are good conventions, and should be followed by all contributors.

---

## 1. Core Principles

- **Everything must match Minecraft exactly**
  - Unit test against the vanilla data.
  - In the future, we may also test against non-vanilla datapacks, but this is not the main concern right now.

- **Performance is critical**
  - Terrain generation is called frequently and must be optimized.
  - Prefer O(1) or O(n) solutions; avoid nested expensive operations where possible.

- **Memory efficiency matters**
  - Avoid unnecessary allocations.
  - Use value types (`struct`) where appropriate.
  - Reuse buffers when possible.

- **Thread safety is required**
  - Assume terrain generation may run in parallel.
  - Avoid shared mutable state unless explicitly synchronized.

---

## 2. Code Style (Swift)

- Follow standard Swift conventions:
  - `camelCase` for variables/functions
  - `PascalCase` for types
- Prefer:
  - `struct` over `class` unless reference semantics are required
  - `let` over `var` whenever possible
- Keep functions:
  - Small
  - Pure (no side effects unless necessary)
- Use explicit types in public APIs.

---

## 3. Architecture Rules

### 3.1 Modular Design

Split terrain generation into clear components, for example:

- **Noise Generation**
- **Density Functions**
- **Biome Lookup Tree**
- **Heightmap Generation**
- **Block Assignment**
- **Post-processing**

Each module must:

- Be independently testable
- Have a clear input/output contract

### 3.2 API Design

- Public API must be:
  - Predictable
  - Minimal
  - Well-documented

Example:

```swift
func generateChunk(at position: ChunkPosition, seed: Int64) -> Chunk
```

Avoid:

- Hidden global state
- Implicit dependencies

## 4. Chunk System

- Chunks must:
  - Be independent
  - Not require neighboring chunks to generate base terrain

- Avoid cross-chunk writes during generation.

## 5. Performance Constraints

- Avoid:
  - Recursion in hot paths
  - Dynamic dispatch in tight loops
- Prefer:
  - Inlineable functions
  - Precomputed lookup tables (when justified)

- Benchmark critical paths:
  - Noise sampling
  - Block assignment

## 6. Testing Requirements

- Every module must have unit tests

- There must be tests against vanilla data, which can be obtained either from the game or from xpple's fork of Cubiomes when possible

- Add snapshot tests for:
  - Chunks
  - Heightmaps

## 7. Debugging & Visualization

- Provide debug utilities:
  - Heightmap export
  - ASCII or image previews
  - Note: These should not be directly contained in DPReader, but should instead leverage its API. [MineScene](https://github.com/picawawa4000/minescene) is a good example.
- Avoid polluting production code with debug logic.

## 8. Error Handling

- Fail fast in development:
  - Use `assert` or `precondition` for impossible states
- In production:
  - Avoid crashes
  - Return safe defaults where appropriate

## 9. Documentation

- Every public function must include:
  - Description
  - Parameters
  - Thread-safety guarantees (where appropriate)

Example:

```swift
/// Generates terrain height for a given coordinate.
/// Concurrency-safe.
/// - Parameters:
///   - x: World X coordinate
///   - z: World Z coordinate
///   - seed: World seed
/// - Returns: Height value
```

## 10. What NOT to Do

- Don't use global mutable state  
- Don't couple unrelated systems  
- Don't optimize prematurely without measurement  
- Don't break chunk independence  

## 11. When Unsure

- Prefer:
  - Simplicity over cleverness
  - Determinism over realism
  - Readability over micro-optimizations (unless in hot paths)

- Ask:
  - “Will this produce the same result every time?”
  - “Can this scale to millions of blocks?”

## 12. Definition of Done

A feature is complete when:

- Tested  
- Documented  
- Performs within acceptable limits  
- Integrates cleanly with existing modules  
