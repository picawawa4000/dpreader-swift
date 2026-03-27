import Foundation

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

public final class StructurePlacementSampler {
    private let worldSeed: WorldSeed
    private let structureSetRegistry = Registry<StructureSet>()

    public init(withWorldSeed worldSeed: WorldSeed, usingDataPacks dataPacks: [DataPack]) {
        self.worldSeed = worldSeed
        for pack in dataPacks {
            self.structureSetRegistry.mergeDown(with: pack.structureSetRegistry)
        }
    }

    public func sampleStructureSet(inRegion regionPos: PosInt2D, for structureSetKey: RegistryKey<StructureSet>) throws -> StructurePlacementSample? {
        return try self.sampleStructureSet(inRegion: regionPos, for: structureSetKey, visitedKeys: [])
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
        case .concentricRings:
            throw Errors.unsupportedStructurePlacement(structureSetKey.name)
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
        let minRegionX = structurePlacementFloorDiv(minChunkX, by: Int32(otherPlacement.spacing))
        let maxRegionX = structurePlacementFloorDiv(maxChunkX, by: Int32(otherPlacement.spacing))
        let minRegionZ = structurePlacementFloorDiv(minChunkZ, by: Int32(otherPlacement.spacing))
        let maxRegionZ = structurePlacementFloorDiv(maxChunkZ, by: Int32(otherPlacement.spacing))
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
        case unsupportedStructurePlacement(String)
        case unsupportedFrequencyReductionMethod(String)
        case circularExclusionZone(String)
    }
}

@inline(__always) private func structurePlacementFloorDiv(_ value: Int32, by divisor: Int32) -> Int32 {
    precondition(divisor > 0, "divisor must be positive")
    let quotient = value / divisor
    let remainder = value % divisor
    return remainder < 0 ? quotient - 1 : quotient
}

@inline(__always) private func structurePlacementRandomSeed(worldSeed: WorldSeed, salt: Int, regionX: Int32, regionZ: Int32) -> WorldSeed {
    let signedSeed = Int64(bitPattern: worldSeed)
    let combined = signedSeed
        &+ Int64(regionX) &* 341873128712
        &+ Int64(regionZ) &* 132897987541
        &+ Int64(salt)
    return overflow(combined)
}

@inline(__always) private func checkedRandomForChunkGeneration(worldSeed: WorldSeed, chunkX: Int32, chunkZ: Int32) -> CheckedRandom {
    var random = CheckedRandom(seed: worldSeed)
    let multiplierX = checkedRandomNextLongExact(&random)
    let multiplierZ = checkedRandomNextLongExact(&random)
    let mixed = (multiplierX &* overflow(Int64(chunkX)))
        ^ (multiplierZ &* overflow(Int64(chunkZ)))
        ^ worldSeed
    return CheckedRandom(seed: mixed)
}

@inline(__always) private func checkedRandomNextLongExact(_ random: inout CheckedRandom) -> UInt64 {
    let high = Int64(Int32(bitPattern: random.next(bits: 32)))
    let low = Int64(Int32(bitPattern: random.next(bits: 32)))
    return UInt64(bitPattern: (high << 32) &+ low)
}
