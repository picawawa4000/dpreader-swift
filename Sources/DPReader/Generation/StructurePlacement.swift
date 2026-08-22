import Foundation

/// A candidate structure-set position before biome and start validation select one structure.
public struct StructurePlacementSample {
    public let structureSetKey: RegistryKey<StructureSet>
    public let regionPos: PosInt2D
    public let chunkPos: PosInt2D
    public let blockPos: PosInt2D
    public let structures: [WeightedStructure]

    init(structureSetKey: RegistryKey<StructureSet>, regionPos: PosInt2D, chunkPos: PosInt2D, blockPos: PosInt2D, structures: [WeightedStructure]) {
        self.structureSetKey = structureSetKey
        self.regionPos = regionPos
        self.chunkPos = chunkPos
        self.blockPos = blockPos
        self.structures = structures
    }
}

/// A structure placement whose weighted entry has been resolved to a concrete structure.
public struct ResolvedStructurePlacementSample {
    public let structureSetKey: RegistryKey<StructureSet>
    public let structureKey: RegistryKey<Structure>
    public let regionPos: PosInt2D
    public let chunkPos: PosInt2D
    public let blockPos: PosInt2D

    init(
        structureSetKey: RegistryKey<StructureSet>,
        structureKey: RegistryKey<Structure>,
        regionPos: PosInt2D,
        chunkPos: PosInt2D,
        blockPos: PosInt2D
    ) {
        self.structureSetKey = structureSetKey
        self.structureKey = structureKey
        self.regionPos = regionPos
        self.chunkPos = chunkPos
        self.blockPos = blockPos
    }
}

/// Deterministically samples and resolves structure-set placements for one world seed.
public final class StructurePlacementSampler {
    private let worldSeed: WorldSeed
    private let dataPacks: [DataPack]
    private let structureRegistry = Registry<Structure>()
    private let structureSetRegistry = Registry<StructureSet>()
    private var tagRegistry: [String: TagDefinition] = [:]
    private var concentricRingsCache: [String: [StructurePlacementSample]] = [:]
    private var resolvedRegistryEntriesCache: [String: Set<String>] = [:]
    private var overworldBiomeGenerator: WorldGenerator?

    public init(withWorldSeed worldSeed: WorldSeed, usingDataPacks dataPacks: [DataPack]) {
        self.worldSeed = worldSeed
        self.dataPacks = dataPacks
        for pack in dataPacks {
            self.structureRegistry.mergeDown(with: pack.structureRegistry)
            self.structureSetRegistry.mergeDown(with: pack.structureSetRegistry)
            pack.tagRegistry.forEach { (key, value) in
                self.mergeTag(value, forKey: key.name)
            }
        }
    }

    public func sampleStructureSet(inRegion regionPos: PosInt2D, for structureSetKey: RegistryKey<StructureSet>) throws -> StructurePlacementSample? {
        return try self.sampleStructureSet(inRegion: regionPos, for: structureSetKey, visitedKeys: [])
    }

    public func sampleAllPlacements(for structureSetKey: RegistryKey<StructureSet>) throws -> [StructurePlacementSample] {
        guard let structureSet = self.structureSetRegistry.get(structureSetKey) else {
            throw Errors.structureSetNotFound(structureSetKey.name)
        }

        switch structureSet.placement {
        case .randomSpread:
            throw Errors.unsupportedPlacementEnumeration(structureSetKey.name)
        case .concentricRings(let placement):
            return try self.sampleConcentricRingsStructureSet(
                structureSet,
                structureSetKey: structureSetKey,
                placement: placement
            )
        }
    }

    public func resolveStructureSet(
        inRegion regionPos: PosInt2D,
        biome: RegistryKey<Biome>,
        for structureSetKey: RegistryKey<StructureSet>
    ) throws -> ResolvedStructurePlacementSample? {
        guard let sample = try self.sampleStructureSet(inRegion: regionPos, for: structureSetKey) else {
            return nil
        }
        guard let structureKey = try self.resolveStructure(for: sample, biome: biome) else {
            return nil
        }
        return ResolvedStructurePlacementSample(
            structureSetKey: sample.structureSetKey,
            structureKey: structureKey,
            regionPos: sample.regionPos,
            chunkPos: sample.chunkPos,
            blockPos: sample.blockPos
        )
    }

    public func resolveStructure(for sample: StructurePlacementSample, biome: RegistryKey<Biome>) throws -> RegistryKey<Structure>? {
        var matchingStructures: [WeightedStructure] = []
        for weightedStructure in sample.structures {
            let structureKey = RegistryKey<Structure>(referencing: weightedStructure.structure)
            guard let structure = self.structureRegistry.get(structureKey) else {
                throw Errors.structureNotFound(weightedStructure.structure)
            }
            if try self.registryEntry(biome.name, matches: structure.biomes, in: "worldgen/biome") {
                matchingStructures.append(weightedStructure)
            }
        }

        if matchingStructures.isEmpty {
            return nil
        }
        return self.selectStructure(from: matchingStructures, atChunk: sample.chunkPos)
    }

    /// Resolves a candidate using each structure's actual generation point and terrain checks.
    public func resolveStructureSet(
        inRegion regionPos: PosInt2D,
        validatingWith context: StructureStartValidationContext,
        for structureSetKey: RegistryKey<StructureSet>
    ) throws -> ResolvedStructurePlacementSample? {
        guard let sample = try self.sampleStructureSet(inRegion: regionPos, for: structureSetKey) else {
            return nil
        }
        guard let structureKey = try self.resolveStructure(for: sample, validatingWith: context) else {
            return nil
        }
        return ResolvedStructurePlacementSample(
            structureSetKey: sample.structureSetKey,
            structureKey: structureKey,
            regionPos: sample.regionPos,
            chunkPos: sample.chunkPos,
            blockPos: sample.blockPos
        )
    }

    /// Resolves one sampled placement after validating terrain and the biome at each possible
    /// structure's generation point.
    public func resolveStructure(
        for sample: StructurePlacementSample,
        validatingWith context: StructureStartValidationContext
    ) throws -> RegistryKey<Structure>? {
        var matchingStructures: [WeightedStructure] = []
        for weightedStructure in sample.structures {
            let structureKey = RegistryKey<Structure>(referencing: weightedStructure.structure)
            if try self.validateStructureStart(
                for: structureKey,
                atChunk: sample.chunkPos,
                using: context
            ) != nil {
                matchingStructures.append(weightedStructure)
            }
        }
        guard !matchingStructures.isEmpty else { return nil }
        return self.selectStructure(from: matchingStructures, atChunk: sample.chunkPos)
    }

    /// Returns details for a valid structure start, or `nil` if terrain or biome checks fail.
    public func validateStructureStart(
        for structureKey: RegistryKey<Structure>,
        atChunk startChunk: PosInt2D,
        using context: StructureStartValidationContext
    ) throws -> ValidatedStructureStart? {
        guard let structure = self.structureRegistry.get(structureKey) else {
            throw Errors.structureNotFound(structureKey.name)
        }
        guard let generationPosition = try structure.generationPosition(
            structureKey: structureKey,
            worldSeed: self.worldSeed,
            startChunk: startChunk,
            context: context
        ) else {
            return nil
        }

        if structure.type == "minecraft:ocean_monument" {
            let surroundingTag = Identifiers.tagID("minecraft:required_ocean_monument_surrounding")
            let checkX = startChunk.x &* 16 &+ 9
            let checkZ = startChunk.z &* 16 &+ 9
            let radius: Int32 = 29
            let minQuartX = floorDiv(checkX &- radius, by: 4)
            let maxQuartX = floorDiv(checkX &+ radius, by: 4)
            let minQuartY = floorDiv(context.seaLevel &- radius, by: 4)
            let maxQuartY = floorDiv(context.seaLevel &+ radius, by: 4)
            let minQuartZ = floorDiv(checkZ &- radius, by: 4)
            let maxQuartZ = floorDiv(checkZ &+ radius, by: 4)
            for quartY in minQuartY...maxQuartY {
                for quartZ in minQuartZ...maxQuartZ {
                    for quartX in minQuartX...maxQuartX {
                        let position = PosInt3D(x: quartX &* 4, y: quartY &* 4, z: quartZ &* 4)
                        guard let biome = try context.biome(at: position),
                              try self.registryEntry(biome.name, matches: surroundingTag, in: "worldgen/biome") else {
                            return nil
                        }
                    }
                }
            }
        }

        guard let biome = try context.biome(at: generationPosition),
              try self.registryEntry(biome.name, matches: structure.biomes, in: "worldgen/biome") else {
            return nil
        }
        return ValidatedStructureStart(
            structureKey: structureKey,
            chunkPos: startChunk,
            generationPosition: generationPosition,
            biome: biome
        )
    }

    private func sampleStructureSet(inRegion regionPos: PosInt2D, for structureSetKey: RegistryKey<StructureSet>, visitedKeys: Set<String>) throws -> StructurePlacementSample? {
        guard let structureSet = self.structureSetRegistry.get(structureSetKey) else {
            throw Errors.structureSetNotFound(structureSetKey.name)
        }

        switch structureSet.placement {
        case .randomSpread(let placement):
            return try self.sampleRandomSpreadStructureSet(
                structureSet,
                structureSetKey: structureSetKey,
                placement: placement,
                regionPos: regionPos,
                visitedKeys: visitedKeys
            )
        case .concentricRings(let placement):
            let samples = try self.sampleConcentricRingsStructureSet(
                structureSet,
                structureSetKey: structureSetKey,
                placement: placement
            )
            return samples.first { $0.chunkPos == regionPos || $0.regionPos == regionPos }
        }
    }

    private func sampleRandomSpreadStructureSet(
        _ structureSet: StructureSet,
        structureSetKey: RegistryKey<StructureSet>,
        placement: RandomSpreadStructurePlacement,
        regionPos: PosInt2D,
        visitedKeys: Set<String>
    ) throws -> StructurePlacementSample? {
        let chunkPos = self.getRandomSpreadChunk(inRegion: regionPos, placement: placement)
        if try !self.shouldGenerateRandomSpreadStructureSet(atChunk: chunkPos, placement: placement, structureSetKey: structureSetKey, visitedKeys: visitedKeys) {
            return nil
        }

        let locateOffset = placement.locateOffset ?? PosInt3D(x: 0, y: 0, z: 0)
        let blockPos = PosInt2D(
            x: chunkPos.x &* 16 &+ locateOffset.x,
            z: chunkPos.z &* 16 &+ locateOffset.z
        )
        return StructurePlacementSample(
            structureSetKey: structureSetKey,
            regionPos: regionPos,
            chunkPos: chunkPos,
            blockPos: blockPos,
            structures: structureSet.structures
        )
    }

    private func sampleConcentricRingsStructureSet(
        _ structureSet: StructureSet,
        structureSetKey: RegistryKey<StructureSet>,
        placement: ConcentricRingsStructurePlacement
    ) throws -> [StructurePlacementSample] {
        if let cached = self.concentricRingsCache[structureSetKey.name] {
            return cached
        }

        let generator = try self.getOverworldBiomeGenerator()
        let preferredBiomeNames = try self.resolveRegistryEntries(
            matching: placement.preferredBiomes,
            in: "worldgen/biome"
        )
        var random = CheckedRandom(seed: self.worldSeed)
        var angle = random.nextDouble() * Double.pi * 2.0
        var ring = 0
        var ringSize = placement.spread
        var ringIndex = 0
        var distance = self.concentricRingDistance(
            placement: placement,
            ring: ring,
            random: &random
        )
        var samples: [StructurePlacementSample] = []
        samples.reserveCapacity(placement.count)

        for index in 0..<placement.count {
            let approxChunkX = Int32(round(cos(angle) * distance))
            let approxChunkZ = Int32(round(sin(angle) * distance))
            let approxBlockX = approxChunkX &* 16 &+ 8
            let approxBlockZ = approxChunkZ &* 16 &+ 8
            let blockPos = try self.locateConcentricRingsBiome(
                near: PosInt2D(x: approxBlockX, z: approxBlockZ),
                withinRadius: 112,
                preferredBiomeNames: preferredBiomeNames,
                generator: generator,
                random: &random
            )
            let snappedBlockPos = PosInt2D(
                x: (blockPos.x & ~15) &+ 4,
                z: (blockPos.z & ~15) &+ 4
            )
            let chunkPos = PosInt2D(
                x: floorDiv(snappedBlockPos.x &- 4, by: 16),
                z: floorDiv(snappedBlockPos.z &- 4, by: 16)
            )
            samples.append(
                StructurePlacementSample(
                    structureSetKey: structureSetKey,
                    regionPos: chunkPos,
                    chunkPos: chunkPos,
                    blockPos: snappedBlockPos,
                    structures: structureSet.structures
                )
            )

            ringIndex += 1
            angle += (Double.pi * 2.0) / Double(ringSize)

            if ringIndex == ringSize {
                ring += 1
                ringIndex = 0
                ringSize += 2 * ringSize / (ring + 1)
                let remaining = placement.count - (index + 1)
                if ringSize > remaining {
                    ringSize = remaining
                }
                angle += random.nextDouble() * Double.pi * 2.0
            }

            if index + 1 < placement.count {
                distance = self.concentricRingDistance(
                    placement: placement,
                    ring: ring,
                    random: &random
                )
            }
        }

        self.concentricRingsCache[structureSetKey.name] = samples
        return samples
    }

    private func locateConcentricRingsBiome<R: Random>(
        near approx: PosInt2D,
        withinRadius radius: Int32,
        preferredBiomeNames: Set<String>,
        generator: WorldGenerator,
        random: inout R
    ) throws -> PosInt2D {
        let searchX = approx.x >> 2
        let searchZ = approx.z >> 2
        let searchRadius = radius >> 2
        let dimension = RegistryKey<Dimension>(referencing: "minecraft:overworld")
        let sideLength = Int(searchRadius * 2 + 1)
        let from = PosInt2D(
            x: (searchX - searchRadius) &* 4,
            z: (searchZ - searchRadius) &* 4
        )
        let to = PosInt2D(
            x: (searchX + searchRadius + 1) &* 4,
            z: (searchZ + searchRadius + 1) &* 4
        )
        var found = 0
        var result = approx
        var locateRandom = CheckedRandom(seed: random.nextLong())
        guard let sampledBiomes = try generator.generateBiomesInSquare(
            from: from,
            to: to,
            atY: 0,
            in: dimension,
            scale: 4,
            forceBaking: true
        ) else {
            return result
        }

        for relativeZ in 0..<sideLength {
            for relativeX in 0..<sideLength {
                let biome = sampledBiomes[relativeZ * sideLength + relativeX]
                guard preferredBiomeNames.contains(biome.name) else {
                    continue
                }
                let biomePos = PosInt3D(
                    x: (searchX - searchRadius + Int32(relativeX)) &* 4,
                    y: 0,
                    z: (searchZ - searchRadius + Int32(relativeZ)) &* 4
                )
                if found == 0 || locateRandom.next(bound: UInt32(found + 1)) == 0 {
                    result = PosInt2D(x: biomePos.x, z: biomePos.z)
                }
                found += 1
            }
        }

        return result
    }

    private func concentricRingDistance<R: Random>(
        placement: ConcentricRingsStructurePlacement,
        ring: Int,
        random: inout R
    ) -> Double {
        let baseDistance = Double(placement.distance)
        return (4.0 * baseDistance)
            + (6.0 * Double(ring) * baseDistance)
            + (random.nextDouble() - 0.5) * baseDistance * 2.5
    }

    private func getOverworldBiomeGenerator() throws -> WorldGenerator {
        if let overworldBiomeGenerator {
            return overworldBiomeGenerator
        }

        let reloadedDataPacks = try self.dataPacks.map {
            try DataPack(
                fromRootPath: $0.rootPath,
                loadingOptions: [.noStructures, .noStructureSets, .noEnchantments, .noStructureTemplates],
                decodingVersion: $0.packFormat
            )
        }
        let generator = try WorldGenerator(
            withWorldSeed: self.worldSeed,
            usingDataPacks: reloadedDataPacks,
            usingSettings: RegistryKey(referencing: "minecraft:overworld")
        )
        self.overworldBiomeGenerator = generator
        return generator
    }

    private func shouldGenerateRandomSpreadStructureSet(
        atChunk chunkPos: PosInt2D,
        placement: RandomSpreadStructurePlacement,
        structureSetKey: RegistryKey<StructureSet>,
        visitedKeys: Set<String>
    ) throws -> Bool {
        if let frequency = placement.frequency {
            let method = placement.frequencyReductionMethod
            switch method {
            case .default?:
                throw Errors.unsupportedFrequencyReductionMethod(structureSetKey.name)
            case .legacyType1?:
                guard self.shouldGenerateLegacyType1(atChunk: chunkPos, chance: frequency) else {
                    return false
                }
            case .legacyType2?:
                guard self.shouldGenerateLegacyType2(atChunk: chunkPos, salt: placement.salt, chance: frequency) else {
                    return false
                }
            case .legacyType3?:
                guard self.shouldGenerateLegacyType3(atChunk: chunkPos, chance: frequency) else {
                    return false
                }
            case nil:
                throw Errors.unsupportedFrequencyReductionMethod(structureSetKey.name)
            }
        }

        guard let exclusionZone = placement.exclusionZone else {
            return true
        }

        if visitedKeys.contains(structureSetKey.name) {
            throw Errors.circularExclusionZone(structureSetKey.name)
        }
        let otherSetKey = RegistryKey<StructureSet>(referencing: exclusionZone.otherSet)
        guard let otherSet = self.structureSetRegistry.get(otherSetKey) else {
            throw Errors.structureSetNotFound(exclusionZone.otherSet)
        }
        guard case .randomSpread(let otherPlacement) = otherSet.placement else {
            throw Errors.unsupportedStructurePlacement(exclusionZone.otherSet)
        }

        let minChunkX = chunkPos.x &- Int32(exclusionZone.chunkCount)
        let maxChunkX = chunkPos.x &+ Int32(exclusionZone.chunkCount)
        let minChunkZ = chunkPos.z &- Int32(exclusionZone.chunkCount)
        let maxChunkZ = chunkPos.z &+ Int32(exclusionZone.chunkCount)
        let minRegionX = floorDiv(minChunkX, by: Int32(otherPlacement.spacing))
        let maxRegionX = floorDiv(maxChunkX, by: Int32(otherPlacement.spacing))
        let minRegionZ = floorDiv(minChunkZ, by: Int32(otherPlacement.spacing))
        let maxRegionZ = floorDiv(maxChunkZ, by: Int32(otherPlacement.spacing))
        var nextVisitedKeys = visitedKeys
        nextVisitedKeys.insert(structureSetKey.name)

        for regionZ in minRegionZ...maxRegionZ {
            for regionX in minRegionX...maxRegionX {
                let regionPos = PosInt2D(x: regionX, z: regionZ)
                if let sample = try self.sampleStructureSet(inRegion: regionPos, for: otherSetKey, visitedKeys: nextVisitedKeys) {
                    if sample.chunkPos.x >= minChunkX && sample.chunkPos.x <= maxChunkX && sample.chunkPos.z >= minChunkZ && sample.chunkPos.z <= maxChunkZ {
                        return false
                    }
                }
            }
        }

        return true
    }

    private func registryEntry(_ entryName: String, matches identifiers: Identifiers, in registryPath: String) throws -> Bool {
        switch identifiers {
        case .rawID(let id):
            return entryName == id
        case .tagID(let tag):
            return try self.registryEntry(entryName, isInTag: tag, in: registryPath, visitedTags: [])
        case .idList(let ids):
            for identifier in ids {
                if try self.registryEntry(entryName, matches: identifier, in: registryPath) {
                    return true
                }
            }
            return false
        }
    }

    private func resolveRegistryEntries(matching identifiers: Identifiers, in registryPath: String) throws -> Set<String> {
        let cacheKey = "\(registryPath)|\(self.identifiersCacheKey(identifiers))"
        if let cached = self.resolvedRegistryEntriesCache[cacheKey] {
            return cached
        }

        let resolved = try self.resolveRegistryEntries(
            matching: identifiers,
            in: registryPath,
            visitedTags: []
        )
        self.resolvedRegistryEntriesCache[cacheKey] = resolved
        return resolved
    }

    private func resolveRegistryEntries(
        matching identifiers: Identifiers,
        in registryPath: String,
        visitedTags: Set<String>
    ) throws -> Set<String> {
        switch identifiers {
        case .rawID(let id):
            return [id]
        case .tagID(let tag):
            if visitedTags.contains(tag) {
                throw Errors.circularTag(tag)
            }

            let tagKey = structurePlacementTagKey(forRegistryPath: registryPath, tagName: tag)
            guard let tagDefinition = self.tagRegistry[tagKey] else {
                return []
            }

            var nextVisitedTags = visitedTags
            nextVisitedTags.insert(tag)
            return try tagDefinition.values.reduce(into: Set<String>()) { partialResult, value in
                partialResult.formUnion(
                    try self.resolveRegistryEntries(for: value, in: registryPath, visitedTags: nextVisitedTags)
                )
            }
        case .idList(let ids):
            return try ids.reduce(into: Set<String>()) { partialResult, identifier in
                partialResult.formUnion(
                    try self.resolveRegistryEntries(
                        matching: identifier,
                        in: registryPath,
                        visitedTags: visitedTags
                    )
                )
            }
        }
    }

    private func resolveRegistryEntries(
        for tagValue: TagValue,
        in registryPath: String,
        visitedTags: Set<String>
    ) throws -> Set<String> {
        switch tagValue {
        case .rawID(let id):
            return [id]
        case .tagID(let tag):
            return try self.resolveRegistryEntries(
                matching: .tagID(tag),
                in: registryPath,
                visitedTags: visitedTags
            )
        }
    }

    private func identifiersCacheKey(_ identifiers: Identifiers) -> String {
        switch identifiers {
        case .rawID(let id):
            return "id:\(id)"
        case .tagID(let tag):
            return "tag:\(tag)"
        case .idList(let ids):
            return "list:[" + ids.map(self.identifiersCacheKey).joined(separator: ",") + "]"
        }
    }

    private func registryEntry(_ entryName: String, isInTag tag: String, in registryPath: String, visitedTags: Set<String>) throws -> Bool {
        if visitedTags.contains(tag) {
            throw Errors.circularTag(tag)
        }
        let tagKey = structurePlacementTagKey(forRegistryPath: registryPath, tagName: tag)
        guard let tagDefinition = self.tagRegistry[tagKey] else {
            return false
        }

        var nextVisitedTags = visitedTags
        nextVisitedTags.insert(tag)
        for value in tagDefinition.values {
            switch value {
            case .rawID(let id):
                if entryName == id {
                    return true
                }
            case .tagID(let nestedTag):
                if try self.registryEntry(entryName, isInTag: nestedTag, in: registryPath, visitedTags: nextVisitedTags) {
                    return true
                }
            }
        }
        return false
    }

    private func selectStructure(from matchingStructures: [WeightedStructure], atChunk chunkPos: PosInt2D) -> RegistryKey<Structure> {
        precondition(!matchingStructures.isEmpty, "Cannot select a structure from an empty structure list")

        let totalWeight = matchingStructures.reduce(into: 0) { partialResult, structure in
            partialResult += structure.weight
        }
        precondition(totalWeight > 0, "Structure weights must sum to a positive value")

        var random = checkedRandomForChunkGeneration(worldSeed: self.worldSeed, chunkX: chunkPos.x, chunkZ: chunkPos.z)
        var choice = Int(random.next(bound: UInt32(totalWeight)))
        for structure in matchingStructures {
            choice -= structure.weight
            if choice < 0 {
                return RegistryKey(referencing: structure.structure)
            }
        }

        return RegistryKey(referencing: matchingStructures.last!.structure)
    }

    private func mergeTag(_ tag: TagDefinition, forKey key: String) {
        if tag.replace || self.tagRegistry[key] == nil {
            self.tagRegistry[key] = tag
            return
        }

        var mergedValues = self.tagRegistry[key]!.values
        for value in tag.values where !mergedValues.contains(value) {
            mergedValues.append(value)
        }
        self.tagRegistry[key] = TagDefinition(values: mergedValues)
    }

    private func getRandomSpreadChunk(inRegion regionPos: PosInt2D, placement: RandomSpreadStructurePlacement) -> PosInt2D {
        let chunkRange = placement.spacing - placement.separation
        precondition(chunkRange > 0, "Invalid random spread placement: spacing must be greater than separation")

        var random = CheckedRandom(
            seed: structurePlacementRandomSeed(
                worldSeed: self.worldSeed,
                salt: placement.salt,
                regionX: regionPos.x,
                regionZ: regionPos.z
            )
        )

        let offsetX: Int32
        let offsetZ: Int32
        switch placement.spreadType {
        case .linear:
            offsetX = Int32(random.next(bound: UInt32(chunkRange)))
            offsetZ = Int32(random.next(bound: UInt32(chunkRange)))
        case .triangular:
            offsetX = Int32((random.next(bound: UInt32(chunkRange)) + random.next(bound: UInt32(chunkRange))) / 2)
            offsetZ = Int32((random.next(bound: UInt32(chunkRange)) + random.next(bound: UInt32(chunkRange))) / 2)
        }

        return PosInt2D(
            x: regionPos.x &* Int32(placement.spacing) &+ offsetX,
            z: regionPos.z &* Int32(placement.spacing) &+ offsetZ
        )
    }

    private func shouldGenerateLegacyType1(atChunk chunkPos: PosInt2D, chance: Double) -> Bool {
        guard chance > 0.0 else { return false }
        guard chance >= 0.2 else {
            return false
        }

        let shiftedX = Int64(chunkPos.x >> 4)
        let shiftedZ = Int64(chunkPos.z >> 4)
        let mixedSeed = self.worldSeed
            ^ overflow(shiftedX)
            ^ (overflow(shiftedZ) << 4)
        var random = CheckedRandom(seed: mixedSeed)
        _ = random.next(bits: 31)
        let inverseChance = max(1, Int((1.0 / chance).rounded()))
        return random.next(bound: UInt32(inverseChance)) == 0
    }

    private func shouldGenerateLegacyType2(atChunk chunkPos: PosInt2D, salt: Int, chance: Double) -> Bool {
        guard chance > 0.0 else { return false }
        var random = CheckedRandom(
            seed: structurePlacementRandomSeed(
                worldSeed: self.worldSeed,
                salt: salt,
                regionX: chunkPos.x,
                regionZ: chunkPos.z
            )
        )
        return Double(random.nextFloat()) < chance
    }

    private func shouldGenerateLegacyType3(atChunk chunkPos: PosInt2D, chance: Double) -> Bool {
        guard chance > 0.0 else { return false }
        var random = checkedRandomForChunkGeneration(worldSeed: self.worldSeed, chunkX: chunkPos.x, chunkZ: chunkPos.z)
        return random.nextDouble() < chance
    }

    enum Errors: Error {
        case structureSetNotFound(String)
        case structureNotFound(String)
        case unsupportedStructurePlacement(String)
        case unsupportedPlacementEnumeration(String)
        case unsupportedFrequencyReductionMethod(String)
        case circularExclusionZone(String)
        case circularTag(String)
    }
}

@inline(__always) private func structurePlacementRandomSeed(worldSeed: WorldSeed, salt: Int, regionX: Int32, regionZ: Int32) -> WorldSeed {
    let signedSeed = Int64(bitPattern: worldSeed)
    let combined = signedSeed
        &+ Int64(regionX) &* 341873128712
        &+ Int64(regionZ) &* 132897987541
        &+ Int64(salt)
    return overflow(combined)
}

@inline(__always) private func structurePlacementTagKey(forRegistryPath registryPath: String, tagName: String) -> String {
    let namespacedTag = addDefaultNamespace(tagName)
    let pieces = namespacedTag.split(separator: ":", maxSplits: 1)
    precondition(pieces.count == 2, "Tag names must be namespaced")
    return "\(pieces[0]):\(registryPath)/\(pieces[1])"
}
