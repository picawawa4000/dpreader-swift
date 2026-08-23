import Foundation

/// The fluid surface and block type selected for one aquifer cell.
struct AquiferFluidLevel: Equatable {
    let y: Int32
    let state: BlockState

    @inline(__always) func blockState(at y: Int32) -> BlockState {
        y < self.y ? self.state : Blocks.airState
    }
}

/// Resolves the material of non-solid density cells using Minecraft's aquifer grid.
///
/// One instance belongs to one generated chunk and is reused by its carvers. The
/// caches and `needsFluidTick` value intentionally mirror the stateful vanilla
/// sampler, although proto-chunks do not currently retain post-processing ticks.
final class AquiferSampler {
    private enum PositionalRandomDeriver {
        case checked(CheckedRandomSplitter)
        case xoroshiro(XoroshiroRandomSplitter)

        func offsets(at position: PosInt3D) -> (Int32, Int32, Int32) {
            switch self {
            case .checked(let splitter):
                var random = splitter.split(usingPos: position)
                return (
                    Int32(random.next(bound: 10)),
                    Int32(random.next(bound: 9)),
                    Int32(random.next(bound: 10))
                )
            case .xoroshiro(let splitter):
                var random = splitter.split(usingPos: position)
                return (
                    Int32(random.next(bound: 10)),
                    Int32(random.next(bound: 9)),
                    Int32(random.next(bound: 10))
                )
            }
        }
    }

    private enum Mode {
        case seaLevel
        case aquifer(Impl)
    }

    private var mode: Mode
    private(set) var needsFluidTick = false
    private let fluidLevelSampler: (Int32, Int32, Int32) -> AquiferFluidLevel

    init(settings: NoiseSettings, chunkPos: PosInt2D, worldSeed: WorldSeed) {
        let defaultFluid = settings.defaultFluid.blockState
        let lava = BlockState(type: Block(withID: "minecraft:lava"))
        let seaLevel = Int32(settings.seaLevel)
        self.fluidLevelSampler = { _, y, _ in
            y < min(-54, seaLevel)
                ? AquiferFluidLevel(y: -54, state: lava)
                : AquiferFluidLevel(y: seaLevel, state: defaultFluid)
        }

        guard settings.aquifersEnabled else {
            self.mode = .seaLevel
            return
        }

        let aquiferSplitter: PositionalRandomDeriver
        if settings.legacyRandomSource {
            var rootRandom = CheckedRandom(seed: worldSeed)
            let rootSplitter = CheckedRandomSplitter(seed: rootRandom.nextLong())
            var aquiferRandom = rootSplitter.split(usingString: "minecraft:aquifer")
            aquiferSplitter = .checked(CheckedRandomSplitter(seed: aquiferRandom.nextLong()))
        } else {
            var rootRandom = XoroshiroRandom(seed: worldSeed)
            let rootSplitter = XoroshiroRandomSplitter(
                seedLo: rootRandom.nextLong(),
                seedHi: rootRandom.nextLong()
            )
            var aquiferRandom = rootSplitter.split(usingString: "minecraft:aquifer")
            aquiferSplitter = .xoroshiro(XoroshiroRandomSplitter(
                seedLo: aquiferRandom.nextLong(),
                seedHi: aquiferRandom.nextLong()
            ))
        }
        self.mode = .aquifer(Impl(
            settings: settings,
            chunkPos: chunkPos,
            randomDeriver: aquiferSplitter,
            fluidLevelSampler: self.fluidLevelSampler
        ))
    }

    /// Returns `nil` for solid/barrier cells and an air or fluid state otherwise.
    func apply(at position: PosInt3D, density: Double) -> BlockState? {
        switch self.mode {
        case .seaLevel:
            self.needsFluidTick = false
            guard density <= 0 else { return nil }
            return self.fluidLevelSampler(position.x, position.y, position.z).blockState(at: position.y)
        case .aquifer(let implementation):
            let state = implementation.apply(at: position, density: density)
            self.needsFluidTick = implementation.needsFluidTick
            return state
        }
    }

    private final class Impl {
        private static let noFluidLevel: Int32 = -32_512
        private static let fluidTickDistanceThreshold = maxDistance(100, 144)
        private static let surfaceOffsets: [(Int32, Int32)] = [
            (0, 0), (-2, -1), (-1, -1), (0, -1), (1, -1),
            (-3, 0), (-2, 0), (-1, 0), (1, 0),
            (-2, 1), (-1, 1), (0, 1), (1, 1)
        ]

        private let barrierNoise: any DensityFunction
        private let floodednessNoise: any DensityFunction
        private let spreadNoise: any DensityFunction
        private let fluidTypeNoise: any DensityFunction
        private let erosion: any DensityFunction
        private let depth: any DensityFunction
        private let preliminarySurfaceLevel: (any DensityFunction)?
        private let seaLevel: Int32
        private let randomDeriver: PositionalRandomDeriver
        private let fluidLevelSampler: (Int32, Int32, Int32) -> AquiferFluidLevel
        private let startX: Int32
        private let startY: Int32
        private let startZ: Int32
        private let sizeX: Int
        private let sizeY: Int
        private let sizeZ: Int
        private var maximumAquiferY: Int32
        private var fluidLevels: [AquiferFluidLevel?]
        private var cellPositions: [PosInt3D?]
        private var surfaceHeightCache: [Int64: Int32] = [:]
        private(set) var needsFluidTick = false

        init(
            settings: NoiseSettings,
            chunkPos: PosInt2D,
            randomDeriver: PositionalRandomDeriver,
            fluidLevelSampler: @escaping (Int32, Int32, Int32) -> AquiferFluidLevel
        ) {
            let router = settings.noiseRouter
            self.barrierNoise = router.barrier
            self.floodednessNoise = router.fluidLevelFloodedness
            self.spreadNoise = router.fluidLevelSpread
            self.fluidTypeNoise = router.lava
            self.erosion = router.erosion
            self.depth = router.depth
            self.preliminarySurfaceLevel = router.preliminarySurfaceLevel
            self.seaLevel = Int32(settings.seaLevel)
            self.randomDeriver = randomDeriver
            self.fluidLevelSampler = fluidLevelSampler

            let chunkStartX = chunkPos.x * 16
            let chunkStartZ = chunkPos.z * 16
            self.startX = floorDiv(chunkStartX - 5, by: 16)
            let endX = floorDiv(chunkStartX + 15 - 5, by: 16) + 1
            self.sizeX = Int(endX - self.startX + 1)
            self.startY = floorDiv(Int32(settings.minY) + 1, by: 12) - 1
            let endY = floorDiv(Int32(settings.minY + settings.height) + 1, by: 12) + 1
            self.sizeY = Int(endY - self.startY + 1)
            self.startZ = floorDiv(chunkStartZ - 5, by: 16)
            let endZ = floorDiv(chunkStartZ + 15 - 5, by: 16) + 1
            self.sizeZ = Int(endZ - self.startZ + 1)

            self.maximumAquiferY = .min
            self.fluidLevels = [AquiferFluidLevel?](repeating: nil, count: self.sizeX * self.sizeY * self.sizeZ)
            self.cellPositions = [PosInt3D?](repeating: nil, count: self.sizeX * self.sizeY * self.sizeZ)

            var highestSurface = Int32.min
            var z = self.startZ * 16
            while z <= endZ * 16 + 9 {
                var x = self.startX * 16
                while x <= endX * 16 + 9 {
                    highestSurface = max(highestSurface, self.estimateSurfaceHeight(x: x, z: z))
                    x += 4
                }
                z += 4
            }
            let raisedSurface = highestSurface + 8
            let upperCell = floorDiv(raisedSurface + 12, by: 12) + 1
            self.maximumAquiferY = upperCell * 12 + 10
        }

        func apply(at position: PosInt3D, density: Double) -> BlockState? {
            guard density <= 0 else {
                self.needsFluidTick = false
                return nil
            }

            let defaultLevel = self.fluidLevelSampler(position.x, position.y, position.z)
            if position.y > self.maximumAquiferY {
                self.needsFluidTick = false
                return defaultLevel.blockState(at: position.y)
            }
            if defaultLevel.blockState(at: position.y).type.id == "minecraft:lava" {
                self.needsFluidTick = false
                return defaultLevel.blockState(at: position.y)
            }

            let cellX = floorDiv(position.x - 5, by: 16)
            let cellY = floorDiv(position.y + 1, by: 12)
            let cellZ = floorDiv(position.z - 5, by: 16)
            var closestDistance = Int32.max
            var secondDistance = Int32.max
            var thirdDistance = Int32.max
            var fourthDistance = Int32.max
            var closest = 0
            var second = 0
            var third = 0
            var fourth = 0

            for offsetX in Int32(0)...1 {
                for offsetY in Int32(-1)...1 {
                    for offsetZ in Int32(0)...1 {
                        let candidateX = cellX + offsetX
                        let candidateY = cellY + offsetY
                        let candidateZ = cellZ + offsetZ
                        let candidateIndex = self.index(x: candidateX, y: candidateY, z: candidateZ)
                        let candidate = self.cellPosition(
                            at: candidateIndex,
                            cellX: candidateX,
                            cellY: candidateY,
                            cellZ: candidateZ
                        )
                        let dx = candidate.x - position.x
                        let dy = candidate.y - position.y
                        let dz = candidate.z - position.z
                        let distance = dx * dx + dy * dy + dz * dz
                        if closestDistance >= distance {
                            fourth = third; third = second; second = closest; closest = candidateIndex
                            fourthDistance = thirdDistance; thirdDistance = secondDistance
                            secondDistance = closestDistance; closestDistance = distance
                        } else if secondDistance >= distance {
                            fourth = third; third = second; second = candidateIndex
                            fourthDistance = thirdDistance; thirdDistance = secondDistance; secondDistance = distance
                        } else if thirdDistance >= distance {
                            fourth = third; third = candidateIndex
                            fourthDistance = thirdDistance; thirdDistance = distance
                        } else if fourthDistance >= distance {
                            fourth = candidateIndex; fourthDistance = distance
                        }
                    }
                }
            }

            let firstLevel = self.fluidLevel(at: closest)
            let firstSimilarity = Self.maxDistance(closestDistance, secondDistance)
            let result = firstLevel.blockState(at: position.y)
            if firstSimilarity <= 0 {
                if firstSimilarity >= Self.fluidTickDistanceThreshold {
                    self.needsFluidTick = firstLevel != self.fluidLevel(at: second)
                } else {
                    self.needsFluidTick = false
                }
                return result
            }

            if result.type.id == "minecraft:water",
               self.fluidLevelSampler(position.x, position.y - 1, position.z)
                .blockState(at: position.y - 1).type.id == "minecraft:lava" {
                self.needsFluidTick = true
                return result
            }

            var barrierSample: Double?
            let secondLevel = self.fluidLevel(at: second)
            let firstPressure = firstSimilarity * self.calculateDensity(
                at: position,
                cachedBarrier: &barrierSample,
                first: firstLevel,
                second: secondLevel
            )
            if density + firstPressure > 0 {
                self.needsFluidTick = false
                return nil
            }

            let thirdLevel = self.fluidLevel(at: third)
            let firstThirdSimilarity = Self.maxDistance(closestDistance, thirdDistance)
            if firstThirdSimilarity > 0 {
                let pressure = firstSimilarity * firstThirdSimilarity * self.calculateDensity(
                    at: position,
                    cachedBarrier: &barrierSample,
                    first: firstLevel,
                    second: thirdLevel
                )
                if density + pressure > 0 {
                    self.needsFluidTick = false
                    return nil
                }
            }

            let secondThirdSimilarity = Self.maxDistance(secondDistance, thirdDistance)
            if secondThirdSimilarity > 0 {
                let pressure = firstSimilarity * secondThirdSimilarity * self.calculateDensity(
                    at: position,
                    cachedBarrier: &barrierSample,
                    first: secondLevel,
                    second: thirdLevel
                )
                if density + pressure > 0 {
                    self.needsFluidTick = false
                    return nil
                }
            }

            let differs12 = firstLevel != secondLevel
            let differs23 = secondThirdSimilarity >= Self.fluidTickDistanceThreshold && secondLevel != thirdLevel
            let differs13 = firstThirdSimilarity >= Self.fluidTickDistanceThreshold && firstLevel != thirdLevel
            if differs12 || differs23 || differs13 {
                self.needsFluidTick = true
            } else {
                self.needsFluidTick = firstThirdSimilarity >= Self.fluidTickDistanceThreshold
                    && Self.maxDistance(closestDistance, fourthDistance) >= Self.fluidTickDistanceThreshold
                    && firstLevel != self.fluidLevel(at: fourth)
            }
            return result
        }

        private func index(x: Int32, y: Int32, z: Int32) -> Int {
            let localX = Int(x - self.startX)
            let localY = Int(y - self.startY)
            let localZ = Int(z - self.startZ)
            precondition(localX >= 0 && localX < self.sizeX)
            precondition(localY >= 0 && localY < self.sizeY)
            precondition(localZ >= 0 && localZ < self.sizeZ)
            return (localY * self.sizeZ + localZ) * self.sizeX + localX
        }

        private func cellPosition(at index: Int, cellX: Int32, cellY: Int32, cellZ: Int32) -> PosInt3D {
            if let cached = self.cellPositions[index] { return cached }
            let offsets = self.randomDeriver.offsets(at: PosInt3D(x: cellX, y: cellY, z: cellZ))
            let position = PosInt3D(
                x: cellX * 16 + offsets.0,
                y: cellY * 12 + offsets.1,
                z: cellZ * 16 + offsets.2
            )
            self.cellPositions[index] = position
            return position
        }

        private func fluidLevel(at index: Int) -> AquiferFluidLevel {
            if let cached = self.fluidLevels[index] { return cached }
            guard let position = self.cellPositions[index] else {
                preconditionFailure("Aquifer fluid level requested before its cell position")
            }
            let level = self.calculateFluidLevel(at: position)
            self.fluidLevels[index] = level
            return level
        }

        private func calculateDensity(
            at position: PosInt3D,
            cachedBarrier: inout Double?,
            first: AquiferFluidLevel,
            second: AquiferFluidLevel
        ) -> Double {
            let firstState = first.blockState(at: position.y).type.id
            let secondState = second.blockState(at: position.y).type.id
            if (firstState == "minecraft:lava" && secondState == "minecraft:water")
                || (firstState == "minecraft:water" && secondState == "minecraft:lava") {
                return 2
            }
            let difference = abs(first.y - second.y)
            guard difference != 0 else { return 0 }
            let midpoint = 0.5 * Double(first.y + second.y)
            let positionFromMidpoint = Double(position.y) + 0.5 - midpoint
            let halfDifference = Double(difference) / 2
            let remaining = halfDifference - abs(positionFromMidpoint)
            let pressure: Double
            if positionFromMidpoint > 0 {
                pressure = remaining > 0 ? remaining / 1.5 : remaining / 2.5
            } else {
                let belowPressure = 3 + remaining
                pressure = belowPressure > 0 ? belowPressure / 3 : belowPressure / 10
            }
            let barrier: Double
            if pressure >= -2 && pressure <= 2 {
                if let cachedBarrier { barrier = cachedBarrier }
                else {
                    barrier = self.barrierNoise.sample(at: position)
                    cachedBarrier = barrier
                }
            } else {
                barrier = 0
            }
            return 2 * (barrier + pressure)
        }

        private func calculateFluidLevel(at position: PosInt3D) -> AquiferFluidLevel {
            let defaultLevel = self.fluidLevelSampler(position.x, position.y, position.z)
            var minimumSurface = Int32.max
            let upperY = position.y + 12
            let lowerY = position.y - 12
            var hasSurfaceFluid = false

            for offset in Self.surfaceOffsets {
                let x = position.x + offset.0 * 16
                let z = position.z + offset.1 * 16
                let rawSurface = self.estimateSurfaceHeight(x: x, z: z)
                let raisedSurface = rawSurface + 8
                let isCenter = offset.0 == 0 && offset.1 == 0
                if isCenter && lowerY > raisedSurface { return defaultLevel }

                let reachesSurface = upperY > raisedSurface
                if reachesSurface || isCenter {
                    let surfaceLevel = self.fluidLevelSampler(x, raisedSurface, z)
                    if !surfaceLevel.blockState(at: raisedSurface).type.isAir {
                        if isCenter { hasSurfaceFluid = true }
                        if reachesSurface { return surfaceLevel }
                    }
                }
                minimumSurface = min(minimumSurface, rawSurface)
            }

            let fluidY = self.fluidBlockY(
                at: position,
                defaultLevel: defaultLevel,
                surfaceHeight: minimumSurface,
                hasSurfaceFluid: hasSurfaceFluid
            )
            return AquiferFluidLevel(
                y: fluidY,
                state: self.fluidBlockState(at: position, defaultLevel: defaultLevel, fluidY: fluidY)
            )
        }

        private func fluidBlockY(
            at position: PosInt3D,
            defaultLevel: AquiferFluidLevel,
            surfaceHeight: Int32,
            hasSurfaceFluid: Bool
        ) -> Int32 {
            let floodedness: Double
            let lowerFloodedness: Double
            if self.erosion.sample(at: position) < -0.225 && self.depth.sample(at: position) > 0.9 {
                floodedness = -1
                lowerFloodedness = -1
            } else {
                let distanceBelowSurface = surfaceHeight + 8 - position.y
                let surfaceInfluence = hasSurfaceFluid
                    ? clampedMap(value: Double(distanceBelowSurface), oldStart: 0, oldEnd: 64, newStart: 1, newEnd: 0)
                    : 0
                let noise = clamp(value: self.floodednessNoise.sample(at: position), lowerBound: -1.0, upperBound: 1.0)
                let lowerThreshold = lerp(delta: surfaceInfluence, start: 0.4, end: -0.8)
                let upperThreshold = lerp(delta: surfaceInfluence, start: 0.8, end: -0.3)
                floodedness = noise - lowerThreshold
                lowerFloodedness = noise - upperThreshold
            }

            if lowerFloodedness > 0 { return defaultLevel.y }
            if floodedness > 0 { return self.noiseBasedFluidLevel(at: position, surfaceHeight: surfaceHeight) }
            return Self.noFluidLevel
        }

        private func noiseBasedFluidLevel(at position: PosInt3D, surfaceHeight: Int32) -> Int32 {
            let cellX = floorDiv(position.x, by: 16)
            let cellY = floorDiv(position.y, by: 40)
            let cellZ = floorDiv(position.z, by: 16)
            let centerY = cellY * 40 + 20
            let noise = self.spreadNoise.sample(at: PosInt3D(x: cellX, y: cellY, z: cellZ)) * 10
            let rounded = Int32(floor(noise / 3)) * 3
            return min(surfaceHeight, centerY + rounded)
        }

        private func fluidBlockState(
            at position: PosInt3D,
            defaultLevel: AquiferFluidLevel,
            fluidY: Int32
        ) -> BlockState {
            var state = defaultLevel.state
            if fluidY <= -10, fluidY != Self.noFluidLevel, defaultLevel.state.type.id != "minecraft:lava" {
                let cell = PosInt3D(
                    x: floorDiv(position.x, by: 64),
                    y: floorDiv(position.y, by: 40),
                    z: floorDiv(position.z, by: 64)
                )
                if abs(self.fluidTypeNoise.sample(at: cell)) > 0.3 {
                    state = BlockState(type: Block(withID: "minecraft:lava"))
                }
            }
            return state
        }

        private func estimateSurfaceHeight(x: Int32, z: Int32) -> Int32 {
            let snappedX = floorDiv(x, by: 4) * 4
            let snappedZ = floorDiv(z, by: 4) * 4
            let key = Int64(snappedX) << 32 ^ Int64(UInt32(bitPattern: snappedZ))
            if let cached = self.surfaceHeightCache[key] { return cached }
            let estimated = self.preliminarySurfaceLevel.map {
                Int32(floor($0.sample(at: PosInt3D(x: snappedX, y: 0, z: snappedZ))))
            } ?? self.seaLevel
            self.surfaceHeightCache[key] = estimated
            return estimated
        }

        @inline(__always) private static func maxDistance(_ first: Int32, _ second: Int32) -> Double {
            1 - Double(second - first) / 25
        }
    }
}
