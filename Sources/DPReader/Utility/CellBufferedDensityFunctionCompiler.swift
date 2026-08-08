import Foundation

#if canImport(CLLVM)

private enum BulkDensityCacheKind {
    case flat
    case cache2D
}

private struct BulkDensityCacheDescriptor {
    let id: Int
    let identity: ObjectIdentifier
    let kind: BulkDensityCacheKind
    let delegate: any DensityFunction
}

private struct BulkDensityInterpolatorDescriptor {
    let identity: ObjectIdentifier
    let delegate: any DensityFunction
    let isFlat2D: Bool
}

private struct BulkDensityInterpolatorValues {
    let values: [Double]
    let isFlat2D: Bool
}

private enum BulkDensityEvaluationMode {
    case normal
    case interpolatorCorners(baseY: Int32)
}

private final class CellBufferedDensityFunctionPlan: BufferedDensityFunctionRuntimePlan, @unchecked Sendable {
    private let root: any DensityFunction
    private let registry: Registry<DensityFunction>
    private let cellSize: DensityFunctionCellSize
    private let cellVolume: DensityFunctionCellVolume
    private let caches: [BulkDensityCacheDescriptor]
    private let cacheIDs: [ObjectIdentifier: Int]
    private let interpolators: [BulkDensityInterpolatorDescriptor]
    private let useExternalCacheStorage: Bool

    init(
        root: any DensityFunction,
        registry: Registry<DensityFunction>,
        cellSize: DensityFunctionCellSize,
        cellVolume: DensityFunctionCellVolume,
        useExternalCacheStorage: Bool
    ) throws {
        var inventory = BulkDensityFunctionInventory(registry: registry)
        try inventory.visit(root)
        self.root = root
        self.registry = registry
        self.cellSize = cellSize
        self.cellVolume = cellVolume
        self.caches = inventory.caches
        self.cacheIDs = Dictionary(uniqueKeysWithValues: inventory.caches.map { ($0.identity, $0.id) })
        self.interpolators = inventory.interpolators
        self.useExternalCacheStorage = useExternalCacheStorage
    }

    var cacheCount: Int {
        self.caches.count
    }

    func evaluate(
        runtimeContextPointer: UnsafeRawPointer?,
        baseX: Int32,
        baseY: Int32,
        baseZ: Int32,
        outputPointer: UnsafeMutablePointer<Double>?
    ) {
        guard let outputPointer else {
            return
        }

        let horizontal = self.cellSize.horizontalBlockCount
        let vertical = self.cellSize.verticalBlockCount
        precondition(floorMod(baseX, horizontal) == 0 && floorMod(baseY, vertical) == 0 && floorMod(baseZ, horizontal) == 0,
            "Bulk density evaluation base position must be aligned to the compiled cell size.")

        let requiredCacheValues = self.caches.count * self.cellSize.blockCount
        var internalCache = [Double](repeating: 0.0, count: requiredCacheValues)
        let externalContext: CompiledDensityFunctionBulkEvaluationContext? = if self.useExternalCacheStorage {
            runtimeContextPointer?.assumingMemoryBound(to: CompiledDensityFunctionBulkEvaluationContext.self).pointee
        } else {
            nil
        }
        if self.useExternalCacheStorage {
            precondition(externalContext != nil, "Bulk density evaluation requires an evaluation context.")
            precondition(externalContext!.cacheValueCount == requiredCacheValues,
                "Bulk density evaluation cache storage does not match the compiled cache layout.")
            precondition(requiredCacheValues == 0 || externalContext!.cacheValues != nil,
                "Bulk density evaluation requires non-null cache storage.")
        }

        let interpolatorValues = self.precomputeInterpolators(baseX: baseX, baseY: baseY, baseZ: baseZ)
        let xCellCount = Int(self.cellVolume.xCount)
        let yCellCount = Int(self.cellVolume.yCount)
        let zCellCount = Int(self.cellVolume.zCount)
        let columnValueCount = yCellCount * self.cellSize.blockCount
        var outputOffset = 0

        func evaluateColumns(cachePointer: UnsafeMutablePointer<Double>?) {
            for cellZ in 0..<zCellCount {
                let columnBaseZ = baseZ + Int32(cellZ) * horizontal
                for cellX in 0..<xCellCount {
                    let columnBaseX = baseX + Int32(cellX) * horizontal
                    self.fillCaches(
                        cachePointer: cachePointer,
                        columnBaseX: columnBaseX,
                        baseY: baseY,
                        columnBaseZ: columnBaseZ,
                        interpolatorValues: interpolatorValues,
                        volumeBaseX: baseX,
                        volumeBaseZ: baseZ
                    )
                    let positions = self.columnPositions(baseX: columnBaseX, baseY: baseY, baseZ: columnBaseZ)
                    var evaluator = BulkDensityBufferEvaluator(
                        registry: self.registry,
                        cacheIDs: self.cacheIDs,
                        cachePointer: cachePointer,
                        cacheElementsPerCell: self.cellSize.blockCount,
                        cellSize: self.cellSize,
                        columnBaseX: columnBaseX,
                        columnBaseZ: columnBaseZ,
                        volumeBaseX: baseX,
                        volumeBaseY: baseY,
                        volumeBaseZ: baseZ,
                        cellVolume: self.cellVolume,
                        interpolators: interpolatorValues,
                        mode: .normal
                    )
                    let values = evaluator.evaluate(self.root, at: positions)
                    precondition(values.count == columnValueCount)
                    for index in values.indices {
                        outputPointer[outputOffset + index] = values[index]
                    }
                    outputOffset += values.count
                }
            }
        }

        if let externalCache = externalContext?.cacheValues {
            evaluateColumns(cachePointer: externalCache)
        } else {
            internalCache.withUnsafeMutableBufferPointer { cacheBuffer in
                evaluateColumns(cachePointer: cacheBuffer.baseAddress)
            }
        }
    }

    private func columnPositions(baseX: Int32, baseY: Int32, baseZ: Int32) -> [PosInt3D] {
        let horizontal = Int(self.cellSize.horizontalBlockCount)
        let vertical = Int(self.cellSize.verticalBlockCount)
        var positions: [PosInt3D] = []
        positions.reserveCapacity(Int(self.cellVolume.yCount) * self.cellSize.blockCount)
        for cellY in 0..<Int(self.cellVolume.yCount) {
            let cellBaseY = baseY + Int32(cellY * vertical)
            for localZ in 0..<horizontal {
                for localX in 0..<horizontal {
                    for localY in 0..<vertical {
                        positions.append(PosInt3D(
                            x: baseX + Int32(localX),
                            y: cellBaseY + Int32(localY),
                            z: baseZ + Int32(localZ)
                        ))
                    }
                }
            }
        }
        return positions
    }

    private func fillCaches(
        cachePointer: UnsafeMutablePointer<Double>?,
        columnBaseX: Int32,
        baseY: Int32,
        columnBaseZ: Int32,
        interpolatorValues: [ObjectIdentifier: BulkDensityInterpolatorValues],
        volumeBaseX: Int32,
        volumeBaseZ: Int32
    ) {
        guard let cachePointer else {
            precondition(self.caches.isEmpty)
            return
        }
        let horizontal = Int(self.cellSize.horizontalBlockCount)
        let vertical = Int(self.cellSize.verticalBlockCount)
        for cache in self.caches {
            var positions: [PosInt3D] = []
            positions.reserveCapacity(horizontal * horizontal)
            for localZ in 0..<horizontal {
                for localX in 0..<horizontal {
                    let worldX = columnBaseX + Int32(localX)
                    let worldZ = columnBaseZ + Int32(localZ)
                    switch cache.kind {
                    case .flat:
                        positions.append(PosInt3D(
                            x: floorDiv(worldX, by: 4) * 4,
                            y: 0,
                            z: floorDiv(worldZ, by: 4) * 4
                        ))
                    case .cache2D:
                        positions.append(PosInt3D(x: worldX, y: baseY, z: worldZ))
                    }
                }
            }
            var evaluator = BulkDensityBufferEvaluator(
                registry: self.registry,
                cacheIDs: self.cacheIDs,
                cachePointer: cachePointer,
                cacheElementsPerCell: self.cellSize.blockCount,
                cellSize: self.cellSize,
                columnBaseX: columnBaseX,
                columnBaseZ: columnBaseZ,
                volumeBaseX: volumeBaseX,
                volumeBaseY: baseY,
                volumeBaseZ: volumeBaseZ,
                cellVolume: self.cellVolume,
                interpolators: interpolatorValues,
                mode: .normal
            )
            let values = evaluator.evaluate(cache.delegate, at: positions)
            let cacheBase = cache.id * self.cellSize.blockCount
            for localZ in 0..<horizontal {
                for localX in 0..<horizontal {
                    let value = values[localZ * horizontal + localX]
                    let blockBase = cacheBase + (localZ * horizontal + localX) * vertical
                    for localY in 0..<vertical {
                        cachePointer[blockBase + localY] = value
                    }
                }
            }
        }
    }

    private func precomputeInterpolators(baseX: Int32, baseY: Int32, baseZ: Int32) -> [ObjectIdentifier: BulkDensityInterpolatorValues] {
        var result: [ObjectIdentifier: BulkDensityInterpolatorValues] = [:]
        let horizontal = self.cellSize.horizontalBlockCount
        let vertical = self.cellSize.verticalBlockCount
        for interpolator in self.interpolators {
            var positions: [PosInt3D] = []
            if interpolator.isFlat2D {
                positions.reserveCapacity((Int(self.cellVolume.xCount) + 1) * (Int(self.cellVolume.zCount) + 1))
                for z in 0...Int(self.cellVolume.zCount) {
                    for x in 0...Int(self.cellVolume.xCount) {
                        positions.append(PosInt3D(
                            x: baseX + Int32(x) * horizontal,
                            y: 0,
                            z: baseZ + Int32(z) * horizontal
                        ))
                    }
                }
            } else {
                positions.reserveCapacity(
                    (Int(self.cellVolume.xCount) + 1)
                        * (Int(self.cellVolume.yCount) + 1)
                        * (Int(self.cellVolume.zCount) + 1)
                )
                for z in 0...Int(self.cellVolume.zCount) {
                    for x in 0...Int(self.cellVolume.xCount) {
                        for y in 0...Int(self.cellVolume.yCount) {
                            positions.append(PosInt3D(
                                x: baseX + Int32(x) * horizontal,
                                y: baseY + Int32(y) * vertical,
                                z: baseZ + Int32(z) * horizontal
                            ))
                        }
                    }
                }
            }
            var evaluator = BulkDensityBufferEvaluator(
                registry: self.registry,
                cacheIDs: [:],
                cachePointer: nil,
                cacheElementsPerCell: self.cellSize.blockCount,
                cellSize: self.cellSize,
                columnBaseX: baseX,
                columnBaseZ: baseZ,
                volumeBaseX: baseX,
                volumeBaseY: baseY,
                volumeBaseZ: baseZ,
                cellVolume: self.cellVolume,
                interpolators: result,
                mode: .interpolatorCorners(baseY: baseY)
            )
            result[interpolator.identity] = BulkDensityInterpolatorValues(
                values: evaluator.evaluate(interpolator.delegate, at: positions),
                isFlat2D: interpolator.isFlat2D
            )
        }
        return result
    }
}

private struct BulkDensityFunctionInventory {
    private struct VisitKey: Hashable {
        let identity: ObjectIdentifier
        let insideInterpolator: Bool
    }

    let registry: Registry<DensityFunction>
    private(set) var caches: [BulkDensityCacheDescriptor] = []
    private(set) var interpolators: [BulkDensityInterpolatorDescriptor] = []
    private var cacheIDs: [ObjectIdentifier: Int] = [:]
    private var interpolatorIDs: Set<ObjectIdentifier> = []
    private var visited: Set<VisitKey> = []
    private var referenceStack: [String] = []

    init(registry: Registry<DensityFunction>) {
        self.registry = registry
    }

    mutating func visit(_ function: any DensityFunction, insideInterpolator: Bool = false) throws {
        if let reference = function as? ReferenceDensityFunction {
            let key = reference.targetKey.name
            guard !self.referenceStack.contains(key) else {
                throw DensityFunctionCompilationError.badDensityFunction("Cyclic density function reference: \(key)")
            }
            guard let target = self.registry.get(reference.targetKey) else {
                throw DensityFunctionCompilationError.badDensityFunction("Missing referenced density function: \(key)")
            }
            self.referenceStack.append(key)
            defer { _ = self.referenceStack.popLast() }
            try self.visit(target, insideInterpolator: insideInterpolator)
            return
        }

        let identity = ObjectIdentifier(function as AnyObject)
        let visitKey = VisitKey(identity: identity, insideInterpolator: insideInterpolator)
        if self.visited.contains(visitKey) {
            return
        }
        self.visited.insert(visitKey)

        if let cache = self.cacheInfo(function) {
            try self.visit(cache.delegate, insideInterpolator: insideInterpolator)
            if !insideInterpolator, self.cacheIDs[identity] == nil {
                let id = self.caches.count
                self.cacheIDs[identity] = id
                self.caches.append(BulkDensityCacheDescriptor(id: id, identity: identity, kind: cache.kind, delegate: cache.delegate))
            }
            return
        }
        if let interpolator = self.interpolatorDelegate(function) {
            try self.visit(interpolator, insideInterpolator: true)
            if self.interpolatorIDs.insert(identity).inserted {
                self.interpolators.append(BulkDensityInterpolatorDescriptor(
                    identity: identity,
                    delegate: interpolator,
                    isFlat2D: self.cacheInfo(interpolator)?.kind == .flat
                ))
            }
            return
        }
        if let unary = function as? UnaryDensityFunction {
            try self.visit(unary.inputOperand, insideInterpolator: insideInterpolator)
        } else if let binary = function as? BinaryDensityFunction {
            try self.visit(binary.firstOperand, insideInterpolator: insideInterpolator)
            try self.visit(binary.secondOperand, insideInterpolator: insideInterpolator)
        } else if let clampFunction = function as? ClampDensityFunction {
            try self.visit(clampFunction.clampedInput, insideInterpolator: insideInterpolator)
        } else if let rangeChoice = function as? RangeChoice {
            try self.visit(rangeChoice.inputChoiceFunction, insideInterpolator: insideInterpolator)
            try self.visit(rangeChoice.whenInRangeOutput, insideInterpolator: insideInterpolator)
            try self.visit(rangeChoice.whenOutOfRangeOutput, insideInterpolator: insideInterpolator)
        } else if let shiftedNoise = function as? ShiftedNoise {
            try self.visit(shiftedNoise.shiftXFunction, insideInterpolator: insideInterpolator)
            try self.visit(shiftedNoise.shiftYFunction, insideInterpolator: insideInterpolator)
            try self.visit(shiftedNoise.shiftZFunction, insideInterpolator: insideInterpolator)
        } else if let weirdScaledSampler = function as? WeirdScaledSampler {
            try self.visit(weirdScaledSampler.inputFunction, insideInterpolator: insideInterpolator)
        } else if let blendDensity = function as? BlendDensity {
            try self.visit(blendDensity.argumentFunction, insideInterpolator: insideInterpolator)
        } else if let findTopSurface = function as? FindTopSurface {
            try self.visit(findTopSurface.densityFunction, insideInterpolator: insideInterpolator)
            try self.visit(findTopSurface.upperBoundFunction, insideInterpolator: insideInterpolator)
        } else if let spline = function as? SplineDensityFunction {
            try self.visit(spline.splineSegment, insideInterpolator: insideInterpolator)
        } else if let wrapper = function as? any DensityFunctionWrapperIntrospectable {
            try self.visit(wrapper.wrappedDensityFunction, insideInterpolator: insideInterpolator)
        }
    }

    private mutating func visit(_ segment: SplineSegment, insideInterpolator: Bool) throws {
        guard case .object(let object) = segment else { return }
        try self.visit(object.inputFunction, insideInterpolator: insideInterpolator)
        for value in object.pointValues {
            try self.visit(value, insideInterpolator: insideInterpolator)
        }
    }

    private func cacheInfo(_ function: any DensityFunction) -> (kind: BulkDensityCacheKind, delegate: any DensityFunction)? {
        if let marker = function as? CacheMarker {
            switch marker.type {
            case .flatCache: return (.flat, marker.argument)
            case .cache2D: return (.cache2D, marker.argument)
            case .interpolated, .cacheAllInCell, .cacheOnce: return nil
            }
        }
        if let cache = function as? WorldScaleFlatCache { return (.flat, cache.wrappedDensityFunction) }
        if let cache = function as? ChunkFlatCache { return (.flat, cache.wrappedDensityFunction) }
        if let cache = function as? WorldScaleCache2D { return (.cache2D, cache.wrappedDensityFunction) }
        if let cache = function as? ChunkCache2D { return (.cache2D, cache.wrappedDensityFunction) }
        return nil
    }

    private func interpolatorDelegate(_ function: any DensityFunction) -> (any DensityFunction)? {
        if let marker = function as? CacheMarker, marker.type == .interpolated { return marker.argument }
        if let interpolator = function as? ChunkInterpolatedCache { return interpolator.wrappedDensityFunction }
        return nil
    }
}

private struct BulkDensityBufferEvaluator {
    private struct MemoKey: Hashable {
        let identity: ObjectIdentifier
        let count: Int
        let firstX: Int32
        let firstY: Int32
        let firstZ: Int32
        let lastX: Int32
        let lastY: Int32
        let lastZ: Int32
        let coordinateHash: Int
    }

    let registry: Registry<DensityFunction>
    let cacheIDs: [ObjectIdentifier: Int]
    let cachePointer: UnsafeMutablePointer<Double>?
    let cacheElementsPerCell: Int
    let cellSize: DensityFunctionCellSize
    let columnBaseX: Int32
    let columnBaseZ: Int32
    let volumeBaseX: Int32
    let volumeBaseY: Int32
    let volumeBaseZ: Int32
    let cellVolume: DensityFunctionCellVolume
    let interpolators: [ObjectIdentifier: BulkDensityInterpolatorValues]
    let mode: BulkDensityEvaluationMode
    private var memo: [MemoKey: [Double]] = [:]
    private var referenceStack: [String] = []

    init(
        registry: Registry<DensityFunction>,
        cacheIDs: [ObjectIdentifier: Int],
        cachePointer: UnsafeMutablePointer<Double>?,
        cacheElementsPerCell: Int,
        cellSize: DensityFunctionCellSize,
        columnBaseX: Int32,
        columnBaseZ: Int32,
        volumeBaseX: Int32,
        volumeBaseY: Int32,
        volumeBaseZ: Int32,
        cellVolume: DensityFunctionCellVolume,
        interpolators: [ObjectIdentifier: BulkDensityInterpolatorValues],
        mode: BulkDensityEvaluationMode
    ) {
        self.registry = registry
        self.cacheIDs = cacheIDs
        self.cachePointer = cachePointer
        self.cacheElementsPerCell = cacheElementsPerCell
        self.cellSize = cellSize
        self.columnBaseX = columnBaseX
        self.columnBaseZ = columnBaseZ
        self.volumeBaseX = volumeBaseX
        self.volumeBaseY = volumeBaseY
        self.volumeBaseZ = volumeBaseZ
        self.cellVolume = cellVolume
        self.interpolators = interpolators
        self.mode = mode
    }

    mutating func evaluate(_ function: any DensityFunction, at positions: [PosInt3D]) -> [Double] {
        let identity = ObjectIdentifier(function as AnyObject)
        let key = Self.memoKey(identity: identity, positions: positions)
        if let values = self.memo[key] {
            return values
        }
        let values = self.evaluateUncached(function, identity: identity, positions: positions)
        self.memo[key] = values
        return values
    }

    private static func memoKey(identity: ObjectIdentifier, positions: [PosInt3D]) -> MemoKey {
        var hasher = Hasher()
        if let first = positions.first {
            hasher.combine(first.x)
            hasher.combine(first.y)
            hasher.combine(first.z)
        }
        if positions.count > 2 {
            let middle = positions[positions.count / 2]
            hasher.combine(middle.x)
            hasher.combine(middle.y)
            hasher.combine(middle.z)
        }
        if let last = positions.last {
            hasher.combine(last.x)
            hasher.combine(last.y)
            hasher.combine(last.z)
        }
        let first = positions.first ?? PosInt3D(x: 0, y: 0, z: 0)
        let last = positions.last ?? first
        return MemoKey(
            identity: identity,
            count: positions.count,
            firstX: first.x,
            firstY: first.y,
            firstZ: first.z,
            lastX: last.x,
            lastY: last.y,
            lastZ: last.z,
            coordinateHash: hasher.finalize()
        )
    }

    private mutating func evaluateUncached(
        _ function: any DensityFunction,
        identity: ObjectIdentifier,
        positions: [PosInt3D]
    ) -> [Double] {
        if let reference = function as? ReferenceDensityFunction {
            let key = reference.targetKey.name
            precondition(!self.referenceStack.contains(key), "Cyclic density function reference: \(key)")
            guard let target = self.registry.get(reference.targetKey) else {
                preconditionFailure("Missing referenced density function: \(key)")
            }
            self.referenceStack.append(key)
            defer { _ = self.referenceStack.popLast() }
            return self.evaluate(target, at: positions)
        }
        if let constant = function as? ConstantDensityFunction {
            return [Double](repeating: constant.constantValue, count: positions.count)
        }
        if function is BlendAlpha {
            return [Double](repeating: 1.0, count: positions.count)
        }
        if function is BlendOffset || function is BeardifierMarker {
            return [Double](repeating: 0.0, count: positions.count)
        }
        if let unary = function as? UnaryDensityFunction {
            var values = self.evaluate(unary.inputOperand, at: positions)
            Self.applyUnary(unary.operationType, to: &values)
            return values
        }
        if let binary = function as? BinaryDensityFunction {
            var lhs = self.evaluate(binary.firstOperand, at: positions)
            if binary.operationType == .MULTIPLY && lhs.allSatisfy({ $0 == 0.0 }) {
                return lhs
            }
            if binary.operationType == .MINIMUM && lhs.allSatisfy({ $0 < binary.secondOperand.lowerBoundValue() }) {
                return lhs
            }
            if binary.operationType == .MAXIMUM && lhs.allSatisfy({ $0 > binary.secondOperand.upperBoundValue() }) {
                return lhs
            }
            let rhs = self.evaluate(binary.secondOperand, at: positions)
            Self.applyBinary(binary.operationType, lhs: &lhs, rhs: rhs)
            return lhs
        }
        if let clampFunction = function as? ClampDensityFunction {
            var values = self.evaluate(clampFunction.clampedInput, at: positions)
            for index in values.indices {
                values[index] = clamp(value: values[index], lowerBound: clampFunction.minimumValue, upperBound: clampFunction.maximumValue)
            }
            return values
        }
        if let gradient = function as? YClampedGradient {
            return positions.map {
                clampedMap(
                    value: Double($0.y),
                    oldStart: Double(gradient.testingAttributes.fromY),
                    oldEnd: Double(gradient.testingAttributes.toY),
                    newStart: gradient.minimumOutputValue,
                    newEnd: gradient.maximumOutputValue
                )
            }
        }
        if let cache = self.cacheDelegate(function) {
            switch self.mode {
            case .normal:
                guard let id = self.cacheIDs[identity], let cachePointer else {
                    preconditionFailure("Bulk cache was not assigned storage during compilation.")
                }
                return positions.map { position in
                    let localX = Int(floorMod(position.x - self.columnBaseX, self.cellSize.horizontalBlockCount))
                    let localY = Int(floorMod(position.y - self.volumeBaseY, self.cellSize.verticalBlockCount))
                    let localZ = Int(floorMod(position.z - self.columnBaseZ, self.cellSize.horizontalBlockCount))
                    return cachePointer[id * self.cacheElementsPerCell + (localZ * Int(self.cellSize.horizontalBlockCount) + localX) * Int(self.cellSize.verticalBlockCount) + localY]
                }
            case .interpolatorCorners(let baseY):
                let adjusted = positions.map { position in
                    switch cache.kind {
                    case .flat:
                        return PosInt3D(x: floorDiv(position.x, by: 4) * 4, y: 0, z: floorDiv(position.z, by: 4) * 4)
                    case .cache2D:
                        return PosInt3D(x: position.x, y: baseY, z: position.z)
                    }
                }
                return self.evaluate(cache.delegate, at: adjusted)
            }
        }
        if self.isInterpolator(function) {
            switch self.mode {
            case .normal:
                guard let precomputed = self.interpolators[identity] else {
                    preconditionFailure("Interpolator was not precomputed.")
                }
                if precomputed.isFlat2D {
                    return self.sampleFlat2DInterpolator(precomputed, at: positions)
                }
                return positions.map { self.sampleInterpolator(precomputed, at: $0) }
            case .interpolatorCorners:
                return self.evaluate(self.interpolatorDelegate(function)!, at: positions)
            }
        }
        if let marker = function as? CacheMarker {
            return self.evaluate(marker.argument, at: positions)
        }
        if let wrapper = function as? ChunkPositionCache {
            return self.evaluate(wrapper.wrappedDensityFunction, at: positions)
        }
        if let rangeChoice = function as? RangeChoice {
            let input = self.evaluate(rangeChoice.inputChoiceFunction, at: positions)
            let mask = input.map { rangeChoice.minimumInclusive <= $0 && $0 < rangeChoice.maximumExclusive }
            if mask.allSatisfy({ $0 }) {
                return self.evaluate(rangeChoice.whenInRangeOutput, at: positions)
            }
            if mask.allSatisfy({ !$0 }) {
                return self.evaluate(rangeChoice.whenOutOfRangeOutput, at: positions)
            }
            let inside = self.evaluate(rangeChoice.whenInRangeOutput, at: positions)
            let outside = self.evaluate(rangeChoice.whenOutOfRangeOutput, at: positions)
            return mask.indices.map { mask[$0] ? inside[$0] : outside[$0] }
        }
        if let noise = function as? NoiseDensityFunction {
            return positions.map {
                noise.noiseSampler.sample(
                    x: Double($0.x) * noise.xzScaleValue,
                    y: Double($0.y) * noise.yScaleValue,
                    z: Double($0.z) * noise.xzScaleValue
                )
            }
        }
        if let shifted = function as? ShiftedNoise {
            let shiftX = self.evaluate(shifted.shiftXFunction, at: positions)
            let shiftY = self.evaluate(shifted.shiftYFunction, at: positions)
            let shiftZ = self.evaluate(shifted.shiftZFunction, at: positions)
            return positions.indices.map { index in
                shifted.noiseSampler.sample(
                    x: Double(positions[index].x) * shifted.xzScaleValue + shiftX[index],
                    y: Double(positions[index].y) * shifted.yScaleValue + shiftY[index],
                    z: Double(positions[index].z) * shifted.xzScaleValue + shiftZ[index]
                )
            }
        }
        if let weird = function as? WeirdScaledSampler {
            let input = self.evaluate(weird.inputFunction, at: positions)
            return positions.indices.map { index in
                let scale = weird.scaleValue(input[index])
                return scale * abs(weird.noiseSampler.sample(
                    x: Double(positions[index].x) / scale,
                    y: Double(positions[index].y) / scale,
                    z: Double(positions[index].z) / scale
                ))
            }
        }
        if let spline = function as? SplineDensityFunction {
            return self.evaluateSpline(spline.splineSegment, at: positions).map(Double.init)
        }
        if let blend = function as? BlendDensity {
            return self.evaluate(blend.argumentFunction, at: positions)
        }
        if let findTop = function as? FindTopSurface {
            let upper = self.evaluate(findTop.upperBoundFunction, at: positions)
            var output = [Double](repeating: Double(findTop.lowerBoundHeight), count: positions.count)
            for index in positions.indices {
                let startingY = Int(floor(upper[index] / Double(findTop.cellHeightValue))) * findTop.cellHeightValue
                if startingY <= findTop.lowerBoundHeight { continue }
                for y in stride(from: startingY, through: findTop.lowerBoundHeight, by: -findTop.cellHeightValue) {
                    let position = PosInt3D(x: positions[index].x, y: Int32(y), z: positions[index].z)
                    if self.evaluate(findTop.densityFunction, at: [position])[0] > 0.0 {
                        output[index] = Double(y)
                        break
                    }
                }
            }
            return output
        }
        return positions.map { function.sample(at: $0) }
    }

    private mutating func evaluateSpline(_ segment: SplineSegment, at positions: [PosInt3D]) -> [Float] {
        switch segment {
        case .number(let value):
            return [Float](repeating: value, count: positions.count)
        case .object(let object):
            let input = self.evaluate(object.inputFunction, at: positions).map(Float.init)
            let locations = object.pointLocations
            let derivatives = object.pointDerivatives
            let branches = input.map { value -> Int in
                var low = 0
                var high = locations.count
                while low < high {
                    let middle = (low + high) / 2
                    if locations[middle] < value { low = middle + 1 } else { high = middle }
                }
                return low - 1
            }
            let last = locations.count - 1
            guard let branch = branches.first, branches.allSatisfy({ $0 == branch }) else {
                let pointValues = object.pointValues.map { self.evaluateSpline($0, at: positions) }
                var output = [Float](repeating: 0.0, count: positions.count)
                for index in output.indices {
                    let laneBranch = branches[index]
                    if laneBranch < 0 || laneBranch == last {
                        let point = laneBranch < 0 ? 0 : last
                        output[index] = pointValues[point][index]
                            + derivatives[point] * (input[index] - locations[point])
                        continue
                    }
                    let start = locations[laneBranch]
                    let end = locations[laneBranch + 1]
                    let width = end - start
                    let delta = (input[index] - start) / width
                    let left = pointValues[laneBranch][index]
                    let right = pointValues[laneBranch + 1][index]
                    let difference = right - left
                    let p = derivatives[laneBranch] * width - difference
                    let q = -derivatives[laneBranch + 1] * width + difference
                    output[index] = lerp(delta: delta, start: left, end: right)
                        + delta * (1.0 - delta) * lerp(delta: delta, start: p, end: q)
                }
                return output
            }
            if branch < 0 || branch == last {
                let point = branch < 0 ? 0 : last
                var values = self.evaluateSpline(object.pointValues[point], at: positions)
                let derivative = derivatives[point]
                if derivative != 0.0 {
                    for index in values.indices {
                        values[index] += derivative * (input[index] - locations[point])
                    }
                }
                return values
            }
            let left = self.evaluateSpline(object.pointValues[branch], at: positions)
            let right = self.evaluateSpline(object.pointValues[branch + 1], at: positions)
            let start = locations[branch]
            let end = locations[branch + 1]
            let width = end - start
            var output = [Float](repeating: 0.0, count: positions.count)
            for index in output.indices {
                let delta = (input[index] - start) / width
                let difference = right[index] - left[index]
                let p = derivatives[branch] * width - difference
                let q = -derivatives[branch + 1] * width + difference
                output[index] = lerp(delta: delta, start: left[index], end: right[index])
                    + delta * (1.0 - delta) * lerp(delta: delta, start: p, end: q)
            }
            return output
        }
    }

    private func sampleInterpolator(_ precomputed: BulkDensityInterpolatorValues, at position: PosInt3D) -> Double {
        let horizontal = self.cellSize.horizontalBlockCount
        let vertical = self.cellSize.verticalBlockCount
        let cellX = Int(floorDiv(position.x - self.volumeBaseX, by: horizontal))
        let cellY = Int(floorDiv(position.y - self.volumeBaseY, by: vertical))
        let cellZ = Int(floorDiv(position.z - self.volumeBaseZ, by: horizontal))
        let deltaX = Double(floorMod(position.x - self.volumeBaseX, horizontal)) / Double(horizontal)
        let deltaZ = Double(floorMod(position.z - self.volumeBaseZ, horizontal)) / Double(horizontal)
        let xCorners = Int(self.cellVolume.xCount) + 1
        let yCorners = Int(self.cellVolume.yCount) + 1
        if precomputed.isFlat2D {
            let index00 = cellZ * xCorners + cellX
            let index10 = index00 + 1
            let index01 = index00 + xCorners
            let index11 = index01 + 1
            return lerp(
                delta: deltaZ,
                start: lerp(delta: deltaX, start: precomputed.values[index00], end: precomputed.values[index10]),
                end: lerp(delta: deltaX, start: precomputed.values[index01], end: precomputed.values[index11])
            )
        }
        let deltaY = Double(floorMod(position.y - self.volumeBaseY, vertical)) / Double(vertical)
        func index(_ x: Int, _ y: Int, _ z: Int) -> Int { ((z * xCorners) + x) * yCorners + y }
        return lerp3(
            deltaX: deltaX,
            deltaY: deltaY,
            deltaZ: deltaZ,
            x0y0z0: precomputed.values[index(cellX, cellY, cellZ)],
            x1y0z0: precomputed.values[index(cellX + 1, cellY, cellZ)],
            x0y1z0: precomputed.values[index(cellX, cellY + 1, cellZ)],
            x1y1z0: precomputed.values[index(cellX + 1, cellY + 1, cellZ)],
            x0y0z1: precomputed.values[index(cellX, cellY, cellZ + 1)],
            x1y0z1: precomputed.values[index(cellX + 1, cellY, cellZ + 1)],
            x0y1z1: precomputed.values[index(cellX, cellY + 1, cellZ + 1)],
            x1y1z1: precomputed.values[index(cellX + 1, cellY + 1, cellZ + 1)]
        )
    }

    private func sampleFlat2DInterpolator(
        _ precomputed: BulkDensityInterpolatorValues,
        at positions: [PosInt3D]
    ) -> [Double] {
        var valuesByColumn: [UInt64: Double] = [:]
        valuesByColumn.reserveCapacity(Int(self.cellSize.horizontalBlockCount * self.cellSize.horizontalBlockCount))
        var output = [Double](repeating: 0.0, count: positions.count)
        for index in positions.indices {
            let position = positions[index]
            let key = UInt64(UInt32(bitPattern: position.x)) << 32 | UInt64(UInt32(bitPattern: position.z))
            if let cached = valuesByColumn[key] {
                output[index] = cached
            } else {
                let value = self.sampleInterpolator(precomputed, at: position)
                valuesByColumn[key] = value
                output[index] = value
            }
        }
        return output
    }

    private func cacheDelegate(_ function: any DensityFunction) -> (kind: BulkDensityCacheKind, delegate: any DensityFunction)? {
        if let marker = function as? CacheMarker {
            if marker.type == .flatCache { return (.flat, marker.argument) }
            if marker.type == .cache2D { return (.cache2D, marker.argument) }
        }
        if let cache = function as? WorldScaleFlatCache { return (.flat, cache.wrappedDensityFunction) }
        if let cache = function as? ChunkFlatCache { return (.flat, cache.wrappedDensityFunction) }
        if let cache = function as? WorldScaleCache2D { return (.cache2D, cache.wrappedDensityFunction) }
        if let cache = function as? ChunkCache2D { return (.cache2D, cache.wrappedDensityFunction) }
        return nil
    }

    private func isInterpolator(_ function: any DensityFunction) -> Bool {
        self.interpolatorDelegate(function) != nil
    }

    private func interpolatorDelegate(_ function: any DensityFunction) -> (any DensityFunction)? {
        if let marker = function as? CacheMarker, marker.type == .interpolated { return marker.argument }
        if let interpolator = function as? ChunkInterpolatedCache { return interpolator.wrappedDensityFunction }
        return nil
    }

    private static func applyUnary(_ operation: UnaryDensityFunction.OperationType, to values: inout [Double]) {
        for index in values.indices {
            let value = values[index]
            switch operation {
            case .ABS: values[index] = abs(value)
            case .SQUARE: values[index] = value * value
            case .CUBE: values[index] = value * value * value
            case .HALF_NEGATIVE: values[index] = value < 0.0 ? value * 0.5 : value
            case .QUARTER_NEGATIVE: values[index] = value < 0.0 ? value * 0.25 : value
            case .SQUEEZE:
                let clamped = clamp(value: value, lowerBound: -1.0, upperBound: 1.0)
                values[index] = clamped * 0.5 - clamped * clamped * clamped / 24.0
            case .INVERT: values[index] = 1.0 / value
            }
        }
    }

    private static func applyBinary(_ operation: BinaryDensityFunction.OperationType, lhs: inout [Double], rhs: [Double]) {
        var index = 0
        if operation == .ADD || operation == .MULTIPLY {
            while index + 4 <= lhs.count {
                let left = SIMD4(lhs[index], lhs[index + 1], lhs[index + 2], lhs[index + 3])
                let right = SIMD4(rhs[index], rhs[index + 1], rhs[index + 2], rhs[index + 3])
                var result = operation == .ADD ? left + right : left * right
                if operation == .MULTIPLY {
                    for lane in 0..<4 where left[lane] == 0.0 {
                        result[lane] = 0.0
                    }
                }
                lhs[index] = result[0]
                lhs[index + 1] = result[1]
                lhs[index + 2] = result[2]
                lhs[index + 3] = result[3]
                index += 4
            }
        }
        while index < lhs.count {
            switch operation {
            case .ADD: lhs[index] += rhs[index]
            case .MULTIPLY: lhs[index] = lhs[index] == 0.0 ? 0.0 : lhs[index] * rhs[index]
            case .MINIMUM: lhs[index] = min(lhs[index], rhs[index])
            case .MAXIMUM: lhs[index] = max(lhs[index], rhs[index])
            }
            index += 1
        }
    }
}

/// Compiles a density function for one fixed generation-cell volume.
public func compile(
    densityFunction root: any DensityFunction,
    cellSize: DensityFunctionCellSize,
    cellVolume: DensityFunctionCellVolume,
    registry: Registry<DensityFunction> = Registry()
) throws -> CompiledDensityFunctionBulkProgram {
    let plan = try CellBufferedDensityFunctionPlan(
        root: root,
        registry: registry,
        cellSize: cellSize,
        cellVolume: cellVolume,
        useExternalCacheStorage: true
    )
    let function = try compileBufferedRuntimePlan(plan, registry: registry)
    return CompiledDensityFunctionBulkProgram(
        function: function,
        cellSize: cellSize,
        cellVolume: cellVolume,
        cacheCount: plan.cacheCount
    )
}

private func floorMod(_ value: Int32, _ divisor: Int32) -> Int32 {
    let remainder = value % divisor
    return remainder < 0 ? remainder + divisor : remainder
}
#else
public func compile(
    densityFunction root: any DensityFunction,
    cellSize: DensityFunctionCellSize,
    cellVolume: DensityFunctionCellVolume,
    registry: Registry<DensityFunction> = Registry()
) throws -> CompiledDensityFunctionBulkProgram {
    throw DensityFunctionCompilationError.noLLVM
}
#endif
