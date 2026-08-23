import Foundation

/// Runtime values supplied while evaluating a surface rule at one block.
public struct SurfaceRuleEvaluationContext {
    public let blockPosition: PosInt3D
    public let biome: RegistryKey<Biome>?
    public let stoneDepthAbove: Int
    public let stoneDepthBelow: Int
    public let fluidHeight: Int32?
    public let surfaceDepth: Int
    public let secondarySurfaceDepth: Double
    public let seaLevel: Int32
    public let minY: Int32
    public let height: Int32
    public let estimatedSurfaceY: Int32
    public let isSteep: Bool
    public let biomeTemperature: Double?
}

/// Evaluates decoded surface rules and applies them to generated chunk blocks.
final class SurfaceRuleApplicator {
    private let settings: NoiseSettings
    private let noises: Registry<DoublePerlinNoise>
    private let biomes: Registry<Biome>
    private let worldSeed: WorldSeed
    private let randomDeriver: XoroshiroRandomSplitter
    private let terracottaBands: [BlockState]

    init(
        settings: NoiseSettings,
        noises: Registry<DoublePerlinNoise>,
        biomes: Registry<Biome>,
        worldSeed: WorldSeed
    ) {
        self.settings = settings
        self.noises = noises
        self.biomes = biomes
        self.worldSeed = worldSeed
        var random = XoroshiroRandom(seed: worldSeed)
        self.randomDeriver = XoroshiroRandomSplitter(seedLo: random.nextLong(), seedHi: random.nextLong())
        var bandRandom = self.randomDeriver.split(usingString: "minecraft:clay_bands")
        self.terracottaBands = Self.makeTerracottaBands(random: &bandRandom)
    }

    func apply(to chunk: ProtoChunk, at chunkPos: PosInt2D) {
        let minY = chunk.minY
        let defaultState = self.settings.defaultBlock.blockState

        var heights = [Int32](repeating: minY - 1, count: 256)
        for z in Int32(0)..<16 {
            for x in Int32(0)..<16 {
                let index = Int(z * 16 + x)
                heights[index] = self.highestNonAirY(in: chunk, x: x, z: z)
            }
        }

        for z in Int32(0)..<16 {
            for x in Int32(0)..<16 {
                let top = heights[Int(z * 16 + x)]
                guard top >= minY else { continue }
                let biomeY = min(chunk.height - 1, max(0, top - minY))
                guard chunk.biome(atLocal: PosInt3D(x: x, y: biomeY, z: z))?.name == "minecraft:eroded_badlands" else { continue }
                self.placeBadlandsPillar(in: chunk, chunkPos: chunkPos, x: x, z: z, surfaceY: top + 1)
                heights[Int(z * 16 + x)] = self.highestNonAirY(in: chunk, x: x, z: z)
            }
        }

        for z in Int32(0)..<16 {
            for x in Int32(0)..<16 {
                let worldX = chunkPos.x * 16 + x
                let worldZ = chunkPos.z * 16 + z
                let surfaceDepth = self.sampleSurfaceDepth(x: worldX, z: worldZ)
                let secondaryDepth = self.sampleNoise("minecraft:surface_secondary", x: Double(worldX), y: 0, z: Double(worldZ)) ?? 0
                let actualTop = heights[Int(z * 16 + x)]
                let estimatedSurface = self.estimatedSurfaceY(x: worldX, z: worldZ, actualTop: actualTop, surfaceDepth: surfaceDepth)
                let steep = Self.isSteep(x: x, z: z, heights: heights)
                var stoneDepthAbove = 0
                var fluidHeight: Int32?
                var stoneBottom = Int32.max

                if actualTop < minY { continue }
                var worldY = actualTop
                while worldY >= minY {
                    let local = PosInt3D(x: x, y: worldY - minY, z: z)
                    let state = chunk.block(atLocal: local)
                    if state.type.isAir {
                        stoneDepthAbove = 0
                        stoneBottom = Int32.max
                        fluidHeight = nil
                    } else if Self.isFluid(state) {
                        stoneDepthAbove = 0
                        stoneBottom = Int32.max
                        if fluidHeight == nil { fluidHeight = worldY + 1 }
                    } else {
                        if stoneBottom >= worldY {
                            stoneBottom = minY
                            var scanY = worldY - 1
                            while scanY >= minY {
                                let below = chunk.block(atLocal: PosInt3D(x: x, y: scanY - minY, z: z))
                                if below.type.isAir || Self.isFluid(below) {
                                    stoneBottom = scanY + 1
                                    break
                                }
                                scanY -= 1
                            }
                        }
                        stoneDepthAbove += 1
                        let stoneDepthBelow = Int(worldY - stoneBottom + 1)
                        if state == defaultState {
                            let biomeKey = chunk.biome(atLocal: local)
                            let biome = biomeKey.flatMap { self.biomes.get($0) }
                            let context = SurfaceRuleEvaluationContext(
                                blockPosition: PosInt3D(x: worldX, y: worldY, z: worldZ),
                                biome: biomeKey,
                                stoneDepthAbove: stoneDepthAbove,
                                stoneDepthBelow: stoneDepthBelow,
                                fluidHeight: fluidHeight,
                                surfaceDepth: surfaceDepth,
                                secondarySurfaceDepth: secondaryDepth,
                                seaLevel: Int32(self.settings.seaLevel),
                                minY: minY,
                                height: chunk.height,
                                estimatedSurfaceY: estimatedSurface,
                                isSteep: steep,
                                biomeTemperature: biome?.temperature
                            )
                            if let replacement = self.evaluate(rule: self.settings.surfaceRule, context: context) {
                                chunk.setBlock(replacement, atLocal: local)
                            }
                        }
                    }
                    worldY -= 1
                }
                let biomeY = min(chunk.height - 1, max(0, actualTop - minY))
                if let biomeKey = chunk.biome(atLocal: PosInt3D(x: x, y: biomeY, z: z)),
                   biomeKey.name == "minecraft:frozen_ocean" || biomeKey.name == "minecraft:deep_frozen_ocean" {
                    self.placeIceberg(
                        in: chunk,
                        chunkPos: chunkPos,
                        x: x,
                        z: z,
                        surfaceY: actualTop + 1,
                        minimumY: estimatedSurface,
                        biome: self.biomes.get(biomeKey)
                    )
                }
            }
        }
    }

    func evaluate(rule: any SurfaceRule, context: SurfaceRuleEvaluationContext) -> BlockState? {
        switch rule {
        case let block as SurfaceRuleBlock:
            return block.resultState.blockState
        case let sequence as SurfaceRuleSequence:
            for child in sequence.sequence {
                if let result = self.evaluate(rule: child, context: context) { return result }
            }
            return nil
        case let conditional as SurfaceRuleConditionRule:
            guard self.evaluate(condition: conditional.ifTrue, context: context) else { return nil }
            return self.evaluate(rule: conditional.thenRun, context: context)
        case is SurfaceRuleBandlands:
            let sampledOffset = (self.sampleNoise(
                "minecraft:clay_bands_offset",
                x: Double(context.blockPosition.x),
                y: 0,
                z: Double(context.blockPosition.z)
            ) ?? 0) * 4.0
            let offset = Int(floor(sampledOffset + 0.5))
            return self.terracottaBands[Self.floorMod(Int(context.blockPosition.y) + offset, self.terracottaBands.count)]
        default:
            return nil
        }
    }

    func evaluate(condition: any SurfaceRuleCondition, context: SurfaceRuleEvaluationContext) -> Bool {
        switch condition {
        case is SurfaceRuleAbovePreliminarySurface:
            return context.blockPosition.y >= context.estimatedSurfaceY
        case let value as SurfaceRuleBiomeCondition:
            guard let biome = context.biome else { return false }
            return value.biomeIs.map(addDefaultNamespace).contains(biome.name)
        case is SurfaceRuleHoleCondition:
            return context.surfaceDepth <= 0
        case let value as SurfaceRuleNoiseThresholdCondition:
            guard let sampled = self.sampleNoise(
                addDefaultNamespace(value.noise),
                x: Double(context.blockPosition.x), y: 0, z: Double(context.blockPosition.z)
            ) else { return false }
            return sampled >= value.minThreshold && sampled <= value.maxThreshold
        case let value as SurfaceRuleNotCondition:
            return !self.evaluate(condition: value.invert, context: context)
        case is SurfaceRuleSteepCondition:
            return context.isSteep
        case let value as SurfaceRuleStoneDepthCondition:
            let depth = value.surfaceType == .ceiling ? context.stoneDepthBelow : context.stoneDepthAbove
            let addedDepth = value.addSurfaceDepth ? context.surfaceDepth : 0
            let secondary = value.secondaryDepthRange.map {
                Int(Self.map(context.secondarySurfaceDepth, fromLow: -1, fromHigh: 1, toLow: 0, toHigh: Double($0)))
            } ?? 0
            return depth <= 1 + value.offset + addedDepth + secondary
        case is SurfaceRuleTemperatureCondition:
            guard var temperature = context.biomeTemperature else { return false }
            if context.blockPosition.y > context.seaLevel + 17 {
                temperature -= Double(context.blockPosition.y - context.seaLevel - 17) * 0.05 / 40.0
            }
            return temperature < 0.15
        case let value as SurfaceRuleVerticalGradientCondition:
            let lower = Self.resolve(value.trueAtAndBelow, minY: context.minY, height: context.height)
            let upper = Self.resolve(value.falseAtAndAbove, minY: context.minY, height: context.height)
            if context.blockPosition.y <= lower { return true }
            if context.blockPosition.y >= upper { return false }
            let chance = Self.map(Double(context.blockPosition.y), fromLow: Double(lower), fromHigh: Double(upper), toLow: 1, toHigh: 0)
            var named = self.randomDeriver.split(usingString: addDefaultNamespace(value.randomName))
            let positional = named.nextSplitter()
            var random = positional.split(usingPos: context.blockPosition)
            return Double(random.nextFloat()) < chance
        case let value as SurfaceRuleWaterCondition:
            guard let fluidHeight = context.fluidHeight else { return true }
            let stone = value.addStoneDepth ? context.stoneDepthAbove : 0
            return Int(context.blockPosition.y) + stone >= Int(fluidHeight) + value.offset + context.surfaceDepth * value.surfaceDepthMultiplier
        case let value as SurfaceRuleYAboveCondition:
            let anchor = Self.resolve(value.anchor, minY: context.minY, height: context.height)
            let stone = value.addStoneDepth ? context.stoneDepthAbove : 0
            return Int(context.blockPosition.y) + stone >= Int(anchor) + context.surfaceDepth * value.surfaceDepthMultiplier
        default:
            return false
        }
    }

    private func sampleSurfaceDepth(x: Int32, z: Int32) -> Int {
        let noise = self.sampleNoise("minecraft:surface", x: Double(x), y: 0, z: Double(z)) ?? 0
        var random = self.randomDeriver.split(usingPos: PosInt3D(x: x, y: 0, z: z))
        return Int(noise * 2.75 + 3.0 + random.nextDouble() * 0.25)
    }

    private func sampleNoise(_ name: String, x: Double, y: Double, z: Double) -> Double? {
        self.noises.get(RegistryKey<DoublePerlinNoise>(referencing: addDefaultNamespace(name)))?.sample(x: x, y: y, z: z)
    }

    private func estimatedSurfaceY(x: Int32, z: Int32, actualTop: Int32, surfaceDepth: Int) -> Int32 {
        if let preliminary = self.settings.noiseRouter.preliminarySurfaceLevel {
            return Int32(floor(preliminary.sample(at: PosInt3D(x: x, y: 0, z: z)))) + Int32(surfaceDepth) - 8
        }
        return actualTop + Int32(surfaceDepth) - 8
    }

    private func highestNonAirY(in chunk: ProtoChunk, x: Int32, z: Int32) -> Int32 {
        var localY = chunk.height - 1
        while localY >= 0 {
            if !chunk.block(atLocal: PosInt3D(x: x, y: localY, z: z)).type.isAir {
                return chunk.minY + localY
            }
            localY -= 1
        }
        return chunk.minY - 1
    }

    private func placeBadlandsPillar(in chunk: ProtoChunk, chunkPos: PosInt2D, x: Int32, z: Int32, surfaceY: Int32) {
        let worldX = chunkPos.x * 16 + x, worldZ = chunkPos.z * 16 + z
        guard let surface = self.sampleNoise("minecraft:badlands_surface", x: Double(worldX), y: 0, z: Double(worldZ)),
              let pillar = self.sampleNoise("minecraft:badlands_pillar", x: Double(worldX) * 0.2, y: 0, z: Double(worldZ) * 0.2),
              let roof = self.sampleNoise("minecraft:badlands_pillar_roof", x: Double(worldX) * 0.75, y: 0, z: Double(worldZ) * 0.75)
        else { return }
        let elevation = min(abs(surface * 8.25), pillar * 15)
        guard elevation > 0 else { return }
        let roofHeight = abs(roof * 1.5)
        let top = Int32(floor(64 + min(elevation * elevation * 2.5, ceil(roofHeight * 50) + 24)))
        guard surfaceY <= top else { return }
        let maximumY = chunk.minY + chunk.height - 1
        var scanY = min(top, maximumY)
        while scanY >= chunk.minY {
            let state = chunk.block(atLocal: PosInt3D(x: x, y: scanY - chunk.minY, z: z))
            if state.type.id == self.settings.defaultBlock.name { break }
            if state.type.id == "minecraft:water" { return }
            scanY -= 1
        }
        var fillY = min(top, maximumY)
        while fillY >= chunk.minY {
            let local = PosInt3D(x: x, y: fillY - chunk.minY, z: z)
            guard chunk.block(atLocal: local).type.isAir else { break }
            chunk.setBlock(self.settings.defaultBlock.blockState, atLocal: local)
            fillY -= 1
        }
    }

    private func placeIceberg(
        in chunk: ProtoChunk,
        chunkPos: PosInt2D,
        x: Int32,
        z: Int32,
        surfaceY: Int32,
        minimumY: Int32,
        biome: Biome?
    ) {
        let worldX = chunkPos.x * 16 + x, worldZ = chunkPos.z * 16 + z
        guard let surface = self.sampleNoise("minecraft:iceberg_surface", x: Double(worldX), y: 0, z: Double(worldZ)),
              let pillar = self.sampleNoise("minecraft:iceberg_pillar", x: Double(worldX) * 1.28, y: 0, z: Double(worldZ) * 1.28),
              let roof = self.sampleNoise("minecraft:iceberg_pillar_roof", x: Double(worldX) * 1.17, y: 0, z: Double(worldZ) * 1.17)
        else { return }
        let elevation = min(abs(surface * 8.25), pillar * 15)
        guard elevation > 1.8 else { return }
        var upper = min(elevation * elevation * 1.2, ceil(abs(roof * 1.5) * 40) + 14)
        if (biome?.temperature ?? 0) > 0.1 { upper -= 2 }
        var lower = 0.0
        if upper > 2 {
            lower = Double(self.settings.seaLevel) - upper - 7
            upper += Double(self.settings.seaLevel)
        } else {
            upper = 0
        }
        let targetTop = upper
        var random = self.randomDeriver.split(usingPos: PosInt3D(x: worldX, y: 0, z: worldZ))
        let snowDepth = 2 + Int(random.next(bound: 4))
        let snowLimit = Int32(self.settings.seaLevel + 18 + Int(random.next(bound: 10)))
        var snowPlaced = 0
        let packedIce = BlockState(type: Block(withID: "minecraft:packed_ice"))
        let snow = BlockState(type: Block(withID: "minecraft:snow_block"))
        var worldY = min(chunk.minY + chunk.height - 1, max(surfaceY, Int32(upper) + 1))
        while worldY >= max(chunk.minY, minimumY) {
            let local = PosInt3D(x: x, y: worldY - chunk.minY, z: z)
            let state = chunk.block(atLocal: local)
            let placeInAir = state.type.isAir && worldY < Int32(targetTop) && random.nextDouble() > 0.01
            let placeInWater = state.type.id == "minecraft:water" && worldY > Int32(lower)
                && worldY < Int32(self.settings.seaLevel) && lower != 0 && random.nextDouble() > 0.15
            if placeInAir || placeInWater {
                if snowPlaced <= snowDepth && worldY > snowLimit {
                    chunk.setBlock(snow, atLocal: local); snowPlaced += 1
                } else {
                    chunk.setBlock(packedIce, atLocal: local)
                }
            }
            worldY -= 1
        }
    }

    private static func isSteep(x: Int32, z: Int32, heights: [Int32]) -> Bool {
        func height(_ x: Int32, _ z: Int32) -> Int32 { heights[Int(z * 16 + x)] }
        let north = height(x, max(0, z - 1))
        let south = height(x, min(15, z + 1))
        if south >= north + 4 { return true }
        let west = height(max(0, x - 1), z)
        let east = height(min(15, x + 1), z)
        return west >= east + 4
    }

    private static func isFluid(_ state: BlockState) -> Bool {
        state.type.id == "minecraft:water" || state.type.id == "minecraft:lava"
    }

    private static func resolve(_ anchor: VerticalAnchor, minY: Int32, height: Int32) -> Int32 {
        switch anchor {
        case .absolute(let value): return Int32(value)
        case .aboveBottom(let value): return minY + Int32(value)
        case .belowTop(let value): return minY + height - 1 - Int32(value)
        }
    }

    private static func map(_ value: Double, fromLow: Double, fromHigh: Double, toLow: Double, toHigh: Double) -> Double {
        guard fromLow != fromHigh else { return toLow }
        let fraction = (value - fromLow) / (fromHigh - fromLow)
        return toLow + fraction * (toHigh - toLow)
    }

    private static func floorMod(_ value: Int, _ divisor: Int) -> Int {
        let remainder = value % divisor
        return remainder >= 0 ? remainder : remainder + divisor
    }

    private static func makeTerracottaBands(random: inout XoroshiroRandom) -> [BlockState] {
        func state(_ id: String) -> BlockState { BlockState(type: Block(withID: "minecraft:\(id)")) }
        var bands = [BlockState](repeating: state("terracotta"), count: 192)
        var index = 0
        while index < bands.count {
            index += Int(random.next(bound: 5)) + 2
            if index < bands.count { bands[index] = state("orange_terracotta") }
        }
        func addBands(_ minimumSize: Int, _ block: BlockState, random: inout XoroshiroRandom, bands: inout [BlockState]) {
            let count = 6 + Int(random.next(bound: 10))
            for _ in 0..<count {
                let size = minimumSize + Int(random.next(bound: 3))
                let start = Int(random.next(bound: UInt32(bands.count)))
                for offset in 0..<size where start + offset < bands.count { bands[start + offset] = block }
            }
        }
        addBands(1, state("yellow_terracotta"), random: &random, bands: &bands)
        addBands(2, state("brown_terracotta"), random: &random, bands: &bands)
        addBands(1, state("red_terracotta"), random: &random, bands: &bands)
        let whiteCount = 9 + Int(random.next(bound: 7))
        var placed = 0
        var whiteIndex = 0
        while placed < whiteCount && whiteIndex < bands.count {
            bands[whiteIndex] = state("white_terracotta")
            if whiteIndex > 1 && random.nextBoolean() { bands[whiteIndex - 1] = state("light_gray_terracotta") }
            if whiteIndex + 1 < bands.count && random.nextBoolean() { bands[whiteIndex + 1] = state("light_gray_terracotta") }
            placed += 1
            whiteIndex += Int(random.next(bound: 16)) + 4
        }
        return bands
    }
}
