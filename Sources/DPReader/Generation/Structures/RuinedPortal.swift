/// Complete generated state for one ruined portal.
public struct RuinedPortalGenerationResult {
    public let graph: PieceGraph
    public let blocks: StructureBlockVolume
    public let lootContainers: [StructureLootContainer]
}

private enum RuinedPortalMirror {
    case none
    case frontBack
}

private enum RuinedPortalRotation: Int {
    case none = 0
    case clockwise90
    case clockwise180
    case counterclockwise90
}

public final class RuinedPortalPiece: StructurePiece {
    public let templateName: String
    public let placementOrigin: PosInt3D
    public let placement: RuinedPortalPlacement
    public let rotationQuarterTurns: Int
    public let isMirrored: Bool

    fileprivate let template: StructureTemplate
    fileprivate let setup: RuinedPortalSetup
    fileprivate let airPocket: Bool
    fileprivate let transform: RuinedPortalTransform
    fileprivate var generatedLoot: [StructureLootContainer] = []

    fileprivate init(
        templateName: String,
        template: StructureTemplate,
        origin: PosInt3D,
        setup: RuinedPortalSetup,
        airPocket: Bool,
        rotation: RuinedPortalRotation,
        mirror: RuinedPortalMirror
    ) {
        let pivot = PosInt3D(x: template.size.x / 2, y: 0, z: template.size.z / 2)
        let transform = RuinedPortalTransform(rotation: rotation, mirror: mirror, pivot: pivot)
        self.templateName = templateName
        self.template = template
        self.placementOrigin = origin
        self.placement = setup.placement
        self.rotationQuarterTurns = rotation.rawValue
        self.isMirrored = mirror == .frontBack
        self.setup = setup
        self.airPocket = airPocket
        self.transform = transform
        super.init(orientation: transform.orientation, boundingBox: transform.bounds(size: template.size, origin: origin))
    }

    override var cachesGeneratedContents: Bool { false }

    override func postProcess<R: Random>(in world: StructureWorldView, chunkBox: BoundingBox, random: inout R) {
        // Vanilla expands the containing chunk's box and writes the entire portal only from the
        // chunk containing the template center.
        guard chunkBox.contains(PosInt3D(
            x: (self.boundingBox.minX + self.boundingBox.maxX + 1) / 2,
            y: (self.boundingBox.minY + self.boundingBox.maxY + 1) / 2,
            z: (self.boundingBox.minZ + self.boundingBox.maxZ + 1) / 2
        )) else { return }

        let palette = self.template.palette(at: self.placementOrigin)
        for block in self.template.blocks {
            guard block.state >= 0, block.state < palette.count else { continue }
            var state = palette[block.state]
            if state.id == "minecraft:structure_block" { continue }
            if self.airPocket && state.isAir {
                // Air-pocket setups retain template air. Other setups use IGNORE_AIR.
            } else if !self.airPocket && state.isAir {
                continue
            }
            let pos = self.transform.position(block.pos).portalAdding(self.placementOrigin)
            state = self.process(state: state, at: pos)
            world.setBlock(self.transform.state(state), at: pos)
            if let table = block.nbt?.portalCompoundString("LootTable") {
                let seed = Int64(bitPattern: random.nextLong())
                self.generatedLoot.append(StructureLootContainer(
                    block: state.id, pos: pos, lootTable: table, lootSeed: seed
                ))
            }
        }

        self.placeNetherrackBase(in: world, random: &random)
    }

    private func process(state: BlockState, at position: PosInt3D) -> BlockState {
        var positional = Self.positionalRandom(at: position)
        switch state.id {
        case "minecraft:gold_block" where positional.nextFloat() < 0.3:
            return Blocks.airState
        case "minecraft:lava":
            if self.placement == .onOceanFloor { return BlockState(id: "minecraft:magma_block") }
            if self.setup.canBeCold { return BlockState(id: "minecraft:netherrack") }
            return positional.nextFloat() < 0.2 ? BlockState(id: "minecraft:magma_block") : state
        case "minecraft:netherrack" where !self.setup.canBeCold && positional.nextFloat() < 0.07:
            return BlockState(id: "minecraft:magma_block")
        default:
            return state
        }
    }

    private static func positionalRandom(at position: PosInt3D) -> CheckedRandom {
        let xProduct = position.x &* 3_129_871
        var seed = Int64(xProduct) ^ (Int64(position.z) &* 116_129_781) ^ Int64(position.y)
        seed = seed &* seed &* 42_317_861 &+ seed &* 11
        return CheckedRandom(seed: UInt64(bitPattern: seed >> 16))
    }

    private func placeNetherrackBase<R: Random>(in world: StructureWorldView, random: inout R) {
        let centerX = (self.boundingBox.minX + self.boundingBox.maxX + 1) / 2
        let centerZ = (self.boundingBox.minZ + self.boundingBox.maxZ + 1) / 2
        let chances: [Float] = [1, 1, 1, 1, 1, 1, 1, 0.9, 0.9, 0.8, 0.7, 0.6, 0.4, 0.2]
        let averageSide = ((self.boundingBox.maxX - self.boundingBox.minX + 1)
            + (self.boundingBox.maxZ - self.boundingBox.minZ + 1)) / 2
        let offset = Int32(random.next(bound: UInt32(max(1, 8 - averageSide / 2))))
        for x in (centerX - 14)...(centerX + 14) {
            for z in (centerZ - 14)...(centerZ + 14) {
                let distance = abs(x - centerX) + abs(z - centerZ) + offset
                guard distance >= 0, distance < Int32(chances.count), random.nextDouble() < Double(chances[Int(distance)]) else { continue }
                let surface = self.surfaceY(in: world, x: x, z: z)
                let surfacePlacement = self.placement == .onLandSurface || self.placement == .onOceanFloor
                let y = surfacePlacement ? surface : min(self.boundingBox.minY, surface)
                guard abs(y - self.boundingBox.minY) <= 3 else { continue }
                let pos = PosInt3D(x: x, y: y, z: z)
                let existing = world.block(at: pos)
                guard !existing.isAir, existing.id != "minecraft:obsidian", existing.id != "minecraft:lava" else { continue }
                let state = !self.setup.canBeCold && random.nextFloat() < 0.07
                    ? BlockState(id: "minecraft:magma_block")
                    : BlockState(id: "minecraft:netherrack")
                world.setBlock(state, at: pos)
            }
        }
    }

    private func surfaceY(in world: StructureWorldView, x: Int32, z: Int32) -> Int32 {
        for y in stride(from: world.volume.bounds.maxY, through: world.minimumWorldY, by: -1) {
            let state = world.block(at: PosInt3D(x: x, y: y, z: z))
            if !state.isAir && (self.placement != .onOceanFloor || (state.id != "minecraft:water" && state.id != "minecraft:lava")) {
                return y
            }
        }
        return world.minimumWorldY
    }
}

public enum RuinedPortal {
    private static let commonTemplates = (1...10).map { "minecraft:ruined_portal/portal_\($0)" }
    private static let rareTemplates = (1...3).map { "minecraft:ruined_portal/giant_portal_\($0)" }

    public static func generatePieceGraph(
        settings: RuinedPortalStructureSettings,
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) throws -> PieceGraph {
        var random = checkedRandomForChunkGeneration(worldSeed: worldSeed, chunkX: startChunk.x, chunkZ: startChunk.z)
        let setup = self.selectSetup(settings.setups, random: &random)
        let airPocket = self.airPocket(setup.airPocketProbability, random: &random)
        let names = random.nextFloat() < 0.05 ? self.rareTemplates : self.commonTemplates
        let templateName = names[Int(random.next(bound: UInt32(names.count)))]
        guard let template = context.structureTemplate(named: templateName) else {
            throw StructureGenerationError.missingStructureTemplate(templateName)
        }
        let rotation = RuinedPortalRotation(rawValue: Int(random.next(bound: 4)))!
        let mirror: RuinedPortalMirror = random.nextFloat() < 0.5 ? .none : .frontBack
        let pivot = PosInt3D(x: template.size.x / 2, y: 0, z: template.size.z / 2)
        let transform = RuinedPortalTransform(rotation: rotation, mirror: mirror, pivot: pivot)
        let startX = startChunk.x << 4
        let startZ = startChunk.z << 4
        let horizontalBounds = transform.bounds(size: template.size, origin: PosInt3D(x: startX, y: 0, z: startZ))
        let centerX = (horizontalBounds.minX + horizontalBounds.maxX + 1) / 2
        let centerZ = (horizontalBounds.minZ + horizontalBounds.maxZ + 1) / 2
        let surface = self.height(
            atX: centerX, z: centerZ, oceanFloor: setup.placement == .onOceanFloor, context: context
        ) - 1
        var targetY = self.initialY(
            setup: setup, surface: surface, templateHeight: template.size.y,
            minimumWorldY: context.minimumWorldY, random: &random
        )
        let minimum = context.minimumWorldY + 15
        while targetY > minimum {
            var supported = 0
            for (x, z) in [
                (horizontalBounds.minX, horizontalBounds.minZ), (horizontalBounds.maxX, horizontalBounds.minZ),
                (horizontalBounds.minX, horizontalBounds.maxZ), (horizontalBounds.maxX, horizontalBounds.maxZ)
            ] {
                let state = context.blockSampler(PosInt3D(x: x, y: targetY, z: z))
                // Vanilla's support check requires a solid block. Fluids do not support an
                // on-land portal either: otherwise a portal floating on sea-level water stops
                // one block too high instead of descending to the ocean floor.
                let isSupport = !state.isAir
                    && state.id != "minecraft:water"
                    && state.id != "minecraft:lava"
                if isSupport { supported += 1; if supported == 3 { break } }
            }
            if supported >= 3 { break }
            targetY -= 1
        }
        let origin = PosInt3D(x: startX, y: targetY, z: startZ)
        let piece = RuinedPortalPiece(
            templateName: templateName, template: template, origin: origin,
            setup: setup, airPocket: airPocket, rotation: rotation, mirror: mirror
        )
        return PieceGraph(startChunk: startChunk, orientation: piece.orientation, boundingBox: piece.boundingBox, pieces: [piece])
    }

    public static func generate(
        settings: RuinedPortalStructureSettings,
        worldSeed: WorldSeed,
        startChunk: PosInt2D,
        context: StructureGenerationContext
    ) throws -> RuinedPortalGenerationResult {
        let graph = try self.generatePieceGraph(settings: settings, worldSeed: worldSeed, startChunk: startChunk, context: context)
        let spreadBounds = BoundingBox(
            minX: graph.boundingBox.minX - 14, minY: context.minimumWorldY, minZ: graph.boundingBox.minZ - 14,
            maxX: graph.boundingBox.maxX + 14, maxY: context.maximumWorldY, maxZ: graph.boundingBox.maxZ + 14
        )
        let volume = StructureBlockVolume(bounds: spreadBounds, fallbackSampler: context.blockSampler)
        let world = StructureWorldView(seaLevel: context.seaLevel, minimumWorldY: context.minimumWorldY, volume: volume)
        let decoration = context.structureDecorationParameters(forStructureID: "minecraft:ruined_portal")
            ?? StructureDecorationParameters(step: StructureGenerationStep.surfaceStructures.rawIndex, index: 0)
        for chunkZ in (graph.boundingBox.minZ >> 4)...(graph.boundingBox.maxZ >> 4) {
            for chunkX in (graph.boundingBox.minX >> 4)...(graph.boundingBox.maxX >> 4) {
                let box = BoundingBox(
                    minX: chunkX << 4, minY: context.minimumWorldY, minZ: chunkZ << 4,
                    maxX: (chunkX << 4) + 15, maxY: context.maximumWorldY, maxZ: (chunkZ << 4) + 15
                )
                var random = getStructureGenerationRandom(
                    worldSeed: worldSeed, chunkX: chunkX, chunkZ: chunkZ,
                    decoratorIndex: decoration.index, decoratorStep: decoration.step
                )
                graph.pieces[0].write(in: world, chunkBox: box, random: &random)
            }
        }
        let loot = (graph.pieces[0] as? RuinedPortalPiece)?.generatedLoot ?? []
        return RuinedPortalGenerationResult(graph: graph, blocks: volume, lootContainers: loot)
    }

    private static func selectSetup<R: Random>(_ setups: [RuinedPortalSetup], random: inout R) -> RuinedPortalSetup {
        guard setups.count > 1 else { return setups[0] }
        let total = setups.reduce(0.0) { $0 + $1.weight }
        var value = Double(random.nextFloat())
        for setup in setups {
            value -= setup.weight / total
            if value < 0 { return setup }
        }
        return setups.last!
    }

    private static func airPocket<R: Random>(_ probability: Double, random: inout R) -> Bool {
        if probability == 0 { return false }
        if probability == 1 { return true }
        return Double(random.nextFloat()) < probability
    }

    private static func initialY<R: Random>(
        setup: RuinedPortalSetup, surface: Int32, templateHeight: Int32,
        minimumWorldY: Int32, random: inout R
    ) -> Int32 {
        let minimum = minimumWorldY + 15
        func between(_ a: Int32, _ b: Int32) -> Int32 {
            guard a < b else { return b }
            return a + Int32(random.next(bound: UInt32(b - a + 1)))
        }
        switch setup.placement {
        case .inNether:
            if setup.airPocketProbability == 1 { return between(32, 100) }
            return random.nextFloat() < 0.5 ? between(27, 29) : between(29, 100)
        case .inMountain: return between(70, surface - templateHeight)
        case .underground: return between(minimum, surface - templateHeight)
        case .partlyBuried: return surface - templateHeight + between(2, 8)
        case .onLandSurface, .onOceanFloor: return surface
        }
    }

    private static func height(atX x: Int32, z: Int32, oceanFloor: Bool, context: StructureGenerationContext) -> Int32 {
        for y in stride(from: context.maximumWorldY, through: context.minimumWorldY, by: -1) {
            let state = context.blockSampler(PosInt3D(x: x, y: y, z: z))
            if state.isAir { continue }
            if oceanFloor && (state.id == "minecraft:water" || state.id == "minecraft:lava") { continue }
            return y + 1
        }
        return context.minimumWorldY
    }
}

private struct RuinedPortalTransform {
    let rotation: RuinedPortalRotation
    let mirror: RuinedPortalMirror
    let pivot: PosInt3D

    var orientation: CardinalDirection {
        switch self.rotation { case .none: return .south; case .clockwise90: return .west; case .clockwise180: return .north; case .counterclockwise90: return .east }
    }

    func position(_ pos: PosInt3D) -> PosInt3D {
        let x = self.mirror == .frontBack ? -pos.x : pos.x
        let z = pos.z
        switch self.rotation {
        case .none: return PosInt3D(x: x, y: pos.y, z: z)
        case .counterclockwise90: return PosInt3D(x: self.pivot.x - self.pivot.z + z, y: pos.y, z: self.pivot.x + self.pivot.z - x)
        case .clockwise90: return PosInt3D(x: self.pivot.x + self.pivot.z - z, y: pos.y, z: self.pivot.z - self.pivot.x + x)
        case .clockwise180: return PosInt3D(x: self.pivot.x * 2 - x, y: pos.y, z: self.pivot.z * 2 - z)
        }
    }

    func bounds(size: PosInt3D, origin: PosInt3D) -> BoundingBox {
        let a = self.position(PosInt3D(x: 0, y: 0, z: 0)).portalAdding(origin)
        let b = self.position(PosInt3D(x: size.x - 1, y: size.y - 1, z: size.z - 1)).portalAdding(origin)
        return .fromCorners(a, b)
    }

    func state(_ state: BlockState) -> BlockState {
        // Portal templates primarily need horizontal facing and axis transforms.
        guard var properties = state.properties else { return state }
        if self.mirror == .frontBack {
            if properties["facing"] == "east" { properties["facing"] = "west" }
            else if properties["facing"] == "west" { properties["facing"] = "east" }
        }
        let turns = self.rotation == .counterclockwise90 ? 3 : self.rotation.rawValue
        for _ in 0..<turns {
            if let facing = properties["facing"] {
                properties["facing"] = ["north":"east", "east":"south", "south":"west", "west":"north"][facing] ?? facing
            }
        }
        if (self.rotation == .clockwise90 || self.rotation == .counterclockwise90), let axis = properties["axis"] {
            properties["axis"] = axis == "x" ? "z" : axis == "z" ? "x" : axis
        }
        return BlockState(id: state.id, properties: properties)
    }
}

private extension PosInt3D {
    func portalAdding(_ other: PosInt3D) -> PosInt3D {
        PosInt3D(x: self.x &+ other.x, y: self.y &+ other.y, z: self.z &+ other.z)
    }
}

private extension NBTTag {
    func portalCompoundString(_ key: String) -> String? {
        guard case .compound(let values) = self, case .string(let value)? = values[key] else { return nil }
        return value
    }
}
