import Foundation

/// The generated state shared by all pool-based jigsaw structures.
public struct JigsawStructureGenerationResult {
    public let graph: PieceGraph
    public let blocks: StructureBlockVolume
    public let lootContainers: [StructureLootContainer]
}

/// A chunk which must be processed to reproduce jigsaw loot and its decorator RNG.
private struct JigsawLootChunk: Hashable, Comparable {
    let x: Int32
    let z: Int32

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.x == rhs.x ? lhs.z < rhs.z : lhs.x < rhs.x
    }
}

/// One selected pool element in a generated jigsaw graph.
public final class JigsawStructurePiece: StructurePiece {
    public let templateNames: [String]
    public let placementOrigin: PosInt3D
    public let rotationQuarterTurns: Int
    public let depth: Int

    fileprivate let element: StructurePoolElement
    fileprivate let context: StructureGenerationContext
    fileprivate let worldSeed: WorldSeed
    private var rotation: JigsawRotation { JigsawRotation(rawValue: self.rotationQuarterTurns)! }
    private(set) var generatedLootContainers: [StructureLootContainer] = []
    private var cachedLootCandidates: [JigsawLootCandidate]?
    override var cachesGeneratedContents: Bool { false }

    fileprivate init(
        element: StructurePoolElement,
        origin: PosInt3D,
        rotation: JigsawRotation,
        bounds: BoundingBox,
        depth: Int,
        context: StructureGenerationContext,
        worldSeed: WorldSeed
    ) {
        self.templateNames = element.templateLocations
        self.placementOrigin = origin
        self.rotationQuarterTurns = rotation.rawValue
        self.depth = depth
        self.element = element
        self.context = context
        self.worldSeed = worldSeed
        super.init(orientation: rotation.publicDirection, boundingBox: bounds)
    }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        for entry in self.element.singleEntries {
            let templateName = entry.location
            guard let template = self.context.structureTemplate(named: templateName) else { continue }
            let palette = template.palette(at: self.placementOrigin)
            let processors: [StructureProcessor]
            if case .registry(let name)? = entry.processors {
                processors = self.context.structureProcessorList(named: name)?.processors ?? []
            } else {
                processors = []
            }
            // Structure-template NBT stores blocks in vanilla's categorized order (full cubes,
            // dynamic blocks, then block entities). Capped processors shuffle indices in this
            // exact list, so re-sorting it changes which blocks are selected.
            var processed = template.blocks.compactMap { block -> JigsawProcessedBlock? in
                guard block.state >= 0, block.state < palette.count else { return nil }
                return JigsawProcessedBlock(block: block, state: palette[block.state])
            }
            for processor in processors {
                Self.apply(
                    processor: processor,
                    to: &processed,
                    placementOrigin: self.placementOrigin,
                    rotation: self.rotation,
                    worldSeed: self.worldSeed,
                    context: self.context
                )
            }
            for processedBlock in processed {
                let block = processedBlock.block
                var state = processedBlock.state
                let processorLootTable = processedBlock.lootTable
                let processorLootSeed = processedBlock.lootSeed
                let pos = self.rotation.transformed(block.pos).adding(self.placementOrigin)

                if state.id == "minecraft:structure_block" { continue }
                if state.id == "minecraft:jigsaw" {
                    guard let finalState = block.nbt?.compoundString("final_state"),
                          let replacement = Self.parseBlockState(finalState),
                          replacement.id != "minecraft:structure_void"
                    else { continue }
                    state = self.rotation.transformed(replacement)
                } else if !entry.legacy && state.isAir {
                    continue
                } else {
                    state = self.rotation.transformed(state)
                }

                let finalPos: PosInt3D
                if self.element.projection == .terrainMatching,
                   let surface = surfaceY(atX: pos.x, z: pos.z, context: self.context) {
                    finalPos = PosInt3D(x: pos.x, y: surface &- 1 &+ block.pos.y, z: pos.z)
                } else {
                    finalPos = pos
                }
                guard chunkBox.contains(finalPos) else { continue }
                world.setBlock(state, at: finalPos)

                if let table = processorLootTable ?? block.nbt?.compoundString("LootTable") {
                    let seed: Int64
                    if processorLootTable != nil && !Self.isLootableInventory(state.id) {
                        seed = processorLootSeed ?? 0
                    } else if Self.isLootableInventory(state.id) {
                        seed = Int64(bitPattern: random.nextLong())
                    } else {
                        seed = block.nbt?.compoundInt64("LootTableSeed") ?? 0
                    }
                    self.generatedLootContainers.append(StructureLootContainer(block: state.id, pos: finalPos, lootTable: table, lootSeed: seed))
                }
            }
        }
    }

    private static func apply(
        processor: StructureProcessor,
        to blocks: inout [JigsawProcessedBlock],
        placementOrigin: PosInt3D,
        rotation: JigsawRotation,
        worldSeed: WorldSeed,
        context: StructureGenerationContext
    ) {
        switch processor {
        case .protectedBlocks(_):
            return
        case .blockRot(let integrity, let rottableBlocks):
            blocks.removeAll { block in
                if let rottableBlocks {
                    let tag = rottableBlocks.first == "#" ? String(rottableBlocks.dropFirst()) : rottableBlocks
                    guard context.block(block.state.id, isInTag: tag) else { return false }
                }
                let pos = rotation.transformed(block.block.pos).adding(placementOrigin)
                var positionalRandom = self.positionalRandom(at: pos)
                return positionalRandom.nextFloat() > integrity
            }
        case .rule(let rules):
            for index in blocks.indices {
                _ = self.apply(rules: rules, to: &blocks[index], placementOrigin: placementOrigin, rotation: rotation, context: context)
            }
        case .capped(let limit, let delegate):
            guard limit > 0, !blocks.isEmpty else { return }
            var seedRandom = CheckedRandom(seed: worldSeed)
            var cappedRandom = seedRandom.nextSplitter().split(usingPos: placementOrigin)
            var indices = Array(blocks.indices)
            if indices.count > 1 {
                for index in stride(from: indices.count - 1, through: 1, by: -1) {
                    indices.swapAt(index, Int(cappedRandom.next(bound: UInt32(index + 1))))
                }
            }
            var changed = 0
            for index in indices where changed < min(limit, blocks.count) {
                let old = blocks[index]
                switch delegate.value {
                case .rule(let rules):
                    _ = self.apply(rules: rules, to: &blocks[index], placementOrigin: placementOrigin, rotation: rotation, context: context)
                default: break
                }
                if blocks[index] != old { changed += 1 }
            }
        }
    }

    @discardableResult
    private static func apply(
        rules: [StructureProcessorRule],
        to block: inout JigsawProcessedBlock,
        placementOrigin: PosInt3D,
        rotation: JigsawRotation,
        context: StructureGenerationContext
    ) -> Bool {
        let pos = rotation.transformed(block.block.pos).adding(placementOrigin)
        var positionalRandom = self.positionalRandom(at: pos)
        for rule in rules {
            guard rule.inputPredicate.matches(block.state, context: context, random: &positionalRandom) else { continue }
            block.state = rule.outputState.blockState
            if let table = rule.lootTable {
                block.lootTable = addDefaultNamespace(table)
                block.lootSeed = Int64(bitPattern: positionalRandom.nextLong())
            }
            return true
        }
        return false
    }

    private static func positionalRandom(at position: PosInt3D) -> CheckedRandom {
        let xProduct = position.x &* 3_129_871
        var seed = Int64(xProduct) ^ (Int64(position.z) &* 116_129_781) ^ Int64(position.y)
        seed = seed &* seed &* 42_317_861 &+ seed &* 11
        return CheckedRandom(seed: UInt64(bitPattern: seed >> 16))
    }

    private static func isLootableInventory(_ id: String) -> Bool {
        id == "minecraft:chest"
            || id == "minecraft:barrel"
            || id == "minecraft:dispenser"
            || id == "minecraft:hopper"
            || id == "minecraft:decorated_pot"
            // Copper chests were added with abandoned camps. Like regular chests,
            // their LootTableSeed is assigned by structure placement rather than
            // being taken from the template/processor default.
            || id == "minecraft:copper_chest"
            || id == "minecraft:exposed_copper_chest"
            || id == "minecraft:weathered_copper_chest"
            || id == "minecraft:oxidized_copper_chest"
            || id == "minecraft:waxed_copper_chest"
            || id == "minecraft:waxed_exposed_copper_chest"
            || id == "minecraft:waxed_weathered_copper_chest"
            || id == "minecraft:waxed_oxidized_copper_chest"
    }

    fileprivate func templateLootContainers() -> [StructureLootContainer] {
        var result: [StructureLootContainer] = []
        for templateName in self.templateNames {
            guard let template = self.context.structureTemplate(named: templateName) else { continue }
            let palette = template.palette(at: self.placementOrigin)
            for block in template.blocks {
                guard block.state >= 0, block.state < palette.count,
                      let table = block.nbt?.compoundString("LootTable")
                else { continue }
                let state = palette[block.state]
                var pos = self.rotation.transformed(block.pos).adding(self.placementOrigin)
                if self.element.projection == .terrainMatching,
                   let surface = surfaceY(atX: pos.x, z: pos.z, context: self.context) {
                    pos = PosInt3D(x: pos.x, y: surface &- 1 &+ block.pos.y, z: pos.z)
                }
                result.append(StructureLootContainer(
                    block: state.id,
                    pos: pos,
                    lootTable: table,
                    lootSeed: block.nbt?.compoundInt64("LootTableSeed") ?? 0
                ))
            }
        }
        return result
    }

    /// Resolves the only blocks which can affect loot. Processors are included because
    /// rule processors can attach loot tables to ordinary template blocks. The result is
    /// cached because chunk discovery and the actual loot pass need the same information.
    private func lootCandidates() -> [JigsawLootCandidate] {
        if let cachedLootCandidates { return cachedLootCandidates }
        var candidates: [JigsawLootCandidate] = []
        for entry in self.element.singleEntries {
            guard let template = self.context.structureTemplate(named: entry.location) else { continue }
            let processors: [StructureProcessor]
            if case .registry(let name)? = entry.processors {
                processors = self.context.structureProcessorList(named: name)?.processors ?? []
            } else {
                processors = []
            }
            let hasTemplateLoot = template.blocks.contains { $0.nbt?.compoundString("LootTable") != nil }
            let hasProcessorLoot = processors.contains { $0.canAttachLoot }
            guard hasTemplateLoot || hasProcessorLoot else { continue }
            let palette = template.palette(at: self.placementOrigin)
            // A capped processor chooses from every template block, and a loot-bearing rule
            // can affect every block. Otherwise only the template's existing loot blocks can
            // affect the result, so do not construct or process the rest of the template.
            let sourceBlocks: [StructureTemplateBlock]
            if hasProcessorLoot || processors.contains(where: { $0.requiresFullTemplateForLoot }) {
                sourceBlocks = template.blocks
            } else {
                sourceBlocks = template.blocks.filter { $0.nbt?.compoundString("LootTable") != nil }
            }
            var processed = sourceBlocks.compactMap { block -> JigsawProcessedBlock? in
                guard block.state >= 0, block.state < palette.count else { return nil }
                return JigsawProcessedBlock(block: block, state: palette[block.state])
            }
            for processor in processors {
                Self.apply(
                    processor: processor,
                    to: &processed,
                    placementOrigin: self.placementOrigin,
                    rotation: self.rotation,
                    worldSeed: self.worldSeed,
                    context: self.context
                )
            }
            for processedBlock in processed {
                let block = processedBlock.block
                guard processedBlock.lootTable != nil || block.nbt?.compoundString("LootTable") != nil else {
                    continue
                }
                var state = processedBlock.state
                let pos = self.rotation.transformed(block.pos).adding(self.placementOrigin)

                if state.id == "minecraft:structure_block" { continue }
                if state.id == "minecraft:jigsaw" {
                    guard let finalState = block.nbt?.compoundString("final_state"),
                          let replacement = Self.parseBlockState(finalState),
                          replacement.id != "minecraft:structure_void"
                    else { continue }
                    state = self.rotation.transformed(replacement)
                } else if !entry.legacy && state.isAir {
                    continue
                } else {
                    state = self.rotation.transformed(state)
                }

                let finalPos: PosInt3D
                if self.element.projection == .terrainMatching,
                   let surface = surfaceY(atX: pos.x, z: pos.z, context: self.context) {
                    finalPos = PosInt3D(x: pos.x, y: surface &- 1 &+ block.pos.y, z: pos.z)
                } else {
                    finalPos = pos
                }
                candidates.append(JigsawLootCandidate(
                    state: state,
                    pos: finalPos,
                    lootTable: processedBlock.lootTable ?? block.nbt!.compoundString("LootTable")!,
                    processorLootSeed: processedBlock.lootSeed,
                    templateLootSeed: block.nbt?.compoundInt64("LootTableSeed") ?? 0
                ))
            }
        }
        self.cachedLootCandidates = candidates
        return candidates
    }

    /// Finds chunks in which this piece can create a loot container. All processor
    /// randomness used here is positional, so this discovery pass does not consume the
    /// shared chunk decoration RNG.
    fileprivate func lootChunks() -> Set<JigsawLootChunk> {
        Set(self.lootCandidates().map { JigsawLootChunk(x: $0.pos.x >> 4, z: $0.pos.z >> 4) })
    }

    /// Reproduces just the shared decoration-RNG calls and container markers in a chunk.
    /// Non-loot blocks cannot affect either, so writing them is unnecessary for loot lookup.
    fileprivate func generateLoot<R: Random>(in chunkBox: BoundingBox, random: inout R) {
        for candidate in self.lootCandidates() where chunkBox.contains(candidate.pos) {
            let seed: Int64
            if candidate.processorLootSeed != nil && !Self.isLootableInventory(candidate.state.id) {
                seed = candidate.processorLootSeed ?? 0
            } else if Self.isLootableInventory(candidate.state.id) {
                seed = Int64(bitPattern: random.nextLong())
            } else {
                seed = candidate.templateLootSeed
            }
            self.generatedLootContainers.append(StructureLootContainer(
                block: candidate.state.id,
                pos: candidate.pos,
                lootTable: candidate.lootTable,
                lootSeed: seed
            ))
        }
    }

    private static func parseBlockState(_ value: String) -> BlockState? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let bracket = trimmed.firstIndex(of: "[") else {
            return BlockState(id: addDefaultNamespace(trimmed))
        }
        let name = String(trimmed[..<bracket])
        guard trimmed.last == "]" else { return nil }
        let body = trimmed[trimmed.index(after: bracket)..<trimmed.index(before: trimmed.endIndex)]
        var properties: [String: String] = [:]
        for assignment in body.split(separator: ",") {
            let pair = assignment.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { return nil }
            properties[String(pair[0])] = String(pair[1])
        }
        return BlockState(id: addDefaultNamespace(name), properties: properties)
    }
}

/// Vanilla-compatible structure-pool assembly for villages, outposts, bastions,
/// ancient cities, trail ruins, and trial chambers.
enum JigsawStructure {
    /// Collects the tables reachable from a jigsaw's pool graph without assembling a
    /// structure. This deliberately visits every weighted element: a structure start
    /// chooses only one path, while item listing describes all possible starts.
    static func lootTables(settings: JigsawStructureSettings, context: StructureGenerationContext) -> Set<String> {
        var tables: Set<String> = []
        var pendingPools = [settings.startPool]
        var visitedPools: Set<String> = []

        while let poolName = pendingPools.popLast() {
            let normalizedPool = addDefaultNamespace(poolName)
            guard visitedPools.insert(normalizedPool).inserted,
                  let pool = context.structureTemplatePool(named: normalizedPool)
            else { continue }
            pendingPools.append(pool.fallback)

            for weightedElement in pool.elements {
                for entry in weightedElement.element.singleEntries {
                    if let template = context.structureTemplate(named: entry.location) {
                        for block in template.blocks {
                            if let table = block.nbt?.compoundString("LootTable") {
                                tables.insert(addDefaultNamespace(table))
                            }
                            if let childPool = block.nbt?.compoundString("pool") {
                                pendingPools.append(childPool)
                            }
                        }
                    }
                    if case .registry(let name)? = entry.processors {
                        for processor in context.structureProcessorList(named: name)?.processors ?? [] {
                            tables.formUnion(processor.possibleLootTables)
                        }
                    }
                }
            }
        }
        return tables
    }

    static func generatePieceGraph(
        settings: JigsawStructureSettings,
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) -> PieceGraph? {
        var generator = JigsawAssembler(settings: settings, worldSeed: worldSeed, startChunk: startChunk, context: context)
        return generator.generate()
    }

    static func generate(
        settings: JigsawStructureSettings,
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) -> JigsawStructureGenerationResult? {
        guard let graph = self.generatePieceGraph(settings: settings, worldSeed: worldSeed, startChunk: startChunk, context: context) else {
            return nil
        }
        let volume = StructureBlockVolume(bounds: graph.boundingBox, fallbackSampler: context.blockSampler)
        let world = StructureWorldView(seaLevel: context.seaLevel, minimumWorldY: context.minimumWorldY, volume: volume)
        let decoration = context.jigsawDecorationParameters(startPool: settings.startPool) ?? StructureDecorationParameters(step: 0, index: 0)
        for chunkZ in (graph.boundingBox.minZ >> 4)...(graph.boundingBox.maxZ >> 4) {
            for chunkX in (graph.boundingBox.minX >> 4)...(graph.boundingBox.maxX >> 4) {
                let chunkBox = BoundingBox(
                    minX: chunkX &* 16, minY: context.minimumWorldY, minZ: chunkZ &* 16,
                    maxX: chunkX &* 16 &+ 15, maxY: context.maximumWorldY, maxZ: chunkZ &* 16 &+ 15
                )
                var random = getStructureGenerationRandom(
                    worldSeed: worldSeed, chunkX: chunkX, chunkZ: chunkZ,
                    decoratorIndex: decoration.index, decoratorStep: decoration.step
                )
                for piece in graph.pieces where piece.boundingBox.intersects(chunkBox) {
                    piece.write(in: world, chunkBox: chunkBox, random: &random)
                }
            }
        }
        let loot = graph.pieces.compactMap { $0 as? JigsawStructurePiece }.flatMap(\.generatedLootContainers)
        return JigsawStructureGenerationResult(graph: graph, blocks: volume, lootContainers: loot)
    }

    /// Generates only chunks and pieces which can contribute a loot container.
    /// A jigsaw template's only shared chunk-decoration RNG use is assigning a
    /// seed to a lootable inventory. Therefore, in each selected chunk we retain
    /// every piece that can create loot there, in graph order, and omit all others.
    static func generateLoot(
        settings: JigsawStructureSettings,
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) -> [StructureLootContainer]? {
        guard let graph = self.generatePieceGraph(settings: settings, worldSeed: worldSeed, startChunk: startChunk, context: context) else {
            return nil
        }
        let pieces = graph.pieces.compactMap { $0 as? JigsawStructurePiece }
        var piecesByChunk: [JigsawLootChunk: [JigsawStructurePiece]] = [:]
        for piece in pieces {
            for chunk in piece.lootChunks() {
                // Pieces are appended in graph order, matching the full-generation pass.
                piecesByChunk[chunk, default: []].append(piece)
            }
        }
        let decoration = context.jigsawDecorationParameters(startPool: settings.startPool) ?? StructureDecorationParameters(step: 0, index: 0)

        for chunk in piecesByChunk.keys.sorted() {
            let chunkBox = BoundingBox(
                minX: chunk.x &* 16, minY: context.minimumWorldY, minZ: chunk.z &* 16,
                maxX: chunk.x &* 16 &+ 15, maxY: context.maximumWorldY, maxZ: chunk.z &* 16 &+ 15
            )
            var random = getStructureGenerationRandom(
                worldSeed: worldSeed, chunkX: chunk.x, chunkZ: chunk.z,
                decoratorIndex: decoration.index, decoratorStep: decoration.step
            )
            for piece in piecesByChunk[chunk]! {
                piece.generateLoot(in: chunkBox, random: &random)
            }
        }
        return pieces.flatMap(\.generatedLootContainers)
    }
}

private struct JigsawAssembler {
    let settings: JigsawStructureSettings
    let worldSeed: WorldSeed
    let startChunk: PosInt2D
    let context: StructureGenerationContext
    var random: CheckedRandom
    var aliases: [String: String]
    var pieces: [JigsawStructurePiece] = []
    var queue: [QueuedPiece] = []
    var queueSequence = 0
    var orderedTemplateBlocks: [String: [StructureTemplateBlock]] = [:]
    var highestPoolElementHeights: [String: Int32] = [:]

    init(settings: JigsawStructureSettings, worldSeed: WorldSeed, startChunk: PosInt2D, context: StructureGenerationContext) {
        self.settings = settings
        self.worldSeed = worldSeed
        self.startChunk = startChunk
        self.context = context
        self.random = checkedRandomForChunkGeneration(worldSeed: worldSeed, chunkX: startChunk.x, chunkZ: startChunk.z)
        let startY = settings.startHeight.constantValue(minimumWorldY: context.minimumWorldY, maximumWorldY: context.maximumWorldY)
        let aliasPos = PosInt3D(x: startChunk.x &* 16, y: startY ?? 0, z: startChunk.z &* 16)
        self.aliases = Self.makeAliases(settings.poolAliases ?? [], worldSeed: worldSeed, pos: aliasPos)
    }

    mutating func generate() -> PieceGraph? {
        let startX = self.startChunk.x &* 16
        let startZ = self.startChunk.z &* 16
        let sampledY = self.settings.startHeight.sample(
            random: &self.random,
            minimumWorldY: self.context.minimumWorldY,
            maximumWorldY: self.context.maximumWorldY
        )
        // Alias lookup uses the sampled start position but an independent RNG stream.
        self.aliases = Self.makeAliases(
            self.settings.poolAliases ?? [],
            worldSeed: self.worldSeed,
            pos: PosInt3D(x: startX, y: sampledY, z: startZ)
        )
        let rotation = JigsawRotation(rawValue: Int(self.random.next(bound: 4)))!
        let startPoolName = self.resolveAlias(self.settings.startPool)
        guard let startPool = self.context.structureTemplatePool(named: startPoolName),
              let rootElement = self.randomElement(from: startPool),
              !rootElement.isEmpty
        else { return nil }

        let requestedPos = PosInt3D(x: startX, y: sampledY, z: startZ)
        let initialOrigin: PosInt3D
        if let startName = self.settings.startJigsawName {
            let infos = self.jigsaws(in: rootElement, origin: requestedPos, rotation: rotation)
            guard let selected = infos.first(where: { $0.name == startName }) else { return nil }
            let relative = selected.pos.subtracting(requestedPos)
            initialOrigin = requestedPos.subtracting(relative)
        } else {
            initialOrigin = requestedPos
        }
        guard var rootBounds = self.bounds(of: rootElement, origin: initialOrigin, rotation: rotation) else { return nil }
        // Java integer division truncates toward zero here, including for negative coordinates.
        let centerX = (rootBounds.minX &+ rootBounds.maxX) / 2
        let centerZ = (rootBounds.minZ &+ rootBounds.maxZ) / 2
        let projectedY: Int32
        if self.settings.projectStartToHeightmap != nil {
            guard let terrainY = surfaceY(atX: centerX, z: centerZ, context: self.context) else { return nil }
            projectedY = sampledY &+ terrainY
        } else {
            projectedY = initialOrigin.y
        }
        let rootGroundY = rootBounds.minY &+ rootElement.groundLevelDelta
        let dy = projectedY &- rootGroundY
        let rootOrigin = initialOrigin.adding(PosInt3D(x: 0, y: dy, z: 0))
        rootBounds.move(0, dy, 0)

        let bottomPadding = Int32(self.settings.dimensionPadding ?? 0)
        let topPadding = Int32(self.settings.dimensionTopPadding ?? self.settings.dimensionPadding ?? 0)
        guard rootBounds.minY >= self.context.minimumWorldY &+ bottomPadding,
              rootBounds.maxY <= self.context.maximumWorldY &- topPadding
        else { return nil }

        let root = JigsawStructurePiece(
            element: rootElement,
            origin: rootOrigin,
            rotation: rotation,
            bounds: rootBounds,
            depth: 0,
            context: self.context,
            worldSeed: self.worldSeed
        )
        self.pieces.append(root)

        if self.settings.size > 0 {
            let relativeY = requestedPos.y &- initialOrigin.y
            let centerY = projectedY &+ relativeY
            let horizontalDistance = Int32(self.settings.maxDistanceFromCenter)
            let verticalDistance = Int32(self.settings.maxVerticalDistanceFromCenter)
            let boundary = BoundingBox(
                minX: centerX &- horizontalDistance,
                minY: max(centerY &- verticalDistance, self.context.minimumWorldY &+ bottomPadding),
                minZ: centerZ &- horizontalDistance,
                maxX: centerX &+ horizontalDistance,
                maxY: min(centerY &+ verticalDistance, self.context.maximumWorldY &- topPadding),
                maxZ: centerZ &+ horizontalDistance
            )
            let externalShape = JigsawShape(boundary: boundary, occupied: [rootBounds])
            self.expand(piece: root, shape: externalShape, depth: 0)
            while let next = self.dequeue() {
                self.expand(piece: next.piece, shape: next.shape, depth: next.depth)
            }
        }

        guard let combined = self.pieces.map(\.boundingBox).reduce(nil, { partial, box in
            partial.map { $0.union(box) } ?? box
        }) else { return nil }
        return PieceGraph(startChunk: self.startChunk, orientation: rotation.publicDirection, boundingBox: combined, pieces: self.pieces)
    }

    private mutating func expand(piece: JigsawStructurePiece, shape: JigsawShape, depth: Int) {
        let sourceRigid = piece.element.projection == .rigid
        let pieceMinY = piece.boundingBox.minY
        var internalShape: JigsawShape?

        for source in self.jigsaws(in: piece.element, origin: piece.placementOrigin, rotation: JigsawRotation(rawValue: piece.rotationQuarterTurns)!) {
            let connectionPos = source.pos.offset(source.facing)
            let sourceRelativeY = source.pos.y &- pieceMinY
            let targetShape: JigsawShape
            if piece.boundingBox.contains(connectionPos) {
                if internalShape == nil { internalShape = JigsawShape(boundary: piece.boundingBox, occupied: []) }
                targetShape = internalShape!
            } else {
                targetShape = shape
            }
            guard let pool = self.context.structureTemplatePool(named: self.resolveAlias(source.pool)),
                  let fallback = self.context.structureTemplatePool(named: self.resolveAlias(pool.fallback))
            else { continue }

            var candidates: [StructurePoolElement] = []
            if depth != self.settings.size { candidates += self.shuffledElements(of: pool) }
            candidates += self.shuffledElements(of: fallback)
            var attached = false
            let surfaceAtConnector = sourceRigid ? nil : surfaceY(atX: source.pos.x, z: source.pos.z, context: self.context)

            for candidate in candidates {
                if candidate.isEmpty { break }
                for candidateRotation in self.randomRotationOrder() {
                    guard var unshiftedBounds = self.bounds(of: candidate, origin: .zero, rotation: candidateRotation) else { continue }
                    let candidateInfos = self.jigsaws(in: candidate, origin: .zero, rotation: candidateRotation)
                    let expansion = self.expansionHeight(bounds: unshiftedBounds, jigsaws: candidateInfos)

                    for target in candidateInfos where source.attaches(to: target) {
                        let unshiftedTarget = target.pos
                        let origin = connectionPos.subtracting(unshiftedTarget)
                        unshiftedBounds = self.bounds(of: candidate, origin: origin, rotation: candidateRotation)!
                        let candidateMinY = unshiftedBounds.minY
                        let targetRelativeY = unshiftedTarget.y
                        let deltaY = sourceRelativeY &- targetRelativeY &+ source.facing.stepY
                        let placementY: Int32
                        if sourceRigid && candidate.projection == .rigid {
                            placementY = pieceMinY &+ deltaY
                        } else {
                            guard let surface = surfaceAtConnector ?? surfaceY(atX: source.pos.x, z: source.pos.z, context: self.context) else { continue }
                            placementY = surface &- targetRelativeY
                        }
                        let shiftY = placementY &- candidateMinY
                        let shiftedOrigin = origin.adding(PosInt3D(x: 0, y: shiftY, z: 0))
                        var collisionBounds = unshiftedBounds
                        collisionBounds.move(0, shiftY, 0)
                        if expansion > 0 {
                            let expandedHeight = max(expansion &+ 1, collisionBounds.maxY &- collisionBounds.minY)
                            collisionBounds.maxY = max(collisionBounds.maxY, collisionBounds.minY &+ expandedHeight)
                        }
                        guard targetShape.canFit(collisionBounds) else { continue }
                        targetShape.add(collisionBounds)

                        let child = JigsawStructurePiece(
                            element: candidate,
                            origin: shiftedOrigin,
                            rotation: candidateRotation,
                            bounds: collisionBounds,
                            depth: depth + 1,
                            context: self.context,
                            worldSeed: self.worldSeed
                        )
                        self.pieces.append(child)
                        if depth + 1 <= self.settings.size {
                            self.enqueue(child, shape: targetShape, depth: depth + 1, priority: source.placementPriority)
                        }
                        attached = true
                        break
                    }
                    if attached { break }
                }
                if attached { break }
            }
        }
    }

    private mutating func expansionHeight(bounds: BoundingBox, jigsaws: [JigsawInfo]) -> Int32 {
        guard self.settings.useExpansionHack, bounds.maxY &- bounds.minY &+ 1 <= 16 else { return 0 }
        var maximum: Int32 = 0
        for info in jigsaws {
            let poolName = self.resolveAlias(info.pool)
            guard bounds.contains(info.pos.offset(info.facing)),
                  let pool = self.context.structureTemplatePool(named: poolName)
            else { continue }
            maximum = max(maximum, self.highestElementHeight(in: pool, named: poolName))
            let fallbackName = self.resolveAlias(pool.fallback)
            if let fallback = self.context.structureTemplatePool(named: fallbackName) {
                maximum = max(maximum, self.highestElementHeight(in: fallback, named: fallbackName))
            }
        }
        return maximum
    }

    private mutating func highestElementHeight(in pool: StructureTemplatePool, named name: String) -> Int32 {
        if let cached = self.highestPoolElementHeights[name] { return cached }
        let height = pool.elements.compactMap { self.bounds(of: $0.element, origin: .zero, rotation: .none) }
            .map { $0.maxY &- $0.minY &+ 1 }.max() ?? 0
        self.highestPoolElementHeights[name] = height
        return height
    }

    private mutating func randomElement(from pool: StructureTemplatePool) -> StructurePoolElement? {
        let total = pool.elements.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var index = Int(self.random.next(bound: UInt32(total)))
        for entry in pool.elements {
            if index < entry.weight { return entry.element }
            index -= entry.weight
        }
        return nil
    }

    private mutating func shuffledElements(of pool: StructureTemplatePool) -> [StructurePoolElement] {
        var values = pool.elements.flatMap { Array(repeating: $0.element, count: $0.weight) }
        self.shuffle(&values)
        return values
    }

    private mutating func randomRotationOrder() -> [JigsawRotation] {
        var values = JigsawRotation.allCases
        self.shuffle(&values)
        return values
    }

    private mutating func shuffle<T>(_ values: inout [T]) {
        guard values.count > 1 else { return }
        for index in stride(from: values.count - 1, through: 1, by: -1) {
            values.swapAt(index, Int(self.random.next(bound: UInt32(index + 1))))
        }
    }

    private mutating func jigsaws(in element: StructurePoolElement, origin: PosInt3D, rotation: JigsawRotation) -> [JigsawInfo] {
        var values = self.jigsawsUnshuffled(in: element, origin: origin, rotation: rotation)
        self.shuffle(&values)
        return values.enumerated().sorted {
            if $0.element.selectionPriority != $1.element.selectionPriority {
                return $0.element.selectionPriority > $1.element.selectionPriority
            }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    private mutating func jigsawsUnshuffled(in element: StructurePoolElement, origin: PosInt3D, rotation: JigsawRotation) -> [JigsawInfo] {
        switch element {
        case .single(let location, _, _, _, _):
            guard let template = self.context.structureTemplate(named: location) else { return [] }
            let palette = template.palette(at: origin)
            // Vanilla's palette categorization sorts the template-local NBT block list before
            // rotation. Rotation transforms coordinates but does not re-sort that list; preserving
            // the local order is significant because the subsequent shuffle consumes it directly.
            let locallyOrderedBlocks: [StructureTemplateBlock]
            if let cached = self.orderedTemplateBlocks[location] {
                locallyOrderedBlocks = cached
            } else {
                let ordered = template.blocks.sorted {
                    if $0.pos.y != $1.pos.y { return $0.pos.y < $1.pos.y }
                    if $0.pos.x != $1.pos.x { return $0.pos.x < $1.pos.x }
                    return $0.pos.z < $1.pos.z
                }
                self.orderedTemplateBlocks[location] = ordered
                locallyOrderedBlocks = ordered
            }
            return locallyOrderedBlocks.compactMap { block in
                guard block.state >= 0, block.state < palette.count else { return nil }
                let state = palette[block.state]
                guard state.id == "minecraft:jigsaw", let orientation = state.properties?["orientation"],
                      let directions = JigsawDirections(rawValue: orientation)
                else { return nil }
                let joint: JigsawJoint
                if let encodedJoint = block.nbt?.compoundString("joint") {
                    joint = encodedJoint == "rollable" ? .rollable : .aligned
                } else {
                    joint = directions.facing.isVertical ? .rollable : .aligned
                }
                return JigsawInfo(
                    pos: rotation.transformed(block.pos).adding(origin),
                    facing: rotation.transformed(directions.facing),
                    top: rotation.transformed(directions.top),
                    joint: joint,
                    name: addDefaultNamespace(block.nbt?.compoundString("name") ?? "empty"),
                    pool: addDefaultNamespace(block.nbt?.compoundString("pool") ?? "empty"),
                    target: addDefaultNamespace(block.nbt?.compoundString("target") ?? "empty"),
                    placementPriority: Int(block.nbt?.compoundInt32("placement_priority") ?? 0),
                    selectionPriority: Int(block.nbt?.compoundInt32("selection_priority") ?? 0)
                )
            }
        case .list(let elements, _):
            guard let first = elements.first else { return [] }
            return self.jigsawsUnshuffled(in: first, origin: origin, rotation: rotation)
        case .feature:
            return [JigsawInfo(pos: origin, facing: .down, top: rotation.transformed(.south), joint: .rollable, name: "minecraft:bottom", pool: "minecraft:empty", target: "minecraft:empty", placementPriority: 0, selectionPriority: 0)]
        case .empty:
            return []
        }
    }

    private func bounds(of element: StructurePoolElement, origin: PosInt3D, rotation: JigsawRotation) -> BoundingBox? {
        switch element {
        case .single(let location, _, _, _, _):
            guard let template = self.context.structureTemplate(named: location) else { return nil }
            return rotation.bounds(size: template.size, origin: origin)
        case .list(let elements, _):
            return elements.compactMap { self.bounds(of: $0, origin: origin, rotation: rotation) }.reduce(nil) { result, box in
                result.map { $0.union(box) } ?? box
            }
        case .feature:
            return BoundingBox(minX: origin.x, minY: origin.y, minZ: origin.z, maxX: origin.x, maxY: origin.y, maxZ: origin.z)
        case .empty:
            return nil
        }
    }

    private func resolveAlias(_ name: String) -> String { self.aliases[addDefaultNamespace(name)] ?? addDefaultNamespace(name) }

    private mutating func enqueue(_ piece: JigsawStructurePiece, shape: JigsawShape, depth: Int, priority: Int) {
        self.queue.append(QueuedPiece(piece: piece, shape: shape, depth: depth, priority: priority, sequence: self.queueSequence))
        self.queueSequence += 1
        var index = self.queue.count - 1
        while index > 0 {
            let parent = (index - 1) >> 1
            guard Self.precedes(self.queue[index], self.queue[parent]) else { break }
            self.queue.swapAt(index, parent)
            index = parent
        }
    }

    private mutating func dequeue() -> QueuedPiece? {
        guard !self.queue.isEmpty else { return nil }
        if self.queue.count == 1 { return self.queue.removeLast() }
        let next = self.queue[0]
        self.queue[0] = self.queue.removeLast()
        var index = 0
        while true {
            let left = index * 2 + 1
            guard left < self.queue.count else { break }
            let right = left + 1
            let child = right < self.queue.count && Self.precedes(self.queue[right], self.queue[left]) ? right : left
            guard Self.precedes(self.queue[child], self.queue[index]) else { break }
            self.queue.swapAt(index, child)
            index = child
        }
        return next
    }

    private static func precedes(_ lhs: QueuedPiece, _ rhs: QueuedPiece) -> Bool {
        lhs.priority != rhs.priority ? lhs.priority > rhs.priority : lhs.sequence < rhs.sequence
    }

    private static func makeAliases(_ bindings: [StructurePoolAlias], worldSeed: WorldSeed, pos: PosInt3D) -> [String: String] {
        guard !bindings.isEmpty else { return [:] }
        var seedRandom = CheckedRandom(seed: worldSeed)
        let splitter = seedRandom.nextSplitter()
        var random = splitter.split(usingPos: pos)
        var result: [String: String] = [:]
        for binding in bindings { binding.apply(to: &result, random: &random) }
        return result
    }
}

private final class JigsawShape {
    let boundary: BoundingBox
    private var occupied: [BoundingBox]
    private var occupiedByChunk: [JigsawShapeChunk: [Int]] = [:]

    init(boundary: BoundingBox, occupied: [BoundingBox]) {
        self.boundary = boundary
        self.occupied = []
        for box in occupied { self.add(box) }
    }

    func add(_ box: BoundingBox) {
        let index = self.occupied.count
        self.occupied.append(box)
        for z in floorDiv(box.minZ, by: 16)...floorDiv(box.maxZ, by: 16) {
            for x in floorDiv(box.minX, by: 16)...floorDiv(box.maxX, by: 16) {
                self.occupiedByChunk[JigsawShapeChunk(x: x, z: z), default: []].append(index)
            }
        }
    }

    func canFit(_ box: BoundingBox) -> Bool {
        guard self.boundary.contains(PosInt3D(x: box.minX, y: box.minY, z: box.minZ)),
              self.boundary.contains(PosInt3D(x: box.maxX, y: box.maxY, z: box.maxZ))
        else { return false }

        // Collision is strictly local in the horizontal plane. Indexing occupied boxes by
        // chunk avoids a full scan of a large village or chamber for every candidate.
        var checked: Set<Int> = []
        for z in floorDiv(box.minZ, by: 16)...floorDiv(box.maxZ, by: 16) {
            for x in floorDiv(box.minX, by: 16)...floorDiv(box.maxX, by: 16) {
                for index in self.occupiedByChunk[JigsawShapeChunk(x: x, z: z), default: []]
                where checked.insert(index).inserted {
                    if self.occupied[index].intersects(box) { return false }
                }
            }
        }
        return true
    }
}

private struct JigsawShapeChunk: Hashable {
    let x: Int32
    let z: Int32
}

private extension StructureProcessor {
    var possibleLootTables: Set<String> {
        switch self {
        case .rule(let rules):
            return Set(rules.compactMap(\.lootTable).map(addDefaultNamespace))
        case .capped(_, let delegate):
            return delegate.value.possibleLootTables
        case .blockRot, .protectedBlocks:
            return []
        }
    }

    /// Whether applying this processor can attach a loot table to a block.
    var canAttachLoot: Bool {
        switch self {
        case .rule(let rules):
            return rules.contains { $0.lootTable != nil }
        case .capped(_, let delegate):
            return delegate.value.canAttachLoot
        case .blockRot, .protectedBlocks:
            return false
        }
    }

    /// Capped processors choose indices from the full template, so even a rule which
    /// never adds loot can change whether an existing container remains present.
    var requiresFullTemplateForLoot: Bool {
        if case .capped = self { return true }
        return false
    }
}

private struct JigsawProcessedBlock: Equatable {
    let block: StructureTemplateBlock
    var state: BlockState
    var lootTable: String?
    var lootSeed: Int64?

    init(block: StructureTemplateBlock, state: BlockState) {
        self.block = block
        self.state = state
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state == rhs.state && lhs.lootTable == rhs.lootTable && lhs.lootSeed == rhs.lootSeed
    }
}

private struct JigsawLootCandidate {
    let state: BlockState
    let pos: PosInt3D
    let lootTable: String
    let processorLootSeed: Int64?
    let templateLootSeed: Int64
}

private struct QueuedPiece {
    let piece: JigsawStructurePiece
    let shape: JigsawShape
    let depth: Int
    let priority: Int
    let sequence: Int
}

private enum JigsawJoint { case aligned, rollable }

private struct JigsawInfo {
    let pos: PosInt3D
    let facing: LocalDirection
    let top: LocalDirection
    let joint: JigsawJoint
    let name: String
    let pool: String
    let target: String
    let placementPriority: Int
    let selectionPriority: Int

    func attaches(to candidate: JigsawInfo) -> Bool {
        self.facing.opposite == candidate.facing
            && (self.joint == .rollable || self.top == candidate.top)
            && self.target == candidate.name
    }
}

private struct JigsawDirections {
    let facing: LocalDirection
    let top: LocalDirection

    init?(rawValue: String) {
        let parts = rawValue.split(separator: "_")
        guard parts.count == 2,
              let facing = LocalDirection(rawValueName: String(parts[0])),
              let top = LocalDirection(rawValueName: String(parts[1]))
        else { return nil }
        self.facing = facing
        self.top = top
    }
}

private enum JigsawRotation: Int, CaseIterable {
    case none = 0
    case clockwise90
    case clockwise180
    case counterclockwise90

    var publicDirection: CardinalDirection {
        switch self { case .none: return .south; case .clockwise90: return .west; case .clockwise180: return .north; case .counterclockwise90: return .east }
    }

    func transformed(_ pos: PosInt3D) -> PosInt3D {
        switch self {
        case .none: return pos
        case .clockwise90: return PosInt3D(x: -pos.z, y: pos.y, z: pos.x)
        case .clockwise180: return PosInt3D(x: -pos.x, y: pos.y, z: -pos.z)
        case .counterclockwise90: return PosInt3D(x: pos.z, y: pos.y, z: -pos.x)
        }
    }

    func transformed(_ direction: LocalDirection) -> LocalDirection {
        guard !direction.isVertical else { return direction }
        var result = direction
        let turns = self == .counterclockwise90 ? 3 : self.rawValue
        for _ in 0..<turns { result = result.clockwise }
        return result
    }

    func transformed(_ state: BlockState) -> BlockState {
        guard var properties = state.properties else { return state }
        if let facing = properties["facing"], let direction = LocalDirection(rawValueName: facing) {
            properties["facing"] = self.transformed(direction).name
        }
        if let orientation = properties["orientation"], let directions = JigsawDirections(rawValue: orientation) {
            properties["orientation"] = "\(self.transformed(directions.facing).name)_\(self.transformed(directions.top).name)"
        }
        if let axis = properties["axis"], (self == .clockwise90 || self == .counterclockwise90) {
            if axis == "x" { properties["axis"] = "z" } else if axis == "z" { properties["axis"] = "x" }
        }
        if let value = properties["rotation"], let integer = Int(value) {
            properties["rotation"] = String((integer + self.rawValue * 4) & 15)
        }
        let horizontalKeys: [(String, LocalDirection)] = [("north", .north), ("east", .east), ("south", .south), ("west", .west)]
        let directional = horizontalKeys.compactMap { key, direction in properties[key].map { (direction, $0) } }
        if !directional.isEmpty {
            for (key, _) in horizontalKeys { properties.removeValue(forKey: key) }
            for (direction, value) in directional { properties[self.transformed(direction).name] = value }
        }
        if let shape = properties["shape"] {
            properties["shape"] = self.transformedShape(shape)
        }
        return BlockState(id: state.id, properties: properties)
    }

    private func transformedShape(_ shape: String) -> String {
        let turns = self.rawValue
        guard turns != 0 else { return shape }
        var result = shape
        for _ in 0..<turns {
            switch result {
            case "north_south": result = "east_west"
            case "east_west": result = "north_south"
            case "ascending_north": result = "ascending_east"
            case "ascending_east": result = "ascending_south"
            case "ascending_south": result = "ascending_west"
            case "ascending_west": result = "ascending_north"
            case "north_east": result = "south_east"
            case "south_east": result = "south_west"
            case "south_west": result = "north_west"
            case "north_west": result = "north_east"
            default: break
            }
        }
        return result
    }

    func bounds(size: PosInt3D, origin: PosInt3D) -> BoundingBox {
        let a = self.transformed(.zero).adding(origin)
        let b = self.transformed(PosInt3D(x: size.x &- 1, y: size.y &- 1, z: size.z &- 1)).adding(origin)
        return .fromCorners(a, b)
    }
}

private extension StructurePoolElement {
    var isEmpty: Bool { if case .empty = self { return true }; return false }
    var isLegacy: Bool {
        switch self {
        case .single(_, _, _, let legacy, _): return legacy
        case .list(let elements, _): return elements.first?.isLegacy ?? false
        default: return false
        }
    }
    var singleEntries: [(location: String, processors: StructureProcessorListReference?, legacy: Bool)] {
        switch self {
        case .single(let location, let processors, _, let legacy, _): return [(location, processors, legacy)]
        case .list(let elements, _): return elements.flatMap(\.singleEntries)
        default: return []
        }
    }
}

private extension StructureProcessorPredicate {
    func matches<R: Random>(_ state: BlockState, context: StructureGenerationContext, random: inout R) -> Bool {
        switch addDefaultNamespace(self.type) {
        case "minecraft:block_match":
            return self.block.map(addDefaultNamespace) == state.id
        case "minecraft:random_block_match":
            guard self.block.map(addDefaultNamespace) == state.id else { return false }
            return random.nextFloat() < (self.probability ?? 0)
        case "minecraft:blockstate_match":
            return self.blockState?.blockState == state
        case "minecraft:always_true":
            return true
        case "minecraft:tag_match":
            guard let tag = self.tag else { return false }
            return context.block(state.id, isInTag: tag)
        default:
            return false
        }
    }
}

private extension StructurePoolAlias {
    func apply<R: Random>(to aliases: inout [String: String], random: inout R) {
        switch self {
        case .direct(let binding): aliases[binding.alias] = binding.target
        case .random(let binding):
            if let selected = weightedRandom(binding.targets.map { ($0.data, $0.weight) }, random: &random) { aliases[binding.alias] = selected }
        case .randomGroup(let binding):
            if let selected = weightedRandom(binding.groups.map { ($0.data, $0.weight) }, random: &random) {
                for direct in selected { aliases[direct.alias] = direct.target }
            }
        }
    }
}

private func weightedRandom<T, R: Random>(_ values: [(T, Int)], random: inout R) -> T? {
    let total = values.reduce(0) { $0 + $1.1 }
    guard total > 0 else { return nil }
    var selected = Int(random.next(bound: UInt32(total)))
    for (value, weight) in values {
        if selected < weight { return value }
        selected -= weight
    }
    return nil
}

private extension StructureHeightProvider {
    func constantValue(minimumWorldY: Int32, maximumWorldY: Int32) -> Int32? {
        guard case .constant(let anchor) = self else { return nil }
        return anchor.resolve(minimumWorldY: minimumWorldY, maximumWorldY: maximumWorldY)
    }
}

private extension PosInt3D {
    static let zero = PosInt3D(x: 0, y: 0, z: 0)
    func adding(_ other: PosInt3D) -> PosInt3D { PosInt3D(x: self.x &+ other.x, y: self.y &+ other.y, z: self.z &+ other.z) }
    func subtracting(_ other: PosInt3D) -> PosInt3D { PosInt3D(x: self.x &- other.x, y: self.y &- other.y, z: self.z &- other.z) }
    func offset(_ direction: LocalDirection) -> PosInt3D { PosInt3D(x: self.x &+ direction.stepX, y: self.y &+ direction.stepY, z: self.z &+ direction.stepZ) }
}

private extension LocalDirection {
    init?(rawValueName: String) {
        switch rawValueName {
        case "down": self = .down; case "up": self = .up; case "north": self = .north
        case "south": self = .south; case "west": self = .west; case "east": self = .east
        default: return nil
        }
    }
    var name: String {
        switch self { case .down: return "down"; case .up: return "up"; case .north: return "north"; case .south: return "south"; case .west: return "west"; case .east: return "east" }
    }
    var isVertical: Bool { self == .up || self == .down }
    var clockwise: LocalDirection {
        switch self { case .north: return .east; case .east: return .south; case .south: return .west; case .west: return .north; default: return self }
    }
}

private extension NBTTag {
    func compoundString(_ key: String) -> String? {
        guard case .compound(let values) = self, case .string(let value)? = values[key] else { return nil }
        return value
    }
    func compoundInt32(_ key: String) -> Int32? {
        guard case .compound(let values) = self, let value = values[key] else { return nil }
        switch value { case .byte(let x): return Int32(x); case .short(let x): return Int32(x); case .int(let x): return x; case .long(let x): return Int32(truncatingIfNeeded: x); default: return nil }
    }
    func compoundInt64(_ key: String) -> Int64? {
        guard case .compound(let values) = self, let value = values[key] else { return nil }
        switch value { case .byte(let x): return Int64(x); case .short(let x): return Int64(x); case .int(let x): return Int64(x); case .long(let x): return x; default: return nil }
    }
}
