import Foundation

public enum BiomeSearchTreeError: Error {
    case emptyEntries
    case missingBiome(String)
}

public final class BiomeSearchTree {
    private let root: BiomeTreeNode
    private let flatNodes: [FlatBiomeTreeNode]
    private let rootIndex: Int

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
        let flattened = flattenBiomeTree(node: self.root)
        self.rootIndex = 0
        self.flatNodes = flattened
    }

    public func get(_ point: NoisePoint) throws -> RegistryKey<Biome> {
        let state = self.lookupStateForCurrentThread()
        self.updateScratchPoint(from: point, into: &state.scratchPoint)
        let resultIndex = self.getResultingNodeIndex(point: state.scratchPoint, alternativeIndex: state.lastResultIndex)
        guard resultIndex >= 0 else {
            throw BiomeSearchTreeError.emptyEntries
        }
        let value = self.flatNodes[resultIndex].value
        guard let value else {
            throw BiomeSearchTreeError.emptyEntries
        }
        state.lastResultIndex = resultIndex
        return value
    }

    @inline(__always)
    func getUnchecked(_ point: NoisePoint) -> RegistryKey<Biome> {
        let state = self.lookupStateForCurrentThread()
        self.updateScratchPoint(from: point, into: &state.scratchPoint)
        let resultIndex = self.getResultingNodeIndex(point: state.scratchPoint, alternativeIndex: state.lastResultIndex)
        precondition(resultIndex >= 0, "BiomeSearchTree returned an empty result node")
        let value = self.flatNodes[resultIndex].value
        precondition(value != nil, "BiomeSearchTree returned an empty result node")
        state.lastResultIndex = resultIndex
        return value!
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
        let resultIndex = self.getResultingNodeIndex(point: state.scratchPoint, alternativeIndex: state.lastResultIndex)
        precondition(resultIndex >= 0, "BiomeSearchTree returned an empty result node")
        let value = self.flatNodes[resultIndex].value
        precondition(value != nil, "BiomeSearchTree returned an empty result node")
        state.lastResultIndex = resultIndex
        return value!
    }


    func makeReusableLookupState() -> BiomeSearchLookupState {
        return BiomeSearchLookupState(lastResultIndex: -1, scratchPoint: BiomeSearchPoint())
    }

    @inline(__always)
    func getUnchecked(
        temperature: Double,
        humidity: Double,
        continentalness: Double,
        erosion: Double,
        weirdness: Double,
        depth: Double,
        using state: BiomeSearchLookupState
    ) -> RegistryKey<Biome> {
        self.updateScratchPoint(
            temperature: temperature,
            humidity: humidity,
            continentalness: continentalness,
            erosion: erosion,
            weirdness: weirdness,
            depth: depth,
            into: &state.scratchPoint
        )
        let resultIndex = self.getResultingNodeIndex(point: state.scratchPoint, alternativeIndex: state.lastResultIndex)
        precondition(resultIndex >= 0, "BiomeSearchTree returned an empty result node")
        let value = self.flatNodes[resultIndex].value
        precondition(value != nil, "BiomeSearchTree returned an empty result node")
        state.lastResultIndex = resultIndex
        return value!
    }

    /// Resets the tree's internal "alternative".
    /// Useful for deterministic results, but will result in a massive performance hit.
    public func resetAlternative() {
        self.lookupStateForCurrentThread().lastResultIndex = -1
    }

    // Internal helper for diagnostics.
    func lastResultDistance(to point: NoisePoint) -> Int64? {
        let state = self.lookupStateForCurrentThread()
        guard state.lastResultIndex >= 0 else { return nil }
        self.updateScratchPoint(from: point, into: &state.scratchPoint)
        return self.flatNodes[state.lastResultIndex].squaredDistance(to: state.scratchPoint)
    }

    private func updateScratchPoint(from point: NoisePoint, into scratchPoint: inout BiomeSearchPoint) {
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
        into scratchPoint: inout BiomeSearchPoint
    ) {
        scratchPoint.temperature = Int64(temperature * 10000.0)
        scratchPoint.humidity = Int64(humidity * 10000.0)
        scratchPoint.continentalness = Int64(continentalness * 10000.0)
        scratchPoint.erosion = Int64(erosion * 10000.0)
        scratchPoint.depth = Int64(depth * 10000.0)
        scratchPoint.weirdness = Int64(weirdness * 10000.0)
        scratchPoint.offset = 0
    }

    private func lookupStateForCurrentThread() -> BiomeSearchLookupState {
        let key = self.lookupStateThreadDictionaryKey
        if let existing = Thread.current.threadDictionary[key] as? BiomeSearchLookupState {
            return existing
        }
        let state = BiomeSearchLookupState(lastResultIndex: -1, scratchPoint: BiomeSearchPoint())
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

    @inline(__always)
    private func getResultingNodeIndex(point: BiomeSearchPoint, alternativeIndex: Int) -> Int {
        return self.flatNodes.withUnsafeBufferPointer { nodes in
            guard let nodesBase = nodes.baseAddress else {
                return alternativeIndex
            }
            var bestNodeIndex = alternativeIndex
            var bestDistance = alternativeIndex >= 0
                ? squaredDistance(of: nodesBase.advanced(by: alternativeIndex), to: point)
                : Int64.max
            Self.updateBestNode(
                nodeIndex: self.rootIndex,
                point: point,
                bestNodeIndex: &bestNodeIndex,
                bestDistance: &bestDistance,
                nodesBase: nodesBase
            )
            return bestNodeIndex
        }
    }

    @inline(__always)
    private static func updateBestNode(
        nodeIndex: Int,
        point: BiomeSearchPoint,
        bestNodeIndex: inout Int,
        bestDistance: inout Int64,
        nodesBase: UnsafePointer<FlatBiomeTreeNode>
    ) {
        let node = nodesBase.advanced(by: nodeIndex)
        if node.pointee.isLeaf { return }
        let childIndexStart = node.pointee.childIndexStart
        let childEnd = childIndexStart + node.pointee.childCount
        for childIndex in childIndexStart..<childEnd {
            let child = nodesBase.advanced(by: childIndex)
            let distance = squaredDistanceBounded(of: child, to: point, maxDistance: bestDistance)
            if bestDistance < distance { continue }
            if child.pointee.isLeaf {
                bestNodeIndex = childIndex
                bestDistance = distance
            } else {
                Self.updateBestNode(
                    nodeIndex: childIndex,
                    point: point,
                    bestNodeIndex: &bestNodeIndex,
                    bestDistance: &bestDistance,
                    nodesBase: nodesBase
                )
            }
            if bestDistance == 0 {
                return
            }
        }
    }
}

final class BiomeSearchLookupState {
    var lastResultIndex: Int
    var scratchPoint: BiomeSearchPoint

    init(lastResultIndex: Int, scratchPoint: BiomeSearchPoint) {
        self.lastResultIndex = lastResultIndex
        self.scratchPoint = scratchPoint
    }
}

struct BiomeSearchPoint {
    var temperature: Int64 = 0
    var humidity: Int64 = 0
    var continentalness: Int64 = 0
    var erosion: Int64 = 0
    var depth: Int64 = 0
    var weirdness: Int64 = 0
    var offset: Int64 = 0
}

private struct FlatBiomeTreeNode {
    let value: RegistryKey<Biome>?
    let isLeaf: Bool
    var childIndexStart: Int
    var childCount: Int
    let offsetContainsZero: Bool
    let min0: Int64
    let max0: Int64
    let min1: Int64
    let max1: Int64
    let min2: Int64
    let max2: Int64
    let min3: Int64
    let max3: Int64
    let min4: Int64
    let max4: Int64
    let min5: Int64
    let max5: Int64
    let min6: Int64
    let max6: Int64

    init(node: BiomeTreeNode, childIndexStart: Int = 0, childCount: Int = 0) {
        self.value = node.value
        self.isLeaf = node.value != nil
        self.childIndexStart = childIndexStart
        self.childCount = childCount
        self.min0 = node.min0Value
        self.max0 = node.max0Value
        self.min1 = node.min1Value
        self.max1 = node.max1Value
        self.min2 = node.min2Value
        self.max2 = node.max2Value
        self.min3 = node.min3Value
        self.max3 = node.max3Value
        self.min4 = node.min4Value
        self.max4 = node.max4Value
        self.min5 = node.min5Value
        self.max5 = node.max5Value
        self.min6 = node.min6Value
        self.max6 = node.max6Value
        self.offsetContainsZero = self.min6 <= 0 && self.max6 >= 0
    }

    @inline(__always)
    func squaredDistance(to point: BiomeSearchPoint) -> Int64 {
        let d2 = distance(point.continentalness, self.min2, self.max2)
        let d3 = distance(point.erosion, self.min3, self.max3)
        let d5 = distance(point.weirdness, self.min5, self.max5)
        let d4 = distance(point.depth, self.min4, self.max4)
        let d0 = distance(point.temperature, self.min0, self.max0)
        let d1 = distance(point.humidity, self.min1, self.max1)
        var out = d2 &* d2
        out &+= d3 &* d3
        out &+= d5 &* d5
        out &+= d4 &* d4
        out &+= d0 &* d0
        out &+= d1 &* d1
        if !self.offsetContainsZero {
            let d6 = distance(point.offset, self.min6, self.max6)
            out &+= d6 &* d6
        }
        return out
    }

    @inline(__always)
    func squaredDistanceBounded(to point: BiomeSearchPoint, maxDistance: Int64) -> Int64 {
        let d2 = distance(point.continentalness, self.min2, self.max2)
        var out = d2 &* d2
        if out > maxDistance { return maxDistance == Int64.max ? maxDistance : maxDistance + 1 }
        let d3 = distance(point.erosion, self.min3, self.max3)
        out &+= d3 &* d3
        if out > maxDistance { return maxDistance == Int64.max ? maxDistance : maxDistance + 1 }
        let d5 = distance(point.weirdness, self.min5, self.max5)
        out &+= d5 &* d5
        if out > maxDistance { return maxDistance == Int64.max ? maxDistance : maxDistance + 1 }
        let d4 = distance(point.depth, self.min4, self.max4)
        out &+= d4 &* d4
        if out > maxDistance { return maxDistance == Int64.max ? maxDistance : maxDistance + 1 }
        let d0 = distance(point.temperature, self.min0, self.max0)
        out &+= d0 &* d0
        if out > maxDistance { return maxDistance == Int64.max ? maxDistance : maxDistance + 1 }
        let d1 = distance(point.humidity, self.min1, self.max1)
        out &+= d1 &* d1
        if out > maxDistance { return maxDistance == Int64.max ? maxDistance : maxDistance + 1 }
        if !self.offsetContainsZero {
            let d6 = distance(point.offset, self.min6, self.max6)
            out &+= d6 &* d6
        }
        return out
    }
}

@inline(__always)
private func squaredDistance(of node: UnsafePointer<FlatBiomeTreeNode>, to point: BiomeSearchPoint) -> Int64 {
    let d2 = distance(point.continentalness, node.pointee.min2, node.pointee.max2)
    let d3 = distance(point.erosion, node.pointee.min3, node.pointee.max3)
    let d5 = distance(point.weirdness, node.pointee.min5, node.pointee.max5)
    let d4 = distance(point.depth, node.pointee.min4, node.pointee.max4)
    let d0 = distance(point.temperature, node.pointee.min0, node.pointee.max0)
    let d1 = distance(point.humidity, node.pointee.min1, node.pointee.max1)
    var out = d2 &* d2
    out &+= d3 &* d3
    out &+= d5 &* d5
    out &+= d4 &* d4
    out &+= d0 &* d0
    out &+= d1 &* d1
    if !node.pointee.offsetContainsZero {
        let d6 = distance(point.offset, node.pointee.min6, node.pointee.max6)
        out &+= d6 &* d6
    }
    return out
}

@inline(__always)
private func squaredDistanceBounded(
    of node: UnsafePointer<FlatBiomeTreeNode>,
    to point: BiomeSearchPoint,
    maxDistance: Int64
) -> Int64 {
    let d2 = distance(point.continentalness, node.pointee.min2, node.pointee.max2)
    var out = d2 &* d2
    if out > maxDistance { return maxDistance == Int64.max ? maxDistance : maxDistance + 1 }
    let d3 = distance(point.erosion, node.pointee.min3, node.pointee.max3)
    out &+= d3 &* d3
    if out > maxDistance { return maxDistance == Int64.max ? maxDistance : maxDistance + 1 }
    let d5 = distance(point.weirdness, node.pointee.min5, node.pointee.max5)
    out &+= d5 &* d5
    if out > maxDistance { return maxDistance == Int64.max ? maxDistance : maxDistance + 1 }
    let d4 = distance(point.depth, node.pointee.min4, node.pointee.max4)
    out &+= d4 &* d4
    if out > maxDistance { return maxDistance == Int64.max ? maxDistance : maxDistance + 1 }
    let d0 = distance(point.temperature, node.pointee.min0, node.pointee.max0)
    out &+= d0 &* d0
    if out > maxDistance { return maxDistance == Int64.max ? maxDistance : maxDistance + 1 }
    let d1 = distance(point.humidity, node.pointee.min1, node.pointee.max1)
    out &+= d1 &* d1
    if out > maxDistance { return maxDistance == Int64.max ? maxDistance : maxDistance + 1 }
    if !node.pointee.offsetContainsZero {
        let d6 = distance(point.offset, node.pointee.min6, node.pointee.max6)
        out &+= d6 &* d6
    }
    return out
}

private func flattenBiomeTree(node: BiomeTreeNode) -> [FlatBiomeTreeNode] {
    var nodes: [FlatBiomeTreeNode?] = [nil]
    var nextFreeIndex = 1
    populateFlatBiomeTree(node: node, at: 0, into: &nodes, nextFreeIndex: &nextFreeIndex)
    return nodes.map { $0! }
}

private func populateFlatBiomeTree(
    node: BiomeTreeNode,
    at nodeIndex: Int,
    into nodes: inout [FlatBiomeTreeNode?],
    nextFreeIndex: inout Int
) {
    let childIndexStart = nextFreeIndex
    let childCount = node.children.count
    nextFreeIndex += childCount
    if nodes.count < nextFreeIndex {
        nodes.append(contentsOf: repeatElement(nil, count: nextFreeIndex - nodes.count))
    }
    nodes[nodeIndex] = FlatBiomeTreeNode(
        node: node,
        childIndexStart: childIndexStart,
        childCount: childCount
    )
    for (childOffset, child) in node.children.enumerated() {
        populateFlatBiomeTree(
            node: child,
            at: childIndexStart + childOffset,
            into: &nodes,
            nextFreeIndex: &nextFreeIndex
        )
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
    private let isLeaf: Bool
    private let offsetContainsZero: Bool
    private let min0: Int64
    private let max0: Int64
    private let min1: Int64
    private let max1: Int64
    private let min2: Int64
    private let max2: Int64
    private let min3: Int64
    private let max3: Int64
    private let min4: Int64
    private let max4: Int64
    private let min5: Int64
    private let max5: Int64
    private let min6: Int64
    private let max6: Int64

    init(parameters: [ParameterRange], value: RegistryKey<Biome>?, children: [BiomeTreeNode]) {
        self.parameters = parameters
        self.value = value
        self.children = children
        self.isLeaf = value != nil
        if parameters.count == 7 {
            self.min0 = parameters[0].min
            self.max0 = parameters[0].max
            self.min1 = parameters[1].min
            self.max1 = parameters[1].max
            self.min2 = parameters[2].min
            self.max2 = parameters[2].max
            self.min3 = parameters[3].min
            self.max3 = parameters[3].max
            self.min4 = parameters[4].min
            self.max4 = parameters[4].max
            self.min5 = parameters[5].min
            self.max5 = parameters[5].max
            self.min6 = parameters[6].min
            self.max6 = parameters[6].max
            self.offsetContainsZero = self.min6 <= 0 && self.max6 >= 0
        } else {
            self.min0 = 0
            self.max0 = 0
            self.min1 = 0
            self.max1 = 0
            self.min2 = 0
            self.max2 = 0
            self.min3 = 0
            self.max3 = 0
            self.min4 = 0
            self.max4 = 0
            self.min5 = 0
            self.max5 = 0
            self.min6 = 0
            self.max6 = 0
            self.offsetContainsZero = true
        }
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

    var min0Value: Int64 { self.min0 }
    var max0Value: Int64 { self.max0 }
    var min1Value: Int64 { self.min1 }
    var max1Value: Int64 { self.max1 }
    var min2Value: Int64 { self.min2 }
    var max2Value: Int64 { self.max2 }
    var min3Value: Int64 { self.min3 }
    var max3Value: Int64 { self.max3 }
    var min4Value: Int64 { self.min4 }
    var max4Value: Int64 { self.max4 }
    var min5Value: Int64 { self.min5 }
    var max5Value: Int64 { self.max5 }
    var min6Value: Int64 { self.min6 }
    var max6Value: Int64 { self.max6 }
}

@inline(__always)
private func distance(_ point: Int64, _ min: Int64, _ max: Int64) -> Int64 {
    if point > max { return point - max }
    if point < min { return min - point }
    return 0
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
