import Foundation

public enum BiomeSearchTreeError: Error {
    case emptyEntries
    case missingBiome(String)
}

public final class BiomeSearchTree {
    private let root: BiomeTreeNode
    private var lastResult: BiomeTreeNode

    public init(entries: [(NoiseHypercube, Biome)]) throws {
        guard !entries.isEmpty else {
            throw BiomeSearchTreeError.emptyEntries
        }
        var converted: [BiomeTreeNode] = []
        converted.reserveCapacity(entries.count)
        for entry in entries {
            converted.append(BiomeTreeNode(parameters: entry.0.toList(), value: entry.1, children: []))
        }
        self.root = try BiomeTreeNode.createNode(from: converted)
        self.lastResult = BiomeTreeNode(parameters: [], value: nil, children: [])
    }

    public func get(_ point: NoisePoint) throws -> Biome {
        let result = self.root.getResultingNode(point: point.toList(), alternative: self.lastResult)
        guard let value = result.value else {
            throw BiomeSearchTreeError.emptyEntries
        }
        self.lastResult = result
        return value
    }
}

public func buildBiomeSearchTree(from biomeRegistry: Registry<Biome>, entries: [MultiNoiseBiomeSourceBiome]) throws -> BiomeSearchTree {
    var mapped: [(NoiseHypercube, Biome)] = []
    mapped.reserveCapacity(entries.count)
    for entry in entries {
        guard let biome = biomeRegistry.get(RegistryKey(referencing: entry.biome)) else {
            throw BiomeSearchTreeError.missingBiome(entry.biome)
        }
        mapped.append((NoiseHypercube(from: entry.parameters), biome))
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
        if point - self.max > 0 { return point - self.max }
        return Swift.max(self.min - point, 0)
    }
}

final class BiomeTreeNode {
    let parameters: [ParameterRange]
    let children: [BiomeTreeNode]
    let value: Biome?

    init(parameters: [ParameterRange], value: Biome?, children: [BiomeTreeNode]) {
        self.parameters = parameters
        self.value = value
        self.children = children
    }

    func getResultingNode(point: [Int64], alternative: BiomeTreeNode) -> BiomeTreeNode {
        if self.value != nil { return self }
        var ret = alternative
        var retDistance = alternative.value != nil ? squaredDistance(parameters: alternative.parameters, point: point) : Int64.max
        for child in self.children {
            let distance = squaredDistance(parameters: child.parameters, point: point)
            if retDistance < distance { continue }
            let endNode = child.getResultingNode(point: point, alternative: alternative)
            guard endNode.value != nil else {
                continue
            }
            let endDistance = sameBiome(endNode.value, child.value) ? distance : squaredDistance(parameters: endNode.parameters, point: point)
            if retDistance < endDistance { continue }
            retDistance = endDistance
            ret = endNode
        }
        return ret
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

private func sameBiome(_ a: Biome?, _ b: Biome?) -> Bool {
    guard let a, let b else { return false }
    return a === b
}

private func squaredDistance(parameters: [ParameterRange], point: [Int64]) -> Int64 {
    var out: Int64 = 0
    for i in 0..<7 {
        let n = parameters[i].distance(to: point[i])
        out += n * n
    }
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

