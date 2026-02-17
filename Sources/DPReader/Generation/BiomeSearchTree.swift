import Foundation

public enum BiomeSearchTreeError: Error {
    case emptyEntries
    case missingBiome(String)
}

public final class BiomeSearchTree {
    private let root: BiomeTreeNode

    public init(entries: [(NoiseHypercube, RegistryKey<Biome>)]) throws {
        guard !entries.isEmpty else {
            throw BiomeSearchTreeError.emptyEntries
        }
        var converted: [BiomeTreeNode] = []
        converted.reserveCapacity(entries.count)
        for entry in entries {
            converted.append(BiomeTreeNode(parameters: entry.0.toList(), value: entry.1, children: []))
        }
        self.root = try BiomeTreeNode.createNode(from: converted)
    }

    public func get(_ point: NoisePoint) throws -> RegistryKey<Biome> {
        let state = self.lookupStateForCurrentThread()
        self.updateScratchPoint(from: point, into: &state.scratchPoint)
        let result = self.root.getResultingNode(point: state.scratchPoint, alternative: state.lastResult)
        guard let value = result.value else {
            throw BiomeSearchTreeError.emptyEntries
        }
        state.lastResult = result
        return value
    }

    @inline(__always)
    func getUnchecked(_ point: NoisePoint) -> RegistryKey<Biome> {
        let state = self.lookupStateForCurrentThread()
        self.updateScratchPoint(from: point, into: &state.scratchPoint)
        let result = self.root.getResultingNode(point: state.scratchPoint, alternative: state.lastResult)
        precondition(result.value != nil, "BiomeSearchTree returned an empty result node")
        let value = result.value!
        state.lastResult = result
        return value
    }

    @inline(__always)
    func getUnchecked(
        temperature: Double,
        humidity: Double,
        continentalness: Double,
        erosion: Double,
        weirdness: Double,
        depth: Double
    ) -> RegistryKey<Biome> {
        let state = self.lookupStateForCurrentThread()
        self.updateScratchPoint(
            temperature: temperature,
            humidity: humidity,
            continentalness: continentalness,
            erosion: erosion,
            weirdness: weirdness,
            depth: depth,
            into: &state.scratchPoint
        )
        let result = self.root.getResultingNode(point: state.scratchPoint, alternative: state.lastResult)
        precondition(result.value != nil, "BiomeSearchTree returned an empty result node")
        let value = result.value!
        state.lastResult = result
        return value
    }

    /// Resets the tree's internal "alternative".
    /// Useful for deterministic results, but will result in a massive performance hit.
    public func resetAlternative() {
        self.lookupStateForCurrentThread().lastResult = self.makeEmptyNode()
    }

    // Internal helper for diagnostics.
    func lastResultDistance(to point: NoisePoint) -> Int64? {
        let state = self.lookupStateForCurrentThread()
        guard state.lastResult.value != nil else { return nil }
        self.updateScratchPoint(from: point, into: &state.scratchPoint)
        return squaredDistance(parameters: state.lastResult.parameters, point: state.scratchPoint)
    }

    private func updateScratchPoint(from point: NoisePoint, into scratchPoint: inout [Int64]) {
        self.updateScratchPoint(
            temperature: point.temperature,
            humidity: point.humidity,
            continentalness: point.continentalness,
            erosion: point.erosion,
            weirdness: point.weirdness,
            depth: point.depth,
            into: &scratchPoint
        )
    }

    @inline(__always)
    private func updateScratchPoint(
        temperature: Double,
        humidity: Double,
        continentalness: Double,
        erosion: Double,
        weirdness: Double,
        depth: Double,
        into scratchPoint: inout [Int64]
    ) {
        scratchPoint[0] = Int64(temperature * 10000.0)
        scratchPoint[1] = Int64(humidity * 10000.0)
        scratchPoint[2] = Int64(continentalness * 10000.0)
        scratchPoint[3] = Int64(erosion * 10000.0)
        scratchPoint[4] = Int64(depth * 10000.0)
        scratchPoint[5] = Int64(weirdness * 10000.0)
        scratchPoint[6] = 0
    }

    private func lookupStateForCurrentThread() -> LookupState {
        let key = self.lookupStateThreadDictionaryKey
        if let existing = Thread.current.threadDictionary[key] as? LookupState {
            return existing
        }
        let state = LookupState(lastResult: self.makeEmptyNode(), scratchPoint: Array(repeating: 0, count: 7))
        Thread.current.threadDictionary[key] = state
        return state
    }

    // Internal helper for diagnostics and tests.
    func nodes(with biome: RegistryKey<Biome>) -> [BiomeTreeNode] {
        return self.root.nodes(with: biome)
    }

    private var lookupStateThreadDictionaryKey: String {
        let pointer = UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())
        return "BiomeSearchTree.lookupState.\(pointer)"
    }

    private func makeEmptyNode() -> BiomeTreeNode {
        return BiomeTreeNode(parameters: [], value: nil, children: [])
    }
}

private final class LookupState {
    var lastResult: BiomeTreeNode
    var scratchPoint: [Int64]

    init(lastResult: BiomeTreeNode, scratchPoint: [Int64]) {
        self.lastResult = lastResult
        self.scratchPoint = scratchPoint
    }
}

public func buildBiomeSearchTree(from biomeRegistry: Registry<Biome>, entries: [MultiNoiseBiomeSourceBiome]) throws -> BiomeSearchTree {
    var mapped: [(NoiseHypercube, RegistryKey<Biome>)] = []
    mapped.reserveCapacity(entries.count)
    for entry in entries {
        let key = RegistryKey<Biome>(referencing: entry.biome)
        guard biomeRegistry.get(key) != nil else {
            throw BiomeSearchTreeError.missingBiome(entry.biome)
        }
        mapped.append((NoiseHypercube(from: entry.parameters), key))
    }
    return try BiomeSearchTree(entries: mapped)
}

public struct NoiseHypercube {
    let temperature: ParameterRange
    let humidity: ParameterRange
    let continentalness: ParameterRange
    let erosion: ParameterRange
    let depth: ParameterRange
    let weirdness: ParameterRange
    let offset: ParameterRange

    public init(
        temperature: ParameterRange,
        humidity: ParameterRange,
        continentalness: ParameterRange,
        erosion: ParameterRange,
        depth: ParameterRange,
        weirdness: ParameterRange,
        offset: ParameterRange
    ) {
        self.temperature = temperature
        self.humidity = humidity
        self.continentalness = continentalness
        self.erosion = erosion
        self.depth = depth
        self.weirdness = weirdness
        self.offset = offset
    }

    public init(from parameters: MultiNoiseBiomeSourceParameters) {
        self.temperature = ParameterRange(parameters.temperature)
        self.humidity = ParameterRange(parameters.humidity)
        self.continentalness = ParameterRange(parameters.continentalness)
        self.erosion = ParameterRange(parameters.erosion)
        self.depth = ParameterRange(parameters.depth)
        self.weirdness = ParameterRange(parameters.weirdness)
        self.offset = ParameterRange(parameters.offset)
    }

    func toList() -> [ParameterRange] {
        return [temperature, humidity, continentalness, erosion, depth, weirdness, offset]
    }
}

public struct ParameterRange: Equatable {
    let min: Int64
    let max: Int64

    init(min: Int64, max: Int64) {
        self.min = min
        self.max = max
    }

    init(_ range: BiomeParameterRange) {
        self.min = Int64(range.min * 10000.0)
        self.max = Int64(range.max * 10000.0)
    }

    func combine(_ other: ParameterRange?) -> ParameterRange {
        guard let other else { return self }
        return ParameterRange(min: Swift.min(self.min, other.min), max: Swift.max(self.max, other.max))
    }

    func distance(to point: Int64) -> Int64 {
        if point > self.max { return point - self.max }
        if point < self.min { return self.min - point }
        return 0
    }
}

final class BiomeTreeNode {
    let parameters: [ParameterRange]
    let children: [BiomeTreeNode]
    let value: RegistryKey<Biome>?

    init(parameters: [ParameterRange], value: RegistryKey<Biome>?, children: [BiomeTreeNode]) {
        self.parameters = parameters
        self.value = value
        self.children = children
    }

    func getResultingNode(point: [Int64], alternative: BiomeTreeNode) -> BiomeTreeNode {
        if self.value != nil { return self }
        var ret = alternative
        var retDistance = alternative.value != nil ? squaredDistance(parameters: alternative.parameters, point: point) : Int64.max
        for child in self.children {
            let distance = squaredDistanceBounded(parameters: child.parameters, point: point, maxDistance: retDistance)
            if retDistance < distance { continue }
            let endNode = child.getResultingNode(point: point, alternative: alternative)
            guard endNode.value != nil else {
                continue
            }
            let endDistance = sameBiome(endNode.value, child.value)
                ? distance
                : squaredDistanceBounded(parameters: endNode.parameters, point: point, maxDistance: retDistance)
            if retDistance < endDistance { continue }
            retDistance = endDistance
            ret = endNode
        }
        return ret
    }

    func nodes(with biome: RegistryKey<Biome>) -> [BiomeTreeNode] {
        var matches: [BiomeTreeNode] = []
        if self.value == biome {
            matches.append(self)
        }
        for child in self.children {
            matches.append(contentsOf: child.nodes(with: biome))
        }
        return matches
    }

    static func createNode(from children: [BiomeTreeNode]) throws -> BiomeTreeNode {
        guard !children.isEmpty else { throw BiomeSearchTreeError.emptyEntries }
        if children.count == 1 { return children[0] }
        if children.count <= 6 {
            let sorted = children.sorted { a, b in
                let aOut = a.parameters.reduce(Int64(0)) { $0 + abs(($1.min + $1.max) / 2) }
                let bOut = b.parameters.reduce(Int64(0)) { $0 + abs(($1.min + $1.max) / 2) }
                return aOut > bOut
            }
            return BiomeTreeNode(parameters: enclosingParameters(from: sorted), value: nil, children: sorted)
        }

        var span = Int64.max
        var param = -1
        var out: [BiomeTreeNode] = []
        for i in 0..<7 {
            let sorted = sortTree(children: children, currentParameter: i, absSort: false)
            let batched = batchTree(children: sorted)
            var innerSpan: Int64 = 0
            for batch in batched {
                for p in batch.parameters {
                    innerSpan += p.max - p.min
                }
            }
            if innerSpan >= span { continue }
            span = innerSpan
            param = i
            out = batched
        }

        let sortedOut = sortTree(children: out, currentParameter: param, absSort: true)
        var retChildren: [BiomeTreeNode] = []
        retChildren.reserveCapacity(sortedOut.count)
        for node in sortedOut {
            retChildren.append(try createNode(from: node.children))
        }
        return BiomeTreeNode(parameters: enclosingParameters(from: retChildren), value: nil, children: retChildren)
    }
}

private func sameBiome(_ a: RegistryKey<Biome>?, _ b: RegistryKey<Biome>?) -> Bool {
    guard let a, let b else { return false }
    return a == b
}

private func squaredDistance(parameters: [ParameterRange], point: [Int64]) -> Int64 {
    let d0 = parameters[0].distance(to: point[0])
    let d1 = parameters[1].distance(to: point[1])
    let d2 = parameters[2].distance(to: point[2])
    let d3 = parameters[3].distance(to: point[3])
    let d4 = parameters[4].distance(to: point[4])
    let d5 = parameters[5].distance(to: point[5])
    let d6 = parameters[6].distance(to: point[6])
    return d0 * d0 + d1 * d1 + d2 * d2 + d3 * d3 + d4 * d4 + d5 * d5 + d6 * d6
}

private func squaredDistanceBounded(parameters: [ParameterRange], point: [Int64], maxDistance: Int64) -> Int64 {
    let d0 = parameters[0].distance(to: point[0])
    var out = d0 * d0
    if out > maxDistance { return maxDistance == Int64.max ? maxDistance : maxDistance + 1 }
    let d1 = parameters[1].distance(to: point[1])
    out += d1 * d1
    if out > maxDistance { return maxDistance == Int64.max ? maxDistance : maxDistance + 1 }
    let d2 = parameters[2].distance(to: point[2])
    out += d2 * d2
    if out > maxDistance { return maxDistance == Int64.max ? maxDistance : maxDistance + 1 }
    let d3 = parameters[3].distance(to: point[3])
    out += d3 * d3
    if out > maxDistance { return maxDistance == Int64.max ? maxDistance : maxDistance + 1 }
    let d4 = parameters[4].distance(to: point[4])
    out += d4 * d4
    if out > maxDistance { return maxDistance == Int64.max ? maxDistance : maxDistance + 1 }
    let d5 = parameters[5].distance(to: point[5])
    out += d5 * d5
    if out > maxDistance { return maxDistance == Int64.max ? maxDistance : maxDistance + 1 }
    let d6 = parameters[6].distance(to: point[6])
    out += d6 * d6
    return out
}

private func enclosingParameters(from nodes: [BiomeTreeNode]) -> [ParameterRange] {
    precondition(!nodes.isEmpty)
    var res: [ParameterRange?] = Array(repeating: nil, count: 7)
    for node in nodes {
        for i in 0..<7 {
            res[i] = node.parameters[i].combine(res[i])
        }
    }
    return res.map { $0! }
}

private func sortTree(children: [BiomeTreeNode], currentParameter: Int, absSort: Bool) -> [BiomeTreeNode] {
    return children.sorted { a, b in
        for i in 0..<7 {
            let idx = (currentParameter + i) % 7
            let aOut = (a.parameters[idx].min + a.parameters[idx].max) / 2
            let bOut = (b.parameters[idx].min + b.parameters[idx].max) / 2
            let aVal = absSort ? abs(aOut) : aOut
            let bVal = absSort ? abs(bOut) : bOut
            if aVal > bVal { return true }
            if aVal < bVal { return false }
        }
        return false
    }
}

private func batchTree(children: [BiomeTreeNode]) -> [BiomeTreeNode] {
    var ret: [BiomeTreeNode] = []
    var inner: [BiomeTreeNode] = []
    let count = Int(pow(6.0, floor(log(Double(children.count) - 0.01) / log(6.0))))
    for child in children {
        inner.append(child)
        if inner.count < count { continue }
        ret.append(BiomeTreeNode(parameters: enclosingParameters(from: inner), value: nil, children: inner))
        inner = []
    }
    if !inner.isEmpty {
        ret.append(BiomeTreeNode(parameters: enclosingParameters(from: inner), value: nil, children: inner))
    }
    return ret
}

private extension NoisePoint {
    func toList() -> [Int64] {
        return [
            Int64(self.temperature * 10000.0),
            Int64(self.humidity * 10000.0),
            Int64(self.continentalness * 10000.0),
            Int64(self.erosion * 10000.0),
            Int64(self.depth * 10000.0),
            Int64(self.weirdness * 10000.0),
            0
        ]
    }
}

public func getPredefinedBiomeSearchTreeData(for preset: String) -> [MultiNoiseBiomeSourceBiome]? {
    switch preset {
    case "overworld":
        return OverworldBiomeSearchTreeDataCache.cached
    default:
        return nil
    }
}

private func buildOverworldBiomeSearchTreeData() -> [MultiNoiseBiomeSourceBiome] {
    func range(_ min: Double, _ max: Double) -> BiomeParameterRange {
        return BiomeParameterRange(min: min, max: max)
    }

    func combine(_ a: BiomeParameterRange, _ b: BiomeParameterRange) -> BiomeParameterRange {
        return BiomeParameterRange(min: Swift.min(a.min, b.min), max: Swift.max(a.max, b.max))
    }

    let defaultRange = range(-1.0, 1.0)

    let temperatureParameters = [
        range(-1.0, -0.45),
        range(-0.45, -0.15),
        range(-0.15, 0.2),
        range(0.2, 0.55),
        range(0.55, 1.0)
    ]

    let humidityParameters = [
        range(-1.0, -0.35),
        range(-0.35, -0.1),
        range(-0.1, 0.1),
        range(0.1, 0.3),
        range(0.3, 1.0)
    ]

    let erosionParameters = [
        range(-1.0, -0.78),
        range(-0.78, -0.375),
        range(-0.375, -0.2225),
        range(-0.2225, 0.05),
        range(0.05, 0.45),
        range(0.45, 0.55),
        range(0.55, 1.0)
    ]

    let nonFrozenParameters = range(-0.45, 1.0)
    let coastContinentalness = range(-0.19, -0.11)
    let riverContinentalness = range(-0.11, 0.55)
    let nearInlandContinentalness = range(-0.11, 0.03)
    let midInlandContinentalness = range(0.03, 0.3)
    let farInlandContinentalness = range(0.3, 1.0)

    let THE_VOID = "minecraft:the_void"

    let oceanBiomes = [
        [
            "minecraft:deep_frozen_ocean",
            "minecraft:deep_cold_ocean",
            "minecraft:deep_ocean",
            "minecraft:deep_lukewarm_ocean",
            "minecraft:warm_ocean"
        ],
        [
            "minecraft:frozen_ocean",
            "minecraft:cold_ocean",
            "minecraft:ocean",
            "minecraft:lukewarm_ocean",
            "minecraft:warm_ocean"
        ]
    ]

    let commonBiomes = [
        ["minecraft:snowy_plains", "minecraft:snowy_plains", "minecraft:snowy_plains", "minecraft:snowy_taiga", "minecraft:taiga"],
        ["minecraft:plains", "minecraft:plains", "minecraft:forest", "minecraft:taiga", "minecraft:old_growth_spruce_taiga"],
        ["minecraft:flower_forest", "minecraft:plains", "minecraft:forest", "minecraft:birch_forest", "minecraft:dark_forest"],
        ["minecraft:savanna", "minecraft:savanna", "minecraft:forest", "minecraft:jungle", "minecraft:jungle"],
        ["minecraft:desert", "minecraft:desert", "minecraft:desert", "minecraft:desert", "minecraft:desert"]
    ]

    let uncommonBiomes = [
        ["minecraft:ice_spikes", THE_VOID, "minecraft:snowy_taiga", THE_VOID, THE_VOID],
        [THE_VOID, THE_VOID, THE_VOID, THE_VOID, "minecraft:old_growth_pine_taiga"],
        ["minecraft:sunflower_plains", THE_VOID, THE_VOID, "minecraft:old_growth_birch_forest", THE_VOID],
        [THE_VOID, THE_VOID, "minecraft:plains", "minecraft:sparse_jungle", "minecraft:bamboo_jungle"],
        [THE_VOID, THE_VOID, THE_VOID, THE_VOID, THE_VOID]
    ]

    let nearMountainBiomes = [
        ["minecraft:snowy_plains", "minecraft:snowy_plains", "minecraft:snowy_plains", "minecraft:snowy_taiga", "minecraft:snowy_taiga"],
        ["minecraft:meadow", "minecraft:meadow", "minecraft:forest", "minecraft:taiga", "minecraft:old_growth_spruce_taiga"],
        // About the pale_garden entry: Cubiomes has it in specialNearMountainBiomes, whereas modern versions of Minecraft
        // have it as a normal near mountain biome to make it more common.
        // We agree with modern Minecraft here.
        ["minecraft:meadow", "minecraft:meadow", "minecraft:meadow", "minecraft:meadow", "minecraft:pale_garden"],
        ["minecraft:savanna_plateau", "minecraft:savanna_plateau", "minecraft:forest", "minecraft:forest", "minecraft:jungle"],
        ["minecraft:badlands", "minecraft:badlands", "minecraft:badlands", "minecraft:wooded_badlands", "minecraft:wooded_badlands"]
    ]

    let specialNearMountainBiomes = [
        ["minecraft:ice_spikes", THE_VOID, THE_VOID, THE_VOID, THE_VOID],
        ["minecraft:cherry_grove", THE_VOID, "minecraft:meadow", "minecraft:meadow", "minecraft:old_growth_pine_taiga"],
        ["minecraft:cherry_grove", "minecraft:cherry_grove", "minecraft:forest", "minecraft:birch_forest", THE_VOID],
        [THE_VOID, THE_VOID, THE_VOID, THE_VOID, THE_VOID],
        ["minecraft:eroded_badlands", "minecraft:eroded_badlands", THE_VOID, THE_VOID, THE_VOID]
    ]

    let windsweptBiomes = [
        ["minecraft:windswept_gravelly_hills", "minecraft:windswept_gravelly_hills", "minecraft:windswept_hills", "minecraft:windswept_forest", "minecraft:windswept_forest"],
        ["minecraft:windswept_gravelly_hills", "minecraft:windswept_gravelly_hills", "minecraft:windswept_hills", "minecraft:windswept_forest", "minecraft:windswept_forest"],
        ["minecraft:windswept_hills", "minecraft:windswept_hills", "minecraft:windswept_hills", "minecraft:windswept_forest", "minecraft:windswept_forest"],
        [THE_VOID, THE_VOID, THE_VOID, THE_VOID, THE_VOID],
        [THE_VOID, THE_VOID, THE_VOID, THE_VOID, THE_VOID]
    ]

    func getRegularBiome(_ temperature: Int, _ humidity: Int, _ weirdness: BiomeParameterRange) -> String {
        if weirdness.max < 0 {
            return commonBiomes[temperature][humidity]
        }
        let uncommon = uncommonBiomes[temperature][humidity]
        return uncommon == THE_VOID ? commonBiomes[temperature][humidity] : uncommon
    }

    func getBadlandsBiome(_ humidity: Int, _ weirdness: BiomeParameterRange) -> String {
        if humidity < 2 { return weirdness.max < 0 ? "minecraft:badlands" : "minecraft:eroded_badlands" }
        if humidity < 3 { return "minecraft:badlands" }
        return "minecraft:wooded_badlands"
    }

    func getBadlandsOrRegularBiome(_ temperature: Int, _ humidity: Int, _ weirdness: BiomeParameterRange) -> String {
        return temperature == 4 ? getBadlandsBiome(humidity, weirdness) : getRegularBiome(temperature, humidity, weirdness)
    }

    func getNearMountainBiome(_ temperature: Int, _ humidity: Int, _ weirdness: BiomeParameterRange) -> String {
        if weirdness.max > 0, specialNearMountainBiomes[temperature][humidity] != THE_VOID {
            return specialNearMountainBiomes[temperature][humidity]
        }
        return nearMountainBiomes[temperature][humidity]
    }

    func getMountainSlopeBiome(_ temperature: Int, _ humidity: Int, _ weirdness: BiomeParameterRange) -> String {
        if temperature >= 3 { return getNearMountainBiome(temperature, humidity, weirdness) }
        if humidity <= 1 { return "minecraft:snowy_slopes" }
        return "minecraft:grove"
    }

    func getMountainStartBiome(_ temperature: Int, _ humidity: Int, _ weirdness: BiomeParameterRange) -> String {
        return temperature == 0 ? getMountainSlopeBiome(temperature, humidity, weirdness) : getBadlandsOrRegularBiome(temperature, humidity, weirdness)
    }

    func getShoreBiome(_ temperature: Int) -> String {
        return temperature == 0 ? "minecraft:snowy_beach" : (temperature == 4 ? "minecraft:desert" : "minecraft:beach")
    }

    func getBiomeOrWindsweptSavanna(_ temperature: Int, _ humidity: Int, _ weirdness: BiomeParameterRange, _ alt: String) -> String {
        return (temperature > 1 && humidity < 4 && weirdness.max >= 0) ? "minecraft:windswept_savanna" : alt
    }

    func getErodedShoreBiome(_ temperature: Int, _ humidity: Int, _ weirdness: BiomeParameterRange) -> String {
        let alt = weirdness.max >= 0 ? getRegularBiome(temperature, humidity, weirdness) : getShoreBiome(temperature)
        return getBiomeOrWindsweptSavanna(temperature, humidity, weirdness, alt)
    }

    func getWindsweptOrRegularBiome(_ temperature: Int, _ humidity: Int, _ weirdness: BiomeParameterRange) -> String {
        let alt = windsweptBiomes[temperature][humidity]
        return alt == THE_VOID ? getRegularBiome(temperature, humidity, weirdness) : alt
    }

    func getPeakBiome(_ temperature: Int, _ humidity: Int, _ weirdness: BiomeParameterRange) -> String {
        if temperature <= 2 { return weirdness.max < 0 ? "minecraft:jagged_peaks" : "minecraft:frozen_peaks" }
        if temperature == 3 { return "minecraft:stony_peaks" }
        return getBadlandsBiome(humidity, weirdness)
    }

    var entries: [MultiNoiseBiomeSourceBiome] = []

    func enter(_ parameters: [BiomeParameterRange], _ offset: Double, _ biome: String) {
        let baseOffset = BiomeParameterRange(value: offset)
        let paramsDepth0 = MultiNoiseBiomeSourceParameters(
            temperature: parameters[0],
            humidity: parameters[1],
            continentalness: parameters[2],
            erosion: parameters[3],
            depth: BiomeParameterRange(value: 0.0),
            weirdness: parameters[4],
            offset: baseOffset
        )
        entries.append(MultiNoiseBiomeSourceBiome(biome: biome, parameters: paramsDepth0))

        let paramsDepth1 = MultiNoiseBiomeSourceParameters(
            temperature: parameters[0],
            humidity: parameters[1],
            continentalness: parameters[2],
            erosion: parameters[3],
            depth: BiomeParameterRange(value: 1.0),
            weirdness: parameters[4],
            offset: baseOffset
        )
        entries.append(MultiNoiseBiomeSourceBiome(biome: biome, parameters: paramsDepth1))
    }

    func enterValleyBiomes(_ weirdness: BiomeParameterRange) {
        enter([temperatureParameters[0], defaultRange, coastContinentalness, combine(erosionParameters[0], erosionParameters[1]), weirdness], 0, weirdness.max < 0 ? "minecraft:stony_shore" : "minecraft:frozen_river")
        enter([nonFrozenParameters, defaultRange, coastContinentalness, combine(erosionParameters[0], erosionParameters[1]), weirdness], 0, weirdness.max < 0 ? "minecraft:stony_shore" : "minecraft:river")
        enter([temperatureParameters[0], defaultRange, nearInlandContinentalness, combine(erosionParameters[0], erosionParameters[1]), weirdness], 0, "minecraft:frozen_river")
        enter([nonFrozenParameters, defaultRange, nearInlandContinentalness, combine(erosionParameters[0], erosionParameters[1]), weirdness], 0, "minecraft:river")
        enter([temperatureParameters[0], defaultRange, combine(coastContinentalness, farInlandContinentalness), combine(erosionParameters[2], erosionParameters[5]), weirdness], 0, "minecraft:frozen_river")
        enter([nonFrozenParameters, defaultRange, combine(coastContinentalness, farInlandContinentalness), combine(erosionParameters[2], erosionParameters[5]), weirdness], 0, "minecraft:river")
        enter([temperatureParameters[0], defaultRange, coastContinentalness, erosionParameters[6], weirdness], 0, "minecraft:frozen_river")
        enter([nonFrozenParameters, defaultRange, coastContinentalness, erosionParameters[6], weirdness], 0, "minecraft:river")
        enter([combine(temperatureParameters[1], temperatureParameters[2]), defaultRange, combine(riverContinentalness, farInlandContinentalness), erosionParameters[6], weirdness], 0, "minecraft:swamp")
        enter([combine(temperatureParameters[3], temperatureParameters[4]), defaultRange, combine(riverContinentalness, farInlandContinentalness), erosionParameters[6], weirdness], 0, "minecraft:mangrove_swamp")
        enter([temperatureParameters[0], defaultRange, combine(riverContinentalness, farInlandContinentalness), erosionParameters[6], weirdness], 0, "minecraft:frozen_river")
        for i in 0..<temperatureParameters.count {
            let temperature = temperatureParameters[i]
            for j in 0..<humidityParameters.count {
                let humidity = humidityParameters[j]
                let biome = getBadlandsOrRegularBiome(i, j, weirdness)
                enter([temperature, humidity, combine(midInlandContinentalness, farInlandContinentalness), combine(erosionParameters[0], erosionParameters[1]), weirdness], 0, biome)
            }
        }
    }

    func enterLowBiomes(_ weirdness: BiomeParameterRange) {
        enter([defaultRange, defaultRange, coastContinentalness, combine(erosionParameters[0], erosionParameters[2]), weirdness], 0, "minecraft:stony_shore")
        enter([combine(temperatureParameters[1], temperatureParameters[2]), defaultRange, combine(nearInlandContinentalness, farInlandContinentalness), erosionParameters[6], weirdness], 0, "minecraft:swamp")
        enter([combine(temperatureParameters[3], temperatureParameters[4]), defaultRange, combine(nearInlandContinentalness, farInlandContinentalness), erosionParameters[6], weirdness], 0, "minecraft:mangrove_swamp")
        for i in 0..<temperatureParameters.count {
            let temperature = temperatureParameters[i]
            for j in 0..<humidityParameters.count {
                let humidity = humidityParameters[j]
                let regular = getRegularBiome(i, j, weirdness)
                let badlandsOrRegular = getBadlandsOrRegularBiome(i, j, weirdness)
                let mountainStart = getMountainStartBiome(i, j, weirdness)
                let shore = getShoreBiome(i)
                let regularOrWindsweptSavanna = getBiomeOrWindsweptSavanna(i, j, weirdness, regular)
                let erodedShore = getErodedShoreBiome(i, j, weirdness)
                enter([temperature, humidity, nearInlandContinentalness, combine(erosionParameters[0], erosionParameters[1]), weirdness], 0, badlandsOrRegular)
                enter([temperature, humidity, combine(midInlandContinentalness, farInlandContinentalness), combine(erosionParameters[0], erosionParameters[1]), weirdness], 0, mountainStart)
                enter([temperature, humidity, nearInlandContinentalness, combine(erosionParameters[2], erosionParameters[3]), weirdness], 0, regular)
                enter([temperature, humidity, combine(midInlandContinentalness, farInlandContinentalness), combine(erosionParameters[2], erosionParameters[3]), weirdness], 0, badlandsOrRegular)
                enter([temperature, humidity, coastContinentalness, combine(erosionParameters[3], erosionParameters[4]), weirdness], 0, shore)
                enter([temperature, humidity, combine(nearInlandContinentalness, farInlandContinentalness), erosionParameters[4], weirdness], 0, regular)
                enter([temperature, humidity, coastContinentalness, erosionParameters[5], weirdness], 0, erodedShore)
                enter([temperature, humidity, nearInlandContinentalness, erosionParameters[5], weirdness], 0, regularOrWindsweptSavanna)
                enter([temperature, humidity, combine(midInlandContinentalness, farInlandContinentalness), erosionParameters[5], weirdness], 0, regular)
                enter([temperature, humidity, coastContinentalness, erosionParameters[6], weirdness], 0, shore)
                if i != 0 { continue }
                enter([temperature, humidity, combine(nearInlandContinentalness, farInlandContinentalness), erosionParameters[6], weirdness], 0, regular)
            }
        }
    }

    func enterMidBiomes(_ weirdness: BiomeParameterRange) {
        enter([defaultRange, defaultRange, coastContinentalness, combine(erosionParameters[0], erosionParameters[2]), weirdness], 0, "minecraft:stony_shore")
        enter([combine(temperatureParameters[1], temperatureParameters[2]), defaultRange, combine(nearInlandContinentalness, farInlandContinentalness), erosionParameters[6], weirdness], 0, "minecraft:swamp")
        enter([combine(temperatureParameters[3], temperatureParameters[4]), defaultRange, combine(nearInlandContinentalness, farInlandContinentalness), erosionParameters[6], weirdness], 0, "minecraft:mangrove_swamp")
        for i in 0..<temperatureParameters.count {
            let temperature = temperatureParameters[i]
            for j in 0..<humidityParameters.count {
                let humidity = humidityParameters[j]
                let regular = getRegularBiome(i, j, weirdness)
                let badlandsOrRegular = getBadlandsOrRegularBiome(i, j, weirdness)
                let mountainStart = getMountainStartBiome(i, j, weirdness)
                let windsweptOrRegular = getWindsweptOrRegularBiome(i, j, weirdness)
                let nearMountain = getNearMountainBiome(i, j, weirdness)
                let shore = getShoreBiome(i)
                let regularOrWindsweptSavanna = getBiomeOrWindsweptSavanna(i, j, weirdness, regular)
                let erodedShore = getErodedShoreBiome(i, j, weirdness)
                let mountainSlope = getMountainSlopeBiome(i, j, weirdness)
                enter([temperature, humidity, combine(nearInlandContinentalness, farInlandContinentalness), erosionParameters[0], weirdness], 0, mountainSlope)
                enter([temperature, humidity, combine(nearInlandContinentalness, midInlandContinentalness), erosionParameters[1], weirdness], 0, mountainStart)
                enter([temperature, humidity, farInlandContinentalness, erosionParameters[1], weirdness], 0, i == 0 ? mountainSlope : nearMountain)
                enter([temperature, humidity, nearInlandContinentalness, erosionParameters[2], weirdness], 0, regular)
                enter([temperature, humidity, midInlandContinentalness, erosionParameters[2], weirdness], 0, badlandsOrRegular)
                enter([temperature, humidity, farInlandContinentalness, erosionParameters[2], weirdness], 0, nearMountain)
                enter([temperature, humidity, combine(coastContinentalness, nearInlandContinentalness), erosionParameters[3], weirdness], 0, regular)
                enter([temperature, humidity, combine(midInlandContinentalness, farInlandContinentalness), erosionParameters[3], weirdness], 0, badlandsOrRegular)
                if weirdness.max < 0 {
                    enter([temperature, humidity, coastContinentalness, erosionParameters[4], weirdness], 0, shore)
                    enter([temperature, humidity, combine(nearInlandContinentalness, farInlandContinentalness), erosionParameters[4], weirdness], 0, regular)
                } else {
                    enter([temperature, humidity, combine(coastContinentalness, farInlandContinentalness), erosionParameters[4], weirdness], 0, regular)
                }
                enter([temperature, humidity, coastContinentalness, erosionParameters[5], weirdness], 0, erodedShore)
                enter([temperature, humidity, nearInlandContinentalness, erosionParameters[5], weirdness], 0, regularOrWindsweptSavanna)
                enter([temperature, humidity, combine(midInlandContinentalness, farInlandContinentalness), erosionParameters[5], weirdness], 0, windsweptOrRegular)
                if weirdness.max < 0 {
                    enter([temperature, humidity, coastContinentalness, erosionParameters[6], weirdness], 0, shore)
                } else {
                    enter([temperature, humidity, coastContinentalness, erosionParameters[6], weirdness], 0, regular)
                }
                if i != 0 { continue }
                enter([temperature, humidity, combine(nearInlandContinentalness, farInlandContinentalness), erosionParameters[6], weirdness], 0, regular)
            }
        }
    }

    func enterHighBiomes(_ weirdness: BiomeParameterRange) {
        for i in 0..<temperatureParameters.count {
            let temperature = temperatureParameters[i]
            for j in 0..<humidityParameters.count {
                let humidity = humidityParameters[j]
                let regular = getRegularBiome(i, j, weirdness)
                let badlandsOrRegular = getBadlandsOrRegularBiome(i, j, weirdness)
                let mountainStart = getMountainStartBiome(i, j, weirdness)
                let nearMountainBiome = getNearMountainBiome(i, j, weirdness)
                let windsweptOrRegular = getWindsweptOrRegularBiome(i, j, weirdness)
                let regularOrWindsweptSavanna = getBiomeOrWindsweptSavanna(i, j, weirdness, regular)
                let mountainSlope = getMountainSlopeBiome(i, j, weirdness)
                let peak = getPeakBiome(i, j, weirdness)
                enter([temperature, humidity, coastContinentalness, combine(erosionParameters[0], erosionParameters[1]), weirdness], 0, regular)
                enter([temperature, humidity, nearInlandContinentalness, erosionParameters[0], weirdness], 0, mountainSlope)
                enter([temperature, humidity, combine(midInlandContinentalness, farInlandContinentalness), erosionParameters[0], weirdness], 0, peak)
                enter([temperature, humidity, nearInlandContinentalness, erosionParameters[1], weirdness], 0, mountainStart)
                enter([temperature, humidity, combine(midInlandContinentalness, farInlandContinentalness), erosionParameters[1], weirdness], 0, mountainSlope)
                enter([temperature, humidity, combine(coastContinentalness, nearInlandContinentalness), combine(erosionParameters[2], erosionParameters[3]), weirdness], 0, regular)
                enter([temperature, humidity, combine(midInlandContinentalness, farInlandContinentalness), erosionParameters[2], weirdness], 0, nearMountainBiome)
                enter([temperature, humidity, midInlandContinentalness, erosionParameters[3], weirdness], 0, badlandsOrRegular)
                enter([temperature, humidity, farInlandContinentalness, erosionParameters[3], weirdness], 0, nearMountainBiome)
                enter([temperature, humidity, combine(coastContinentalness, farInlandContinentalness), erosionParameters[4], weirdness], 0, regular)
                enter([temperature, humidity, combine(coastContinentalness, nearInlandContinentalness), erosionParameters[5], weirdness], 0, regularOrWindsweptSavanna)
                enter([temperature, humidity, combine(midInlandContinentalness, farInlandContinentalness), erosionParameters[5], weirdness], 0, windsweptOrRegular)
                enter([temperature, humidity, combine(coastContinentalness, farInlandContinentalness), erosionParameters[6], weirdness], 0, regular)
            }
        }
    }

    func enterPeakBiomes(_ weirdness: BiomeParameterRange) {
        for i in 0..<temperatureParameters.count {
            let temperature = temperatureParameters[i]
            for j in 0..<humidityParameters.count {
                let humidity = humidityParameters[j]
                let regular = getRegularBiome(i, j, weirdness)
                let badlandsOrRegular = getBadlandsOrRegularBiome(i, j, weirdness)
                let mountainStart = getMountainStartBiome(i, j, weirdness)
                let nearMountainBiome = getNearMountainBiome(i, j, weirdness)
                let windsweptOrRegular = getWindsweptOrRegularBiome(i, j, weirdness)
                let regularOrWindsweptSavanna = getBiomeOrWindsweptSavanna(i, j, weirdness, windsweptOrRegular)
                let peak = getPeakBiome(i, j, weirdness)
                enter([temperature, humidity, combine(coastContinentalness, farInlandContinentalness), erosionParameters[0], weirdness], 0, peak)
                enter([temperature, humidity, combine(coastContinentalness, nearInlandContinentalness), erosionParameters[1], weirdness], 0, mountainStart)
                enter([temperature, humidity, combine(midInlandContinentalness, farInlandContinentalness), erosionParameters[1], weirdness], 0, peak)
                enter([temperature, humidity, combine(coastContinentalness, nearInlandContinentalness), combine(erosionParameters[2], erosionParameters[3]), weirdness], 0, regular)
                enter([temperature, humidity, combine(midInlandContinentalness, farInlandContinentalness), erosionParameters[2], weirdness], 0, nearMountainBiome)
                enter([temperature, humidity, midInlandContinentalness, erosionParameters[3], weirdness], 0, badlandsOrRegular)
                enter([temperature, humidity, farInlandContinentalness, erosionParameters[3], weirdness], 0, nearMountainBiome)
                enter([temperature, humidity, combine(coastContinentalness, farInlandContinentalness), erosionParameters[4], weirdness], 0, regular)
                enter([temperature, humidity, combine(coastContinentalness, nearInlandContinentalness), erosionParameters[5], weirdness], 0, regularOrWindsweptSavanna)
                enter([temperature, humidity, combine(midInlandContinentalness, farInlandContinentalness), erosionParameters[5], weirdness], 0, windsweptOrRegular)
                enter([temperature, humidity, combine(coastContinentalness, farInlandContinentalness), erosionParameters[6], weirdness], 0, regular)
            }
        }
    }

    // Ocean biomes
    enter([defaultRange, defaultRange, range(-1.2, -1.05), defaultRange, defaultRange], 0, "minecraft:mushroom_fields")
    for i in 0..<temperatureParameters.count {
        let temperature = temperatureParameters[i]
        enter([temperature, defaultRange, range(-1.05, -0.455), defaultRange, defaultRange], 0, oceanBiomes[0][i])
        enter([temperature, defaultRange, range(-0.455, -0.19), defaultRange, defaultRange], 0, oceanBiomes[1][i])
    }

    // Land biomes
    enterMidBiomes(range(-1.0, -0.93333334))
    enterHighBiomes(range(-0.93333334, -0.7666667))
    enterPeakBiomes(range(-0.7666667, -0.56666666))
    enterHighBiomes(range(-0.56666666, -0.4))
    enterMidBiomes(range(-0.4, -0.26666668))
    enterLowBiomes(range(-0.26666668, -0.05))
    enterValleyBiomes(range(-0.05, 0.05))
    enterLowBiomes(range(0.05, 0.26666668))
    enterMidBiomes(range(0.26666668, 0.4))
    enterHighBiomes(range(0.4, 0.56666666))
    enterPeakBiomes(range(0.56666666, 0.7666667))
    enterHighBiomes(range(0.7666667, 0.93333334))
    enterMidBiomes(range(0.93333334, 1.0))

    // Cave biomes
    entries.append(
        MultiNoiseBiomeSourceBiome(
            biome: "minecraft:lush_caves",
            parameters: MultiNoiseBiomeSourceParameters(
                temperature: defaultRange,
                humidity: range(0.7, 1.0),
                continentalness: defaultRange,
                erosion: defaultRange,
                depth: range(0.2, 0.9),
                weirdness: defaultRange,
                offset: BiomeParameterRange(value: 0.0)
            )
        )
    )
    entries.append(
        MultiNoiseBiomeSourceBiome(
            biome: "minecraft:dripstone_caves",
            parameters: MultiNoiseBiomeSourceParameters(
                temperature: defaultRange,
                humidity: defaultRange,
                continentalness: range(0.8, 1.0),
                erosion: defaultRange,
                depth: range(0.2, 0.9),
                weirdness: defaultRange,
                offset: BiomeParameterRange(value: 0.0)
            )
        )
    )
    entries.append(
        MultiNoiseBiomeSourceBiome(
            biome: "minecraft:deep_dark",
            parameters: MultiNoiseBiomeSourceParameters(
                temperature: defaultRange,
                humidity: defaultRange,
                continentalness: defaultRange,
                erosion: combine(erosionParameters[0], erosionParameters[1]),
                depth: range(1.1, 1.1),
                weirdness: defaultRange,
                offset: BiomeParameterRange(value: 0.0)
            )
        )
    )

    return entries
}

private enum OverworldBiomeSearchTreeDataCache {
    static let cached: [MultiNoiseBiomeSourceBiome] = buildOverworldBiomeSearchTreeData()
}
