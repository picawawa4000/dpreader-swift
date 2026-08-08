import Foundation

final class BufferedCompiledDensityFunctionPlan: @unchecked Sendable {
    let root: any DensityFunction
    let registry: Registry<DensityFunction>
    let bufferContext: CompiledDensityFunctionBufferContext
    let options: BufferedDensityFunctionCompilationOptions

    init(
        root: any DensityFunction,
        registry: Registry<DensityFunction>,
        bufferContext: CompiledDensityFunctionBufferContext,
        options: BufferedDensityFunctionCompilationOptions
    ) {
        self.root = root
        self.registry = registry
        self.bufferContext = bufferContext
        self.options = options
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

        if let runtimeContextPointer {
            let runtimeContext = runtimeContextPointer.assumingMemoryBound(to: CompiledDensityFunctionBufferContext.self).pointee
            precondition(
                runtimeContext.xCount == self.bufferContext.xCount
                    && runtimeContext.yCount == self.bufferContext.yCount
                    && runtimeContext.zCount == self.bufferContext.zCount
                    && runtimeContext.xStep == self.bufferContext.xStep
                    && runtimeContext.yStep == self.bufferContext.yStep
                    && runtimeContext.zStep == self.bufferContext.zStep,
                "Buffered density function invoked with a runtime context that does not match the compile-time buffer context."
            )
        }

        let domain = BufferedDensityEvaluationDomain(
            xPositions: stridePositions(start: baseX, count: self.bufferContext.xCount, step: self.bufferContext.xStep),
            yPositions: stridePositions(start: baseY, count: self.bufferContext.yCount, step: self.bufferContext.yStep),
            zPositions: stridePositions(start: baseZ, count: self.bufferContext.zCount, step: self.bufferContext.zStep)
        )
        let evaluator = BufferedDensityFunctionEvaluator(registry: self.registry, profilingState: self.options.profilingState)
        let result = evaluator.evaluate(self.root, domain: domain)
        for index in 0..<result.count {
            outputPointer[index] = result[index]
        }
    }
}

private struct BufferedDensityEvaluationDomain: Hashable {
    let xPositions: [Int32]
    let yPositions: [Int32]
    let zPositions: [Int32]

    var xCount: Int { self.xPositions.count }
    var yCount: Int { self.yPositions.count }
    var zCount: Int { self.zPositions.count }
    var sampleCount: Int { self.xCount * self.yCount * self.zCount }

    @inline(__always)
    func index(x: Int, y: Int, z: Int) -> Int {
        ((z * self.xCount) + x) * self.yCount + y
    }

    @inline(__always)
    func pos(x: Int, y: Int, z: Int) -> PosInt3D {
        PosInt3D(x: self.xPositions[x], y: self.yPositions[y], z: self.zPositions[z])
    }
}

private func stridePositions(start: Int32, count: Int32, step: Int32) -> [Int32] {
    var positions: [Int32] = []
    positions.reserveCapacity(Int(count))
    var value = start
    for _ in 0..<count {
        positions.append(value)
        value &+= step
    }
    return positions
}

private final class BufferedDensityFunctionEvaluator {
    private let registry: Registry<DensityFunction>
    private let profilingState: BufferedDensityFunctionProfilingState?
    private var referenceResolutionStack: [String] = []
    private var nodes: [BufferedPlanNode] = []
    private var nodeIndicesByKey: [BufferedPlanNodeKey: Int] = [:]
    private var nodeResults: [Int: [Double]] = [:]
    private var remainingUses: [Int] = []
    private var reusableBuffers: [Int: [[Double]]] = [:]
    private var sharedNodeReuseCount = 0
    private var fusedTransformCount = 0
    private var profiler = BufferedDensityFunctionEvaluationProfiler()

    init(registry: Registry<DensityFunction>, profilingState: BufferedDensityFunctionProfilingState? = nil) {
        self.registry = registry
        self.profilingState = profilingState
    }

    func evaluate(_ function: any DensityFunction, domain: BufferedDensityEvaluationDomain) -> [Double] {
        self.referenceResolutionStack = []
        self.nodes = []
        self.nodeIndicesByKey = [:]
        self.nodeResults = [:]
        self.remainingUses = []
        self.reusableBuffers = [:]
        self.sharedNodeReuseCount = 0
        self.fusedTransformCount = 0
        self.profiler = BufferedDensityFunctionEvaluationProfiler()

        let buildStart = self.profiler.now()
        let rootNode = self.buildNode(for: function, domain: domain)
        self.profiler.markPlanBuilt(
            buildNanos: self.profiler.now() &- buildStart,
            nodeCount: self.nodes.count,
            sharedNodeReuseCount: self.sharedNodeReuseCount,
            fusedTransformCount: self.fusedTransformCount
        )
        self.remainingUses = self.nodes.map(\.useCount)
        let result = self.realizeNode(rootNode)
        if let profilingState {
            profilingState.record(self.profiler.report())
        }
        return result
    }

    private struct BufferedPlanNodeKey: Hashable {
        let functionIdentity: ObjectIdentifier
        let domain: BufferedDensityEvaluationDomain
    }

    private struct CellAxisSampleData {
        let startIndex: Int
        let endIndex: Int
        let delta: Double
    }

    private struct CellAxisData {
        let uniqueCorners: [Int32]
        let sampleData: [CellAxisSampleData]
    }

    private enum BufferedElementwiseTransform {
        case add(Double)
        case multiply(Double)
        case clamp(Double, Double)
        case unary(UnaryDensityFunction.OperationType)
    }

    private enum BufferedPlanNodeKind {
        case constant(Double)
        case yClampedGradient(YClampedGradient)
        case binaryAdd(lhs: Int, rhs: Int)
        case weirdScaledSampler(input: Int, sampler: WeirdScaledSampler)
        case flatCache(reduced: Int, xMap: [Int], zMap: [Int])
        case cache2D(reduced: Int)
        case interpolated(reduced: Int, xCells: CellAxisData, yCells: CellAxisData, zCells: CellAxisData)
        case scalar(any DensityFunction)
    }

    private struct BufferedPlanNode {
        let domain: BufferedDensityEvaluationDomain
        var kind: BufferedPlanNodeKind
        let transforms: [BufferedElementwiseTransform]
        let profileLabel: String
        var useCount: Int
    }

    private struct BorrowedBuffer {
        var values: [Double]
        let isOwned: Bool
    }

    private func buildNode(for function: any DensityFunction, domain: BufferedDensityEvaluationDomain) -> Int {
        if let key = self.nodeKey(for: function, domain: domain), let existing = self.nodeIndicesByKey[key] {
            self.nodes[existing].useCount += 1
            self.sharedNodeReuseCount += 1
            return existing
        }

        if let reference = function as? ReferenceDensityFunction {
            let key = reference.targetKey.name
            precondition(!self.referenceResolutionStack.contains(key), "Cyclic density function reference during buffered evaluation: \(key)")
            guard let target = self.registry.get(reference.targetKey) else {
                preconditionFailure("Missing referenced density function during buffered evaluation: \(key)")
            }
            self.referenceResolutionStack.append(key)
            defer {
                _ = self.referenceResolutionStack.popLast()
            }
            return self.buildNode(for: target, domain: domain)
        }

        let (producerFunction, transforms) = self.peelFusedTransforms(from: function)
        let kind: BufferedPlanNodeKind
        if let constant = producerFunction as? ConstantDensityFunction {
            kind = .constant(constant.constantValue)
        } else if producerFunction is BlendAlpha {
            kind = .constant(1.0)
        } else if producerFunction is BlendOffset || producerFunction is BeardifierMarker {
            kind = .constant(0.0)
        } else if let yClampedGradient = producerFunction as? YClampedGradient {
            kind = .yClampedGradient(yClampedGradient)
        } else if let flatCache = producerFunction as? ChunkFlatCache {
            if self.domainIsWithinBounds(domain, bounds: flatCache.bufferedSamplingBounds) {
                let (sampleXs, xMap) = self.uniqueMappedValues(from: domain.xPositions.map { floorDiv($0, by: 4) * 4 })
                let (sampleZs, zMap) = self.uniqueMappedValues(from: domain.zPositions.map { floorDiv($0, by: 4) * 4 })
                let reducedDomain = BufferedDensityEvaluationDomain(xPositions: sampleXs, yPositions: [0], zPositions: sampleZs)
                let reducedNode = self.buildNode(for: flatCache.wrappedDensityFunction, domain: reducedDomain)
                kind = .flatCache(reduced: reducedNode, xMap: xMap, zMap: zMap)
            } else {
                kind = .scalar(producerFunction)
            }
        } else if let flatCache = producerFunction as? WorldScaleFlatCache {
            let (sampleXs, xMap) = self.uniqueMappedValues(from: domain.xPositions.map { ($0 / 4) * 4 })
            let (sampleZs, zMap) = self.uniqueMappedValues(from: domain.zPositions.map { ($0 / 4) * 4 })
            let reducedDomain = BufferedDensityEvaluationDomain(xPositions: sampleXs, yPositions: [0], zPositions: sampleZs)
            let reducedNode = self.buildNode(for: flatCache.wrappedDensityFunction, domain: reducedDomain)
            kind = .flatCache(reduced: reducedNode, xMap: xMap, zMap: zMap)
        } else if let cache2D = producerFunction as? ChunkCache2D {
            if self.domainIsWithinBounds(domain, bounds: cache2D.bufferedSamplingBounds, ignoreY: true) {
                let reducedDomain = BufferedDensityEvaluationDomain(
                    xPositions: domain.xPositions,
                    yPositions: [domain.yPositions.first ?? 0],
                    zPositions: domain.zPositions
                )
                let reducedNode = self.buildNode(for: cache2D.wrappedDensityFunction, domain: reducedDomain)
                kind = .cache2D(reduced: reducedNode)
            } else {
                kind = .scalar(producerFunction)
            }
        } else if let cache2D = producerFunction as? WorldScaleCache2D {
            let reducedDomain = BufferedDensityEvaluationDomain(
                xPositions: domain.xPositions,
                yPositions: [domain.yPositions.first ?? 0],
                zPositions: domain.zPositions
            )
            let reducedNode = self.buildNode(for: cache2D.wrappedDensityFunction, domain: reducedDomain)
            kind = .cache2D(reduced: reducedNode)
        } else if let positionCache = producerFunction as? ChunkPositionCache {
            return self.buildNode(for: positionCache.wrappedDensityFunction, domain: domain)
        } else if let interpolatedCache = producerFunction as? ChunkInterpolatedCache {
            if self.domainIsWithinBounds(domain, bounds: interpolatedCache.bufferedSamplingBounds) {
                let xCells = self.uniqueCellAxisData(domain.xPositions, blockCount: interpolatedCache.bufferedHorizontalCellBlockCount)
                let yCells = self.uniqueCellAxisData(domain.yPositions, blockCount: interpolatedCache.bufferedVerticalCellBlockCount)
                let zCells = self.uniqueCellAxisData(domain.zPositions, blockCount: interpolatedCache.bufferedHorizontalCellBlockCount)
                let reducedDomain = BufferedDensityEvaluationDomain(
                    xPositions: xCells.uniqueCorners,
                    yPositions: yCells.uniqueCorners,
                    zPositions: zCells.uniqueCorners
                )
                let reducedNode = self.buildNode(for: interpolatedCache.wrappedDensityFunction, domain: reducedDomain)
                kind = .interpolated(reduced: reducedNode, xCells: xCells, yCells: yCells, zCells: zCells)
            } else {
                kind = .scalar(producerFunction)
            }
        } else if let cacheMarker = producerFunction as? CacheMarker {
            return self.buildNode(for: cacheMarker.argument, domain: domain)
        } else if let wrapper = producerFunction as? any DensityFunctionWrapperIntrospectable {
            return self.buildNode(for: wrapper.wrappedDensityFunction, domain: domain)
        } else if let binary = producerFunction as? BinaryDensityFunction, binary.operationType == .ADD {
            let lhs = self.buildNode(for: binary.firstOperand, domain: domain)
            let rhs = self.buildNode(for: binary.secondOperand, domain: domain)
            kind = .binaryAdd(lhs: lhs, rhs: rhs)
        } else if producerFunction is RangeChoice {
            kind = .scalar(producerFunction)
        } else if let blendDensity = producerFunction as? BlendDensity {
            return self.buildNode(for: blendDensity.argumentFunction, domain: domain)
        } else if let weirdScaledSampler = producerFunction as? WeirdScaledSampler {
            let inputNode = self.buildNode(for: weirdScaledSampler.inputFunction, domain: domain)
            kind = .weirdScaledSampler(input: inputNode, sampler: weirdScaledSampler)
        } else {
            kind = .scalar(producerFunction)
        }

        let nodeIndex = self.nodes.count
        self.nodes.append(
            BufferedPlanNode(
                domain: domain,
                kind: kind,
                transforms: transforms,
                profileLabel: self.profileLabel(for: producerFunction, transforms: transforms),
                useCount: 1
            )
        )
        self.fusedTransformCount += transforms.count
        if let key = self.nodeKey(for: function, domain: domain) {
            self.nodeIndicesByKey[key] = nodeIndex
        }
        return nodeIndex
    }

    private func realizeNode(_ nodeIndex: Int) -> [Double] {
        if let existing = self.nodeResults[nodeIndex] {
            self.profiler.didHitNodeResultCache(nodeIndex: nodeIndex)
            return existing
        }

        let node = self.nodes[nodeIndex]
        let start = self.profiler.now()
        self.profiler.didStartNode(
            index: nodeIndex,
            kind: self.profileKind(for: node.kind),
            label: node.profileLabel,
            domain: node.domain,
            outputValueCount: node.domain.sampleCount,
            plannedUseCount: node.useCount,
            fusedTransformCount: node.transforms.count
        )
        var output: [Double]
        switch node.kind {
        case .constant(let value):
            var buffer = self.acquireBuffer(count: node.domain.sampleCount)
            self.fillConstant(into: &buffer, value: value)
            output = buffer
        case .yClampedGradient(let function):
            var buffer = self.acquireBuffer(count: node.domain.sampleCount)
            self.fillYClampedGradient(into: &buffer, using: function, domain: node.domain)
            output = buffer
        case .binaryAdd(let lhs, let rhs):
            let lhsBuffer = self.takeNodeResult(lhs)
            let rhsBuffer = self.takeNodeResult(rhs)
            var buffer = lhsBuffer.values
            for index in buffer.indices {
                buffer[index] += rhsBuffer.values[index]
            }
            if rhsBuffer.isOwned {
                self.recycleBuffer(rhsBuffer.values)
            }
            output = buffer
        case .weirdScaledSampler(let input, let sampler):
            let inputBuffer = self.takeNodeResult(input)
            var buffer = inputBuffer.values
            for z in 0..<node.domain.zCount {
                for x in 0..<node.domain.xCount {
                    for y in 0..<node.domain.yCount {
                        let index = node.domain.index(x: x, y: y, z: z)
                        let scaleValue = sampler.scaleValue(buffer[index])
                        let pos = node.domain.pos(x: x, y: y, z: z)
                        buffer[index] = scaleValue * abs(
                            sampler.noiseSampler.sample(
                                x: Double(pos.x) / scaleValue,
                                y: Double(pos.y) / scaleValue,
                                z: Double(pos.z) / scaleValue
                            )
                        )
                    }
                }
            }
            output = buffer
        case .flatCache(let reduced, let xMap, let zMap):
            let reducedValues = self.takeNodeResult(reduced)
            var buffer = self.acquireBuffer(count: node.domain.sampleCount)
            self.expandFlatCache(into: &buffer, reducedValues: reducedValues.values, reducedDomain: self.nodes[reduced].domain, xMap: xMap, zMap: zMap, domain: node.domain)
            if reducedValues.isOwned {
                self.recycleBuffer(reducedValues.values)
            }
            output = buffer
        case .cache2D(let reduced):
            let reducedValues = self.takeNodeResult(reduced)
            var buffer = self.acquireBuffer(count: node.domain.sampleCount)
            self.expandCache2D(into: &buffer, reducedValues: reducedValues.values, reducedDomain: self.nodes[reduced].domain, domain: node.domain)
            if reducedValues.isOwned {
                self.recycleBuffer(reducedValues.values)
            }
            output = buffer
        case .interpolated(let reduced, let xCells, let yCells, let zCells):
            let reducedValues = self.takeNodeResult(reduced)
            var buffer = self.acquireBuffer(count: node.domain.sampleCount)
            self.expandInterpolated(
                into: &buffer,
                reducedValues: reducedValues.values,
                reducedDomain: self.nodes[reduced].domain,
                xCells: xCells,
                yCells: yCells,
                zCells: zCells,
                domain: node.domain
            )
            if reducedValues.isOwned {
                self.recycleBuffer(reducedValues.values)
            }
            output = buffer
        case .scalar(let function):
            var buffer = self.acquireBuffer(count: node.domain.sampleCount)
            self.fillScalarFallback(into: &buffer, using: function, domain: node.domain)
            output = buffer
        }

        self.applyTransforms(node.transforms, to: &output)
        self.nodeResults[nodeIndex] = output
        self.profiler.didStoreRetainedBuffer(count: output.count)
        self.profiler.recordNode(
            index: nodeIndex,
            kind: self.profileKind(for: node.kind),
            label: node.profileLabel,
            xCount: node.domain.xCount,
            yCount: node.domain.yCount,
            zCount: node.domain.zCount,
            sampleCount: node.domain.sampleCount,
            outputValueCount: output.count,
            plannedUseCount: node.useCount,
            fusedTransformCount: node.transforms.count,
            totalNanos: self.profiler.now() &- start
        )
        return output
    }

    private func nodeKey(for function: any DensityFunction, domain: BufferedDensityEvaluationDomain) -> BufferedPlanNodeKey? {
        guard type(of: function) is AnyObject.Type else {
            return nil
        }
        return BufferedPlanNodeKey(functionIdentity: ObjectIdentifier(function as AnyObject), domain: domain)
    }

    private func peelFusedTransforms(from function: any DensityFunction) -> (producer: any DensityFunction, transforms: [BufferedElementwiseTransform]) {
        if let unary = function as? UnaryDensityFunction {
            let inner = self.peelFusedTransforms(from: unary.inputOperand)
            return (inner.producer, inner.transforms + [.unary(unary.operationType)])
        }
        if let clampFunction = function as? ClampDensityFunction {
            let inner = self.peelFusedTransforms(from: clampFunction.clampedInput)
            return (inner.producer, inner.transforms + [.clamp(clampFunction.minimumValue, clampFunction.maximumValue)])
        }
        if let binary = function as? BinaryDensityFunction {
            switch binary.operationType {
            case .ADD:
                if let constant = self.constantValue(of: binary.firstOperand) {
                    let inner = self.peelFusedTransforms(from: binary.secondOperand)
                    return (inner.producer, inner.transforms + [.add(constant)])
                }
                if let constant = self.constantValue(of: binary.secondOperand) {
                    let inner = self.peelFusedTransforms(from: binary.firstOperand)
                    return (inner.producer, inner.transforms + [.add(constant)])
                }
            case .MULTIPLY:
                if let constant = self.constantValue(of: binary.firstOperand) {
                    let inner = self.peelFusedTransforms(from: binary.secondOperand)
                    return (inner.producer, inner.transforms + [.multiply(constant)])
                }
                if let constant = self.constantValue(of: binary.secondOperand) {
                    let inner = self.peelFusedTransforms(from: binary.firstOperand)
                    return (inner.producer, inner.transforms + [.multiply(constant)])
                }
            case .MINIMUM, .MAXIMUM:
                break
            }
        }
        if let blendDensity = function as? BlendDensity {
            return self.peelFusedTransforms(from: blendDensity.argumentFunction)
        }
        return (function, [])
    }

    private func constantValue(of function: any DensityFunction) -> Double? {
        if let constant = function as? ConstantDensityFunction {
            return constant.constantValue
        }
        return nil
    }

    private func profileLabel(for function: any DensityFunction, transforms: [BufferedElementwiseTransform]) -> String {
        var label = String(describing: type(of: function))
        guard !transforms.isEmpty else {
            return label
        }
        let suffix = transforms.map(self.transformLabel).joined(separator: " -> ")
        label += " [\(suffix)]"
        return label
    }

    private func transformLabel(_ transform: BufferedElementwiseTransform) -> String {
        switch transform {
        case .add(let constant):
            return "add(\(constant))"
        case .multiply(let constant):
            return "mul(\(constant))"
        case .clamp(let minimum, let maximum):
            return "clamp(\(minimum),\(maximum))"
        case .unary(let operation):
            return "unary.\(operation.rawValue)"
        }
    }

    private func profileKind(for kind: BufferedPlanNodeKind) -> String {
        switch kind {
        case .constant:
            return "constant"
        case .yClampedGradient:
            return "y_clamped_gradient"
        case .binaryAdd:
            return "binary_add"
        case .weirdScaledSampler:
            return "weird_scaled_sampler"
        case .flatCache:
            return "flat_cache"
        case .cache2D:
            return "cache_2d"
        case .interpolated:
            return "interpolated"
        case .scalar:
            return "scalar_fallback"
        }
    }

    private func acquireBuffer(count: Int) -> [Double] {
        if var buffers = self.reusableBuffers[count], let buffer = buffers.popLast() {
            self.reusableBuffers[count] = buffers
            self.profiler.didRemovePooledBuffer(count: count)
            return buffer
        }
        self.profiler.didAllocateBuffer(count: count)
        return [Double](repeating: 0.0, count: count)
    }

    private func recycleBuffer(_ buffer: [Double]) {
        self.reusableBuffers[buffer.count, default: []].append(buffer)
        self.profiler.didAddPooledBuffer(count: buffer.count)
    }

    private func takeNodeResult(_ nodeIndex: Int) -> BorrowedBuffer {
        let result = self.realizeNode(nodeIndex)
        self.remainingUses[nodeIndex] -= 1
        guard self.remainingUses[nodeIndex] == 0 else {
            return BorrowedBuffer(values: result, isOwned: false)
        }
        let owned = self.nodeResults.removeValue(forKey: nodeIndex) ?? result
        self.profiler.didReleaseRetainedBuffer(count: owned.count)
        return BorrowedBuffer(values: owned, isOwned: true)
    }

    private func fillConstant(into output: inout [Double], value: Double) {
        for index in output.indices {
            output[index] = value
        }
    }

    private func fillYClampedGradient(
        into output: inout [Double],
        using function: YClampedGradient,
        domain: BufferedDensityEvaluationDomain
    ) {
        let fromY = Double(function.testingAttributes.fromY)
        let toY = Double(function.testingAttributes.toY)
        let fromValue = function.minimumOutputValue
        let toValue = function.maximumOutputValue

        for z in 0..<domain.zCount {
            for x in 0..<domain.xCount {
                for y in 0..<domain.yCount {
                    let progress = (Double(domain.yPositions[y]) - fromY) / (toY - fromY)
                    let interpolated = fromValue + progress * (toValue - fromValue)
                    output[domain.index(x: x, y: y, z: z)] = clamp(value: interpolated, lowerBound: fromValue, upperBound: toValue)
                }
            }
        }
    }

    private func applyUnary(_ operation: UnaryDensityFunction.OperationType, to buffer: inout [Double]) {
        for index in buffer.indices {
            let value = buffer[index]
            switch operation {
            case .ABS:
                buffer[index] = abs(value)
            case .SQUARE:
                buffer[index] = value * value
            case .CUBE:
                buffer[index] = value * value * value
            case .HALF_NEGATIVE:
                buffer[index] = value < 0.0 ? value / 2.0 : value
            case .QUARTER_NEGATIVE:
                buffer[index] = value < 0.0 ? value / 4.0 : value
            case .SQUEEZE:
                let clampedValue = clamp(value: value, lowerBound: -1.0, upperBound: 1.0)
                buffer[index] = clampedValue / 2.0 - clampedValue * clampedValue * clampedValue / 24.0
            case .INVERT:
                buffer[index] = 1.0 / value
            }
        }
    }

    private func applyTransforms(_ transforms: [BufferedElementwiseTransform], to buffer: inout [Double]) {
        guard !transforms.isEmpty else {
            return
        }
        for index in buffer.indices {
            var value = buffer[index]
            for transform in transforms {
                switch transform {
                case .add(let constant):
                    value += constant
                case .multiply(let constant):
                    value *= constant
                case .clamp(let minimum, let maximum):
                    value = clamp(value: value, lowerBound: minimum, upperBound: maximum)
                case .unary(let operation):
                    switch operation {
                    case .ABS:
                        value = abs(value)
                    case .SQUARE:
                        value = value * value
                    case .CUBE:
                        value = value * value * value
                    case .HALF_NEGATIVE:
                        value = value < 0.0 ? value / 2.0 : value
                    case .QUARTER_NEGATIVE:
                        value = value < 0.0 ? value / 4.0 : value
                    case .SQUEEZE:
                        let clampedValue = clamp(value: value, lowerBound: -1.0, upperBound: 1.0)
                        value = clampedValue / 2.0 - clampedValue * clampedValue * clampedValue / 24.0
                    case .INVERT:
                        value = 1.0 / value
                    }
                }
            }
            buffer[index] = value
        }
    }

    private func expandFlatCache(
        into output: inout [Double],
        reducedValues: [Double],
        reducedDomain: BufferedDensityEvaluationDomain,
        xMap: [Int],
        zMap: [Int],
        domain: BufferedDensityEvaluationDomain
    ) {
        for z in 0..<domain.zCount {
            let reducedZ = zMap[z]
            for x in 0..<domain.xCount {
                let sampled = reducedValues[reducedDomain.index(x: xMap[x], y: 0, z: reducedZ)]
                for y in 0..<domain.yCount {
                    output[domain.index(x: x, y: y, z: z)] = sampled
                }
            }
        }
    }

    private func expandCache2D(
        into output: inout [Double],
        reducedValues: [Double],
        reducedDomain: BufferedDensityEvaluationDomain,
        domain: BufferedDensityEvaluationDomain
    ) {
        for z in 0..<domain.zCount {
            for x in 0..<domain.xCount {
                let sampled = reducedValues[reducedDomain.index(x: x, y: 0, z: z)]
                for y in 0..<domain.yCount {
                    output[domain.index(x: x, y: y, z: z)] = sampled
                }
            }
        }
    }

    private func expandInterpolated(
        into output: inout [Double],
        reducedValues: [Double],
        reducedDomain: BufferedDensityEvaluationDomain,
        xCells: CellAxisData,
        yCells: CellAxisData,
        zCells: CellAxisData,
        domain: BufferedDensityEvaluationDomain
    ) {
        for z in 0..<domain.zCount {
            for x in 0..<domain.xCount {
                for y in 0..<domain.yCount {
                    let xData = xCells.sampleData[x]
                    let yData = yCells.sampleData[y]
                    let zData = zCells.sampleData[z]
                    output[domain.index(x: x, y: y, z: z)] = lerp3(
                        deltaX: xData.delta,
                        deltaY: yData.delta,
                        deltaZ: zData.delta,
                        x0y0z0: reducedValues[reducedDomain.index(x: xData.startIndex, y: yData.startIndex, z: zData.startIndex)],
                        x1y0z0: reducedValues[reducedDomain.index(x: xData.endIndex, y: yData.startIndex, z: zData.startIndex)],
                        x0y1z0: reducedValues[reducedDomain.index(x: xData.startIndex, y: yData.endIndex, z: zData.startIndex)],
                        x1y1z0: reducedValues[reducedDomain.index(x: xData.endIndex, y: yData.endIndex, z: zData.startIndex)],
                        x0y0z1: reducedValues[reducedDomain.index(x: xData.startIndex, y: yData.startIndex, z: zData.endIndex)],
                        x1y0z1: reducedValues[reducedDomain.index(x: xData.endIndex, y: yData.startIndex, z: zData.endIndex)],
                        x0y1z1: reducedValues[reducedDomain.index(x: xData.startIndex, y: yData.endIndex, z: zData.endIndex)],
                        x1y1z1: reducedValues[reducedDomain.index(x: xData.endIndex, y: yData.endIndex, z: zData.endIndex)]
                    )
                }
            }
        }
    }

    private func fillScalarFallback(
        into output: inout [Double],
        using function: any DensityFunction,
        domain: BufferedDensityEvaluationDomain
    ) {
        if self.profilingState != nil {
            self.fillScalarProfiledFallback(into: &output, using: function, domain: domain)
            return
        }

        for z in 0..<domain.zCount {
            for x in 0..<domain.xCount {
                for y in 0..<domain.yCount {
                    output[domain.index(x: x, y: y, z: z)] = function.sample(at: domain.pos(x: x, y: y, z: z))
                }
            }
        }
    }

    private func fillScalarProfiledFallback(
        into output: inout [Double],
        using function: any DensityFunction,
        domain: BufferedDensityEvaluationDomain
    ) {
        for z in 0..<domain.zCount {
            for x in 0..<domain.xCount {
                for y in 0..<domain.yCount {
                    let pos = domain.pos(x: x, y: y, z: z)
                    output[domain.index(x: x, y: y, z: z)] = self.sampleProfiled(function, at: pos)
                }
            }
        }
    }

    private func sampleFast(_ function: any DensityFunction, at pos: PosInt3D) -> Double {
        if let reference = function as? ReferenceDensityFunction {
            if let registry = self.registry.get(reference.targetKey) {
                return self.sampleFast(registry, at: pos)
            }
            return function.sample(at: pos)
        }
        if let constant = function as? ConstantDensityFunction {
            return constant.constantValue
        }
        if let unary = function as? UnaryDensityFunction {
            return self.applyUnary(unary.operationType, to: self.sampleFast(unary.inputOperand, at: pos))
        }
        if let binary = function as? BinaryDensityFunction {
            let firstValue = self.sampleFast(binary.firstOperand, at: pos)
            switch binary.operationType {
            case .ADD:
                return firstValue + self.sampleFast(binary.secondOperand, at: pos)
            case .MULTIPLY:
                return firstValue == 0.0 ? 0.0 : firstValue * self.sampleFast(binary.secondOperand, at: pos)
            case .MINIMUM:
                if firstValue < binary.secondOperand.lowerBoundValue() {
                    return firstValue
                }
                return min(firstValue, self.sampleFast(binary.secondOperand, at: pos))
            case .MAXIMUM:
                if firstValue > binary.secondOperand.upperBoundValue() {
                    return firstValue
                }
                return max(firstValue, self.sampleFast(binary.secondOperand, at: pos))
            }
        }
        if let clampFunction = function as? ClampDensityFunction {
            return clamp(
                value: self.sampleFast(clampFunction.clampedInput, at: pos),
                lowerBound: clampFunction.minimumValue,
                upperBound: clampFunction.maximumValue
            )
        }
        if let yClampedGradient = function as? YClampedGradient {
            return clampedMap(
                value: Double(pos.y),
                oldStart: Double(yClampedGradient.testingAttributes.fromY),
                oldEnd: Double(yClampedGradient.testingAttributes.toY),
                newStart: yClampedGradient.minimumOutputValue,
                newEnd: yClampedGradient.maximumOutputValue
            )
        }
        if let rangeChoice = function as? RangeChoice {
            let inputValue = self.sampleFast(rangeChoice.inputChoiceFunction, at: pos)
            if rangeChoice.minimumInclusive <= inputValue && inputValue < rangeChoice.maximumExclusive {
                return self.sampleFastRangeChoiceBranch(
                    rangeChoice.whenInRangeOutput,
                    inputChoice: rangeChoice.inputChoiceFunction,
                    inputValue: inputValue,
                    at: pos
                )
            }
            return self.sampleFastRangeChoiceBranch(
                rangeChoice.whenOutOfRangeOutput,
                inputChoice: rangeChoice.inputChoiceFunction,
                inputValue: inputValue,
                at: pos
            )
        }
        if let shiftedNoise = function as? ShiftedNoise {
            let x = Double(pos.x) * shiftedNoise.xzScaleValue + self.sampleFast(shiftedNoise.shiftXFunction, at: pos)
            let y = Double(pos.y) * shiftedNoise.yScaleValue + self.sampleFast(shiftedNoise.shiftYFunction, at: pos)
            let z = Double(pos.z) * shiftedNoise.xzScaleValue + self.sampleFast(shiftedNoise.shiftZFunction, at: pos)
            return shiftedNoise.noiseSampler.sample(x: x, y: y, z: z)
        }
        if let weirdScaledSampler = function as? WeirdScaledSampler {
            let density = self.sampleFast(weirdScaledSampler.inputFunction, at: pos)
            let scale = weirdScaledSampler.scaleValue(density)
            return scale * abs(
                weirdScaledSampler.noiseSampler.sample(
                    x: Double(pos.x) / scale,
                    y: Double(pos.y) / scale,
                    z: Double(pos.z) / scale
                )
            )
        }
        if let blendDensity = function as? BlendDensity {
            return self.sampleFast(blendDensity.argumentFunction, at: pos)
        }
        if let findTopSurface = function as? FindTopSurface {
            let upper = self.sampleFast(findTopSurface.upperBoundFunction, at: pos)
            let startingY = Int(floor(upper / Double(findTopSurface.cellHeightValue))) * findTopSurface.cellHeightValue
            if startingY <= findTopSurface.lowerBoundHeight {
                return Double(findTopSurface.lowerBoundHeight)
            }
            for sampleY in stride(from: startingY, through: findTopSurface.lowerBoundHeight, by: -findTopSurface.cellHeightValue) {
                let samplePos = PosInt3D(x: pos.x, y: Int32(sampleY), z: pos.z)
                if self.sampleFast(findTopSurface.densityFunction, at: samplePos) > 0.0 {
                    return Double(sampleY)
                }
            }
            return Double(findTopSurface.lowerBoundHeight)
        }
        if let wrapper = function as? any DensityFunctionWrapperIntrospectable {
            return self.sampleFast(wrapper.wrappedDensityFunction, at: pos)
        }
        return function.sample(at: pos)
    }

    private func sampleFastRangeChoiceBranch(
        _ branch: any DensityFunction,
        inputChoice: any DensityFunction,
        inputValue: Double,
        at pos: PosInt3D
    ) -> Double {
        if self.sameDensityFunctionInstance(branch, inputChoice) {
            return inputValue
        }
        if let constant = branch as? ConstantDensityFunction {
            return constant.constantValue
        }
        if let unary = branch as? UnaryDensityFunction, self.sameDensityFunctionInstance(unary.inputOperand, inputChoice) {
            return self.applyUnary(unary.operationType, to: inputValue)
        }
        if let clampFunction = branch as? ClampDensityFunction, self.sameDensityFunctionInstance(clampFunction.clampedInput, inputChoice) {
            return clamp(value: inputValue, lowerBound: clampFunction.minimumValue, upperBound: clampFunction.maximumValue)
        }
        if let binary = branch as? BinaryDensityFunction {
            let leftIsInput = self.sameDensityFunctionInstance(binary.firstOperand, inputChoice)
            let rightIsInput = self.sameDensityFunctionInstance(binary.secondOperand, inputChoice)
            if leftIsInput || rightIsInput {
                let otherOperand = leftIsInput ? binary.secondOperand : binary.firstOperand
                if let constant = otherOperand as? ConstantDensityFunction {
                    switch binary.operationType {
                    case .ADD:
                        return inputValue + constant.constantValue
                    case .MULTIPLY:
                        return inputValue * constant.constantValue
                    case .MINIMUM:
                        return min(inputValue, constant.constantValue)
                    case .MAXIMUM:
                        return max(inputValue, constant.constantValue)
                    }
                }
                switch binary.operationType {
                case .ADD:
                    return inputValue + self.sampleFast(otherOperand, at: pos)
                case .MULTIPLY:
                    return inputValue == 0.0 ? 0.0 : inputValue * self.sampleFast(otherOperand, at: pos)
                case .MINIMUM:
                    if inputValue < otherOperand.lowerBoundValue() {
                        return inputValue
                    }
                    return min(inputValue, self.sampleFast(otherOperand, at: pos))
                case .MAXIMUM:
                    if inputValue > otherOperand.upperBoundValue() {
                        return inputValue
                    }
                    return max(inputValue, self.sampleFast(otherOperand, at: pos))
                }
            }
        }
        return self.sampleFast(branch, at: pos)
    }

    private func sampleProfiled(_ function: any DensityFunction, at pos: PosInt3D, path: String = "root") -> Double {
        let token = self.profiler.beginFunction(
            function,
            typeName: self.profiledFunctionType(function),
            label: path
        )
        defer {
            self.profiler.endFunction(token)
        }

        if let reference = function as? ReferenceDensityFunction {
            if let registry = self.registry.get(reference.targetKey) {
                return self.sampleProfiled(registry, at: pos, path: "\(path).ref(\(reference.targetKey.name))")
            }
            return function.sample(at: pos)
        }
        if let constant = function as? ConstantDensityFunction {
            return constant.constantValue
        }
        if let unary = function as? UnaryDensityFunction {
            let value = self.sampleProfiled(unary.inputOperand, at: pos, path: "\(path).input")
            return self.applyUnary(unary.operationType, to: value)
        }
        if let binary = function as? BinaryDensityFunction {
            let firstValue = self.sampleProfiled(binary.firstOperand, at: pos, path: "\(path).first")
            switch binary.operationType {
            case .ADD:
                return firstValue + self.sampleProfiled(binary.secondOperand, at: pos, path: "\(path).second")
            case .MULTIPLY:
                return firstValue == 0.0 ? 0.0 : firstValue * self.sampleProfiled(binary.secondOperand, at: pos, path: "\(path).second")
            case .MINIMUM:
                if firstValue < binary.secondOperand.lowerBoundValue() {
                    return firstValue
                }
                return min(firstValue, self.sampleProfiled(binary.secondOperand, at: pos, path: "\(path).second"))
            case .MAXIMUM:
                if firstValue > binary.secondOperand.upperBoundValue() {
                    return firstValue
                }
                return max(firstValue, self.sampleProfiled(binary.secondOperand, at: pos, path: "\(path).second"))
            }
        }
        if let clampFunction = function as? ClampDensityFunction {
            return clamp(
                value: self.sampleProfiled(clampFunction.clampedInput, at: pos, path: "\(path).input"),
                lowerBound: clampFunction.minimumValue,
                upperBound: clampFunction.maximumValue
            )
        }
        if let yClampedGradient = function as? YClampedGradient {
            return clampedMap(
                value: Double(pos.y),
                oldStart: Double(yClampedGradient.testingAttributes.fromY),
                oldEnd: Double(yClampedGradient.testingAttributes.toY),
                newStart: yClampedGradient.minimumOutputValue,
                newEnd: yClampedGradient.maximumOutputValue
            )
        }
        if let rangeChoice = function as? RangeChoice {
            let inputValue = self.sampleProfiled(rangeChoice.inputChoiceFunction, at: pos, path: "\(path).input")
            if rangeChoice.minimumInclusive <= inputValue && inputValue < rangeChoice.maximumExclusive {
                return self.sampleProfiledRangeChoiceBranch(
                    rangeChoice.whenInRangeOutput,
                    inputChoice: rangeChoice.inputChoiceFunction,
                    inputValue: inputValue,
                    at: pos,
                    path: "\(path).whenInRange"
                )
            }
            return self.sampleProfiledRangeChoiceBranch(
                rangeChoice.whenOutOfRangeOutput,
                inputChoice: rangeChoice.inputChoiceFunction,
                inputValue: inputValue,
                at: pos,
                path: "\(path).whenOutOfRange"
            )
        }
        if let shiftedNoise = function as? ShiftedNoise {
            let x = Double(pos.x) * shiftedNoise.xzScaleValue + self.sampleProfiled(shiftedNoise.shiftXFunction, at: pos, path: "\(path).shiftX")
            let y = Double(pos.y) * shiftedNoise.yScaleValue + self.sampleProfiled(shiftedNoise.shiftYFunction, at: pos, path: "\(path).shiftY")
            let z = Double(pos.z) * shiftedNoise.xzScaleValue + self.sampleProfiled(shiftedNoise.shiftZFunction, at: pos, path: "\(path).shiftZ")
            return shiftedNoise.noiseSampler.sample(x: x, y: y, z: z)
        }
        if let weirdScaledSampler = function as? WeirdScaledSampler {
            let density = self.sampleProfiled(weirdScaledSampler.inputFunction, at: pos, path: "\(path).input")
            let scale = weirdScaledSampler.scaleValue(density)
            return scale * abs(
                weirdScaledSampler.noiseSampler.sample(
                    x: Double(pos.x) / scale,
                    y: Double(pos.y) / scale,
                    z: Double(pos.z) / scale
                )
            )
        }
        if let blendDensity = function as? BlendDensity {
            return self.sampleProfiled(blendDensity.argumentFunction, at: pos, path: "\(path).wrapped")
        }
        if let findTopSurface = function as? FindTopSurface {
            let upper = self.sampleProfiled(findTopSurface.upperBoundFunction, at: pos, path: "\(path).upperBound")
            let startingY = Int(floor(upper / Double(findTopSurface.cellHeightValue))) * findTopSurface.cellHeightValue
            if startingY <= findTopSurface.lowerBoundHeight {
                return Double(findTopSurface.lowerBoundHeight)
            }
            for sampleY in stride(from: startingY, through: findTopSurface.lowerBoundHeight, by: -findTopSurface.cellHeightValue) {
                let samplePos = PosInt3D(x: pos.x, y: Int32(sampleY), z: pos.z)
                if self.sampleProfiled(findTopSurface.densityFunction, at: samplePos, path: "\(path).density") > 0.0 {
                    return Double(sampleY)
                }
            }
            return Double(findTopSurface.lowerBoundHeight)
        }
        if let wrapper = function as? any DensityFunctionWrapperIntrospectable {
            return self.sampleProfiled(wrapper.wrappedDensityFunction, at: pos, path: "\(path).wrapped")
        }
        return function.sample(at: pos)
    }

    private func sampleProfiledRangeChoiceBranch(
        _ branch: any DensityFunction,
        inputChoice: any DensityFunction,
        inputValue: Double,
        at pos: PosInt3D,
        path: String
    ) -> Double {
        if self.sameDensityFunctionInstance(branch, inputChoice) {
            return inputValue
        }
        if let constant = branch as? ConstantDensityFunction {
            return constant.constantValue
        }
        if let unary = branch as? UnaryDensityFunction, self.sameDensityFunctionInstance(unary.inputOperand, inputChoice) {
            return self.applyUnary(unary.operationType, to: inputValue)
        }
        if let clampFunction = branch as? ClampDensityFunction, self.sameDensityFunctionInstance(clampFunction.clampedInput, inputChoice) {
            return clamp(value: inputValue, lowerBound: clampFunction.minimumValue, upperBound: clampFunction.maximumValue)
        }
        if let binary = branch as? BinaryDensityFunction {
            let leftIsInput = self.sameDensityFunctionInstance(binary.firstOperand, inputChoice)
            let rightIsInput = self.sameDensityFunctionInstance(binary.secondOperand, inputChoice)
            if leftIsInput || rightIsInput {
                let otherOperand = leftIsInput ? binary.secondOperand : binary.firstOperand
                if let constant = otherOperand as? ConstantDensityFunction {
                    switch binary.operationType {
                    case .ADD:
                        return inputValue + constant.constantValue
                    case .MULTIPLY:
                        return inputValue * constant.constantValue
                    case .MINIMUM:
                        return min(inputValue, constant.constantValue)
                    case .MAXIMUM:
                        return max(inputValue, constant.constantValue)
                    }
                }
                switch binary.operationType {
                case .ADD:
                    return inputValue + self.sampleProfiled(otherOperand, at: pos, path: "\(path).other")
                case .MULTIPLY:
                    return inputValue == 0.0 ? 0.0 : inputValue * self.sampleProfiled(otherOperand, at: pos, path: "\(path).other")
                case .MINIMUM:
                    if inputValue < otherOperand.lowerBoundValue() {
                        return inputValue
                    }
                    return min(inputValue, self.sampleProfiled(otherOperand, at: pos, path: "\(path).other"))
                case .MAXIMUM:
                    if inputValue > otherOperand.upperBoundValue() {
                        return inputValue
                    }
                    return max(inputValue, self.sampleProfiled(otherOperand, at: pos, path: "\(path).other"))
                }
            }
        }
        return self.sampleProfiled(branch, at: pos, path: path)
    }

    private func sameDensityFunctionInstance(_ lhs: any DensityFunction, _ rhs: any DensityFunction) -> Bool {
        guard type(of: lhs) is AnyObject.Type, type(of: rhs) is AnyObject.Type else {
            return false
        }
        return ObjectIdentifier(lhs as AnyObject) == ObjectIdentifier(rhs as AnyObject)
    }

    private func applyUnary(_ operation: UnaryDensityFunction.OperationType, to value: Double) -> Double {
        switch operation {
        case .ABS:
            return abs(value)
        case .SQUARE:
            return value * value
        case .CUBE:
            return value * value * value
        case .HALF_NEGATIVE:
            return value < 0.0 ? value / 2.0 : value
        case .QUARTER_NEGATIVE:
            return value < 0.0 ? value / 4.0 : value
        case .SQUEEZE:
            let clampedValue = clamp(value: value, lowerBound: -1.0, upperBound: 1.0)
            return clampedValue / 2.0 - clampedValue * clampedValue * clampedValue / 24.0
        case .INVERT:
            return 1.0 / value
        }
    }

    private func profiledFunctionType(_ function: any DensityFunction) -> String {
        if let unary = function as? UnaryDensityFunction {
            return "UnaryDensityFunction[\(unary.operationType.rawValue)]"
        }
        if let binary = function as? BinaryDensityFunction {
            return "BinaryDensityFunction[\(binary.operationType.rawValue)]"
        }
        if let rangeChoice = function as? RangeChoice {
            return "RangeChoice[\(rangeChoice.minimumInclusive),\(rangeChoice.maximumExclusive))"
        }
        if let cacheMarker = function as? CacheMarker {
            return "CacheMarker[\(cacheMarker.type.rawValue)]"
        }
        if let weirdScaledSampler = function as? WeirdScaledSampler {
            return "WeirdScaledSampler[\(weirdScaledSampler.scalingType.rawValue)]"
        }
        return String(describing: type(of: function))
    }

    private func uniqueMappedValues(from values: [Int32]) -> (unique: [Int32], mapping: [Int]) {
        var unique: [Int32] = []
        var mapping: [Int] = []
        var indices: [Int32: Int] = [:]
        mapping.reserveCapacity(values.count)
        for value in values {
            if let existing = indices[value] {
                mapping.append(existing)
                continue
            }
            let nextIndex = unique.count
            unique.append(value)
            indices[value] = nextIndex
            mapping.append(nextIndex)
        }
        return (unique, mapping)
    }

    private func uniqueCellAxisData(_ positions: [Int32], blockCount: Int32) -> CellAxisData {
        var uniqueCorners: [Int32] = []
        var indices: [Int32: Int] = [:]
        var sampleData: [CellAxisSampleData] = []
        sampleData.reserveCapacity(positions.count)

        for position in positions {
            let start = floorDiv(position, by: blockCount) * blockCount
            let end = start + blockCount
            let startIndex = indices[start] ?? {
                let index = uniqueCorners.count
                uniqueCorners.append(start)
                indices[start] = index
                return index
            }()
            let endIndex = indices[end] ?? {
                let index = uniqueCorners.count
                uniqueCorners.append(end)
                indices[end] = index
                return index
            }()
            let delta = Double(position - start) / Double(blockCount)
            sampleData.append(CellAxisSampleData(startIndex: startIndex, endIndex: endIndex, delta: delta))
        }

        return CellAxisData(uniqueCorners: uniqueCorners, sampleData: sampleData)
    }

    private func domainIsWithinBounds(
        _ domain: BufferedDensityEvaluationDomain,
        bounds: ChunkSamplingBounds,
        ignoreY: Bool = false
    ) -> Bool {
        guard let firstX = domain.xPositions.first, let lastX = domain.xPositions.last,
            let firstZ = domain.zPositions.first, let lastZ = domain.zPositions.last
        else {
            return true
        }
        guard bounds.containsColumn(x: firstX, z: firstZ), bounds.containsColumn(x: lastX, z: lastZ) else {
            return false
        }
        if ignoreY {
            return true
        }
        guard let firstY = domain.yPositions.first, let lastY = domain.yPositions.last else {
            return true
        }
        return firstY >= bounds.minY && lastY < bounds.maxYExclusive
    }
}

private final class BufferedDensityFunctionEvaluationProfiler {
    private struct MutableNodeProfile {
        let index: Int
        let kind: String
        let label: String
        let xCount: Int
        let yCount: Int
        let zCount: Int
        let sampleCount: Int
        let outputValueCount: Int
        let plannedUseCount: Int
        let fusedTransformCount: Int
        var cacheHitCount: Int
        var totalNanos: UInt64
    }

    private struct FunctionProfileKey: Hashable {
        let objectIdentity: ObjectIdentifier?
        let label: String
    }

    private struct MutableFunctionProfile {
        let index: Int
        let type: String
        let label: String
        var callCount: Int
        var selfNanos: UInt64
        var totalNanos: UInt64
    }

    private struct ActiveFunctionFrame {
        let key: FunctionProfileKey
        let type: String
        let label: String
        let startNanos: UInt64
        var childNanos: UInt64
    }

    private var nodeProfiles: [MutableNodeProfile] = []
    private var nodeProfileIndexByNodeIndex: [Int: Int] = [:]
    private var functionProfiles: [MutableFunctionProfile] = []
    private var functionProfileIndexByKey: [FunctionProfileKey: Int] = [:]
    private var activeFunctionFrames: [ActiveFunctionFrame] = []
    private var buildNanos: UInt64 = 0
    private var nodeCount = 0
    private var sharedNodeReuseCount = 0
    private var fusedTransformCount = 0
    private var realizedNodeCount = 0
    private var nodeResultCacheHitCount = 0
    private var allocatedBufferCount = 0
    private var allocatedValueCount = 0
    private var reusedBufferCount = 0
    private var reusedValueCount = 0
    private var recycledBufferCount = 0
    private var recycledValueCount = 0
    private var storedRetainedBufferCount = 0
    private var storedRetainedValueCount = 0
    private var releasedRetainedBufferCount = 0
    private var releasedRetainedValueCount = 0
    private var currentPooledBufferCount = 0
    private var currentPooledValueCount = 0
    private var peakPooledBufferCount = 0
    private var peakPooledValueCount = 0
    private var currentRetainedBufferCount = 0
    private var currentRetainedValueCount = 0
    private var peakRetainedBufferCount = 0
    private var peakRetainedValueCount = 0
    private var events: [BufferedDensityFunctionProfilingEvent] = []
    private let totalStartNanos = DispatchTime.now().uptimeNanoseconds

    @inline(__always)
    func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func beginFunction(_ function: any DensityFunction, typeName: String, label: String) -> Int {
        let key = FunctionProfileKey(
            objectIdentity: Swift.type(of: function) is AnyObject.Type ? ObjectIdentifier(function as AnyObject) : nil,
            label: label
        )
        self.activeFunctionFrames.append(
            ActiveFunctionFrame(
                key: key,
                type: typeName,
                label: label,
                startNanos: self.now(),
                childNanos: 0
            )
        )
        return self.activeFunctionFrames.count - 1
    }

    func endFunction(_ token: Int) {
        precondition(token == self.activeFunctionFrames.count - 1, "Function profiling frames must end in LIFO order.")
        let frame = self.activeFunctionFrames.removeLast()
        let totalNanos = self.now() &- frame.startNanos
        let selfNanos = totalNanos &- frame.childNanos

        let profileIndex: Int
        if let existing = self.functionProfileIndexByKey[frame.key] {
            profileIndex = existing
            self.functionProfiles[existing].callCount += 1
            self.functionProfiles[existing].selfNanos &+= selfNanos
            self.functionProfiles[existing].totalNanos &+= totalNanos
        } else {
            let nextIndex = self.functionProfiles.count
            profileIndex = nextIndex
            self.functionProfileIndexByKey[frame.key] = nextIndex
            self.functionProfiles.append(
                MutableFunctionProfile(
                    index: nextIndex,
                    type: frame.type,
                    label: frame.label,
                    callCount: 1,
                    selfNanos: selfNanos,
                    totalNanos: totalNanos
                )
            )
        }

        if !self.activeFunctionFrames.isEmpty {
            self.activeFunctionFrames[self.activeFunctionFrames.count - 1].childNanos &+= totalNanos
        }
        _ = profileIndex
    }

    func markPlanBuilt(buildNanos: UInt64, nodeCount: Int, sharedNodeReuseCount: Int, fusedTransformCount: Int) {
        self.buildNanos = buildNanos
        self.nodeCount = nodeCount
        self.sharedNodeReuseCount = sharedNodeReuseCount
        self.fusedTransformCount = fusedTransformCount
        self.recordEvent(kind: "plan_built", valueCount: nodeCount)
    }

    func didStartNode(
        index: Int,
        kind: String,
        label: String,
        domain: BufferedDensityEvaluationDomain,
        outputValueCount: Int,
        plannedUseCount: Int,
        fusedTransformCount: Int
    ) {
        self.realizedNodeCount += 1
        self.nodeProfiles.append(
            MutableNodeProfile(
                index: index,
                kind: kind,
                label: label,
                xCount: domain.xCount,
                yCount: domain.yCount,
                zCount: domain.zCount,
                sampleCount: domain.sampleCount,
                outputValueCount: outputValueCount,
                plannedUseCount: plannedUseCount,
                fusedTransformCount: fusedTransformCount,
                cacheHitCount: 0,
                totalNanos: 0
            )
        )
        self.nodeProfileIndexByNodeIndex[index] = self.nodeProfiles.count - 1
        self.recordEvent(kind: "node_start:\(kind)", valueCount: outputValueCount)
    }

    func didAllocateBuffer(count: Int) {
        self.allocatedBufferCount += 1
        self.allocatedValueCount += count
        self.recordEvent(kind: "buffer_allocate", valueCount: count)
    }

    func didRemovePooledBuffer(count: Int) {
        self.reusedBufferCount += 1
        self.reusedValueCount += count
        self.currentPooledBufferCount -= 1
        self.currentPooledValueCount -= count
        self.recordEvent(kind: "buffer_reuse", valueCount: count)
    }

    func didAddPooledBuffer(count: Int) {
        self.recycledBufferCount += 1
        self.recycledValueCount += count
        self.currentPooledBufferCount += 1
        self.currentPooledValueCount += count
        self.updatePeaks()
        self.recordEvent(kind: "buffer_recycle", valueCount: count)
    }

    func didStoreRetainedBuffer(count: Int) {
        self.storedRetainedBufferCount += 1
        self.storedRetainedValueCount += count
        self.currentRetainedBufferCount += 1
        self.currentRetainedValueCount += count
        self.updatePeaks()
        self.recordEvent(kind: "retained_store", valueCount: count)
    }

    func didReleaseRetainedBuffer(count: Int) {
        self.releasedRetainedBufferCount += 1
        self.releasedRetainedValueCount += count
        self.currentRetainedBufferCount -= 1
        self.currentRetainedValueCount -= count
        self.recordEvent(kind: "retained_release", valueCount: count)
    }

    func didHitNodeResultCache(nodeIndex: Int) {
        self.nodeResultCacheHitCount += 1
        if let profileIndex = self.nodeProfileIndexByNodeIndex[nodeIndex] {
            self.nodeProfiles[profileIndex].cacheHitCount += 1
        }
        self.recordEvent(kind: "node_cache_hit", valueCount: nodeIndex)
    }

    func recordNode(
        index: Int,
        kind: String,
        label: String,
        xCount: Int,
        yCount: Int,
        zCount: Int,
        sampleCount: Int,
        outputValueCount: Int,
        plannedUseCount: Int,
        fusedTransformCount: Int,
        totalNanos: UInt64
    ) {
        if let profileIndex = self.nodeProfileIndexByNodeIndex[index] {
            self.nodeProfiles[profileIndex].totalNanos = totalNanos
        } else {
            self.nodeProfiles.append(
                MutableNodeProfile(
                    index: index,
                    kind: kind,
                    label: label,
                    xCount: xCount,
                    yCount: yCount,
                    zCount: zCount,
                    sampleCount: sampleCount,
                    outputValueCount: outputValueCount,
                    plannedUseCount: plannedUseCount,
                    fusedTransformCount: fusedTransformCount,
                    cacheHitCount: 0,
                    totalNanos: totalNanos
                )
            )
        }
        self.recordEvent(kind: "node_finish:\(kind)", valueCount: outputValueCount)
    }

    func report() -> BufferedDensityFunctionProfilingReport {
        BufferedDensityFunctionProfilingReport(
            buildNanos: self.buildNanos,
            totalNanos: self.now() &- self.totalStartNanos,
            nodeCount: self.nodeCount,
            sharedNodeReuseCount: self.sharedNodeReuseCount,
            fusedTransformCount: self.fusedTransformCount,
            realizedNodeCount: self.realizedNodeCount,
            nodeResultCacheHitCount: self.nodeResultCacheHitCount,
            allocatedBufferCount: self.allocatedBufferCount,
            allocatedValueCount: self.allocatedValueCount,
            reusedBufferCount: self.reusedBufferCount,
            reusedValueCount: self.reusedValueCount,
            recycledBufferCount: self.recycledBufferCount,
            recycledValueCount: self.recycledValueCount,
            storedRetainedBufferCount: self.storedRetainedBufferCount,
            storedRetainedValueCount: self.storedRetainedValueCount,
            releasedRetainedBufferCount: self.releasedRetainedBufferCount,
            releasedRetainedValueCount: self.releasedRetainedValueCount,
            currentPooledBufferCount: self.currentPooledBufferCount,
            currentPooledValueCount: self.currentPooledValueCount,
            peakPooledBufferCount: self.peakPooledBufferCount,
            peakPooledValueCount: self.peakPooledValueCount,
            currentRetainedBufferCount: self.currentRetainedBufferCount,
            currentRetainedValueCount: self.currentRetainedValueCount,
            peakRetainedBufferCount: self.peakRetainedBufferCount,
            peakRetainedValueCount: self.peakRetainedValueCount,
            nodes: self.nodeProfiles.map {
                BufferedDensityFunctionProfilingNode(
                    index: $0.index,
                    kind: $0.kind,
                    label: $0.label,
                    xCount: $0.xCount,
                    yCount: $0.yCount,
                    zCount: $0.zCount,
                    sampleCount: $0.sampleCount,
                    outputValueCount: $0.outputValueCount,
                    plannedUseCount: $0.plannedUseCount,
                    fusedTransformCount: $0.fusedTransformCount,
                    cacheHitCount: $0.cacheHitCount,
                    totalNanos: $0.totalNanos
                )
            },
            functions: self.functionProfiles.map {
                BufferedDensityFunctionProfilingFunction(
                    index: $0.index,
                    type: $0.type,
                    label: $0.label,
                    callCount: $0.callCount,
                    selfNanos: $0.selfNanos,
                    totalNanos: $0.totalNanos
                )
            },
            events: self.events
        )
    }

    private func updatePeaks() {
        let retainedBufferCount = self.currentRetainedBufferCount + self.currentPooledBufferCount
        let retainedValueCount = self.currentRetainedValueCount + self.currentPooledValueCount
        self.peakPooledBufferCount = max(self.peakPooledBufferCount, self.currentPooledBufferCount)
        self.peakPooledValueCount = max(self.peakPooledValueCount, self.currentPooledValueCount)
        self.peakRetainedBufferCount = max(self.peakRetainedBufferCount, retainedBufferCount)
        self.peakRetainedValueCount = max(self.peakRetainedValueCount, retainedValueCount)
    }

    private func recordEvent(kind: String, valueCount: Int) {
        self.events.append(
            BufferedDensityFunctionProfilingEvent(
                nanosSinceStart: self.now() &- self.totalStartNanos,
                kind: kind,
                valueCount: valueCount,
                pooledBufferCount: self.currentPooledBufferCount,
                pooledValueCount: self.currentPooledValueCount,
                retainedBufferCount: self.currentRetainedBufferCount,
                retainedValueCount: self.currentRetainedValueCount
            )
        )
    }
}

private typealias BufferedDensityFunctionEvaluatorThunk = @convention(c) (
    UInt64,
    UnsafeRawPointer?,
    Int32,
    Int32,
    Int32,
    UnsafeMutablePointer<Double>?
) -> Void

@_cdecl("dpreader_evaluate_buffered_density_function")
private func dpreaderEvaluateBufferedDensityFunction(
    _ planPointer: UInt64,
    _ runtimeContextPointer: UnsafeRawPointer?,
    _ baseX: Int32,
    _ baseY: Int32,
    _ baseZ: Int32,
    _ outputPointer: UnsafeMutablePointer<Double>?
) {
    let rawPointer = UnsafeRawPointer(bitPattern: UInt(planPointer))!
    let object = Unmanaged<AnyObject>.fromOpaque(rawPointer).takeUnretainedValue()
    let plan = object as! BufferedCompiledDensityFunctionPlan
    plan.evaluate(
        runtimeContextPointer: runtimeContextPointer,
        baseX: baseX,
        baseY: baseY,
        baseZ: baseZ,
        outputPointer: outputPointer
    )
}

@inline(__always)
func bufferedDensityFunctionEvaluatorAddress() -> UInt64 {
    let function = dpreaderEvaluateBufferedDensityFunction as BufferedDensityFunctionEvaluatorThunk
    return UInt64(UInt(bitPattern: unsafeBitCast(function, to: UnsafeRawPointer.self)))
}
