import Foundation

fileprivate extension URL {
    var isDirectory: Bool {
       (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    func appendingDirectory(path: String) -> URL {
        if #available(macOS 13.0, *) {
            return self.appending(component: path, directoryHint: .isDirectory)
        } else {
            return URL(fileURLWithPath: self.relativeString + path, relativeTo: self.baseURL)
        }
    }
}

/// Registry groups that a ``DataPack`` loader should skip.
public struct DataPackRegistryLoadingOptions: OptionSet, Sendable {
    public var rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    /// Skips density-function JSON.
    public static let noDensityFunctions = DataPackRegistryLoadingOptions(rawValue: 1 << 0)
    /// Skips noise-parameter JSON.
    public static let noNoises = DataPackRegistryLoadingOptions(rawValue: 1 << 1)
    /// Skips noise-settings JSON.
    public static let noNoiseSettings = DataPackRegistryLoadingOptions(rawValue: 1 << 2)
    /// Skips dimension JSON.
    public static let noDimensions = DataPackRegistryLoadingOptions(rawValue: 1 << 3)
    /// Skips biome JSON.
    public static let noBiomes = DataPackRegistryLoadingOptions(rawValue: 1 << 4)
    /// Skips structure JSON.
    public static let noStructures = DataPackRegistryLoadingOptions(rawValue: 1 << 5)
    /// Skips structure-set JSON.
    public static let noStructureSets = DataPackRegistryLoadingOptions(rawValue: 1 << 6)
    /// Skips enchantment JSON.
    public static let noEnchantments = DataPackRegistryLoadingOptions(rawValue: 1 << 7)
    /// Skips binary structure templates.
    public static let noStructureTemplates = DataPackRegistryLoadingOptions(rawValue: 1 << 8)
    /// Skips configured-carver JSON.
    public static let noConfiguredCarvers = DataPackRegistryLoadingOptions(rawValue: 1 << 9)
    /// Skips world-clock JSON.
    public static let noWorldClocks = DataPackRegistryLoadingOptions(rawValue: 1 << 10)
}

/// Represents a data pack.
public final class DataPack {
    public let rootPath: URL
    public let densityFunctionRegistry = Registry<DensityFunction>()
    /// Compiled density functions, when compilation was requested while loading this pack.
    ///
    /// These programs are useful for density functions which do not need seed-dependent baking.
    /// World generation rebuilds its own equivalent registry after it has baked seeded noises.
    public private(set) var compiledDensityFunctionRegistry: Registry<CompiledDensityFunction>?
    /// The optional backend used to populate ``compiledDensityFunctionRegistry``.
    public let densityFunctionCompilationStrategy: CompilationBackend?
    public let noiseRegistry = Registry<NoiseDefinition>()
    public let noiseSettingsRegistry = Registry<NoiseSettings>()
    public let dimensionsRegistry = Registry<Dimension>()
    public let biomeRegistry = Registry<Biome>()
    public let enchantmentRegistry = Registry<Enchantment>()
    public let tagRegistry = Registry<TagDefinition>()
    public let structureRegistry = Registry<Structure>()
    public let structureSetRegistry = Registry<StructureSet>()
    public let structureTemplateRegistry = Registry<StructureTemplate>()
    public let structureTemplatePoolRegistry = Registry<StructureTemplatePool>()
    public let structureProcessorListRegistry = Registry<StructureProcessorList>()
    public let configuredCarverRegistry = Registry<ConfiguredCarver>()
    public let worldClockRegistry = Registry<WorldClock>()
    public let versioning: PackVersioning
    public var packFormat: Version { versioning.selectedVersion }

    /// Loads a data pack from the given path. All loading options are turned off by default.
    /// - Parameter rootPath: The path to load the data pack from (i.e. the path containing the `pack.mcmeta` file).
    /// - Throws: Any errors thrown by the loading process.
    public convenience init(fromRootPath rootPath: URL) throws {
        try self.init(fromRootPath: rootPath, loadingOptions: DataPackRegistryLoadingOptions(rawValue: 0))
    }

    /// Loads a data pack from the given path, decoding it as the requested pack format.
    /// - Parameters:
    ///   - rootPath: The path to load the data pack from.
    ///   - decodingVersion: The pack format to decode against. It must be supported by the pack metadata.
    public convenience init(fromRootPath rootPath: URL, decodingVersion: Version) throws {
        try self.init(
            fromRootPath: rootPath,
            loadingOptions: DataPackRegistryLoadingOptions(rawValue: 0),
            decodingVersion: decodingVersion
        )
    }

    /// Loads a data pack from the given path with the given options.
    /// - Parameters:
    ///   - rootPath: The path to load the data pack from (i.e. the path containing the `pack.mcmeta` file).
    ///   - options: The options to use when loading the data pack. These are mostly for debugging purposes,
    /// and not including the right ones may break the data pack. Use with caution.
    /// - Throws: Any errors thrown by the loading process.
    public convenience init(fromRootPath rootPath: URL, loadingOptions options: DataPackRegistryLoadingOptions) throws {
        try self.init(fromRootPath: rootPath, loadingOptions: options, decodingVersion: nil)
    }

    /// Loads a data pack and compiles its density-function registry using `strategy`.
    public convenience init(
        fromRootPath rootPath: URL,
        densityFunctionCompilationStrategy strategy: CompilationBackend
    ) throws {
        try self.init(
            fromRootPath: rootPath,
            loadingOptions: DataPackRegistryLoadingOptions(rawValue: 0),
            decodingVersion: nil,
            densityFunctionCompilationStrategy: strategy
        )
    }

    /// Loads a data pack from the given path with the given options and decoding version.
    /// - Parameters:
    ///   - rootPath: The path to load the data pack from (i.e. the path containing the `pack.mcmeta` file).
    ///   - options: The options to use when loading the data pack.
    ///   - decodingVersion: The pack format to decode against. If omitted, the highest declared supported version is used.
    public init(
        fromRootPath rootPath: URL,
        loadingOptions options: DataPackRegistryLoadingOptions,
        decodingVersion: Version?,
        densityFunctionCompilationStrategy: CompilationBackend? = nil
    ) throws {
        self.rootPath = rootPath
        self.densityFunctionCompilationStrategy = densityFunctionCompilationStrategy
        let configuration = try Self.loadConfiguration(fromRootPath: rootPath, decodingVersion: decodingVersion)
        self.versioning = configuration.versioning
        try self.loadDataDirectory(at: rootPath.appendingDirectory(path: "data"), loadingOptions: options)
        for overlayDirectory in configuration.overlayDirectories {
            try self.loadDataDirectory(
                at: rootPath.appendingDirectory(path: overlayDirectory).appendingDirectory(path: "data"),
                loadingOptions: options
            )
        }

        if let densityFunctionCompilationStrategy {
            try self.populateCompiledDensityFunctionRegistry(using: densityFunctionCompilationStrategy)
        }
    }

    /// Loads one `data` tree. Calling this repeatedly implements vanilla's
    /// base-then-overlay replacement order because registry writes replace
    /// values with the same resource location.
    private func loadDataDirectory(at namespacesPath: URL, loadingOptions options: DataPackRegistryLoadingOptions) throws {
        guard FileManager.default.fileExists(atPath: namespacesPath.path) else { return }
        for namespaceURL in try FileManager.default.contentsOfDirectory(at: namespacesPath, includingPropertiesForKeys: []) {
            guard namespaceURL.isDirectory else { continue }
            let namespace = namespaceURL.lastPathComponent
            try self.validateResourceDirectories(in: namespaceURL, namespace: namespace)

            try self.loadTags(fromNamespaceURL: namespaceURL, withNamespace: namespace)
            if !options.contains(.noEnchantments) { try self.loadEnchantments(fromNamespaceURL: namespaceURL, withNamespace: namespace) }
            if !options.contains(.noDimensions) { try self.loadDimensions(fromNamespaceURL: namespaceURL, withNamespace: namespace) }
            if !options.contains(.noWorldClocks) { try self.loadWorldClocks(fromNamespaceURL: namespaceURL, withNamespace: namespace) }
            if !options.contains(.noStructureTemplates) { try self.loadStructureTemplates(fromNamespaceURL: namespaceURL, withNamespace: namespace) }

            let worldgenURL = namespaceURL.appendingDirectory(path: "worldgen")

            try self.loadStructureTemplatePools(fromWorldgenURL: worldgenURL, withNamespace: namespace)
            try self.loadStructureProcessorLists(fromWorldgenURL: worldgenURL, withNamespace: namespace)

            if !options.contains(.noDensityFunctions) { try self.loadDensityFunctions(fromWorldgenURL: worldgenURL, withNamespace: namespace) }
            if !options.contains(.noNoises) { try self.loadNoises(fromWorldgenURL: worldgenURL, withNamespace: namespace) }
            if !options.contains(.noNoiseSettings) { try self.loadNoiseSettings(fromWorldgenURL: worldgenURL, withNamespace: namespace) }
            if !options.contains(.noBiomes) { try self.loadBiomes(fromWorldgenURL: worldgenURL, withNamespace: namespace) }
            if !options.contains(.noConfiguredCarvers) { try self.loadConfiguredCarvers(fromWorldgenURL: worldgenURL, withNamespace: namespace) }
            if !options.contains(.noStructures) { try self.loadStructures(fromWorldgenURL: worldgenURL, withNamespace: namespace) }
            if !options.contains(.noStructureSets) { try self.loadStructureSets(fromWorldgenURL: worldgenURL, withNamespace: namespace) }
        }
    }

    private func populateCompiledDensityFunctionRegistry(using strategy: CompilationBackend) throws {
        let compiled = Registry<CompiledDensityFunction>()
        try self.densityFunctionRegistry.forEach { key, densityFunction in
            compiled.register(
                try compile(
                    densityFunction: densityFunction,
                    strategy: strategy,
                    registry: self.densityFunctionRegistry
                ),
                forKey: key.convertType()
            )
        }
        self.compiledDensityFunctionRegistry = compiled
    }

    private func validateResourceDirectories(in namespaceURL: URL, namespace: String) throws {
        let renamedDirectories = [
            "advancements": "advancement",
            "functions": "function",
            "item_modifiers": "item_modifier",
            "loot_tables": "loot_table",
            "predicates": "predicate",
            "recipes": "recipe",
            "structures": "structure"
        ]
        for (legacy, current) in renamedDirectories {
            let invalid = packFormat >= Version(major: 45, minor: 0) ? legacy : current
            let replacement = packFormat >= Version(major: 45, minor: 0) ? current : legacy
            if FileManager.default.fileExists(atPath: namespaceURL.appendingDirectory(path: invalid).path) {
                throw LoadingErrors.invalidResourcePath(
                    "data/\(namespace)/\(invalid) is invalid in pack format \(packFormat); use \(replacement)"
                )
            }
        }
    }

    public func makeDecoder() -> JSONDecoder {
        Self.makeDecoder(for: versioning)
    }

    static func namespacedID(fromNamespace namespace: String, relativeTo rootURL: URL, withURL url: URL) -> String {
        let relativePathWithExtension: String
        let relativeString = url.relativeString

        if !relativeString.hasPrefix("file:") && !relativeString.hasPrefix("/") {
            relativePathWithExtension = relativeString
        } else {
            let standardizedRootPath = rootURL.standardizedFileURL.path
            let rootPrefix = standardizedRootPath.hasSuffix("/") ? standardizedRootPath : standardizedRootPath + "/"
            let standardizedFilePath = url.standardizedFileURL.path

            if standardizedFilePath.hasPrefix(rootPrefix) {
                relativePathWithExtension = String(standardizedFilePath.dropFirst(rootPrefix.count))
            } else {
                relativePathWithExtension = url.lastPathComponent
            }
        }

        return namespace + ":" + (relativePathWithExtension as NSString).deletingPathExtension
    }

    private static func shouldDecodeFile(at filepath: URL) -> Bool {
        !filepath.isDirectory && filepath.pathExtension.lowercased() == "json"
    }

    private static func shouldDecodeStructureTemplate(at filepath: URL) -> Bool {
        !filepath.isDirectory && filepath.pathExtension.lowercased() == "nbt"
    }

    private func decodeResource<T: Decodable>(
        _ type: T.Type,
        at filepath: URL,
        using decoder: JSONDecoder
    ) throws -> T {
        do {
            return try decoder.decode(type, from: Data(contentsOf: filepath))
        } catch {
            throw LoadingErrors.invalidResource(
                path: filepath.standardizedFileURL.path,
                reason: String(describing: error)
            )
        }
    }

    private struct LoadingConfiguration {
        let versioning: PackVersioning
        let overlayDirectories: [String]
    }

    private static func loadConfiguration(fromRootPath rootPath: URL, decodingVersion: Version?) throws -> LoadingConfiguration {
        let metadataURL = rootPath.appendingPathComponent("pack.mcmeta")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw LoadingErrors.invalidPackMetadata(
                "missing required pack.mcmeta; every data pack must declare its supported pack format"
            )
        }

        let data = try Data(contentsOf: metadataURL)
        let metadata = try JSONDecoder().decode(PackMetadata.self, from: data)
        let versioning = try metadata.pack.makeVersioning(decodingVersion: decodingVersion)
        try metadata.validate(for: versioning.selectedVersion)
        let overlayDirectories = try metadata.applicableOverlayDirectories(for: versioning.selectedVersion)
        return LoadingConfiguration(versioning: versioning, overlayDirectories: overlayDirectories)
    }

    private static func makeDecoder(for versioning: PackVersioning) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.setDPReaderVersioning(versioning)
        return decoder
    }

    private func loadDensityFunctions(fromWorldgenURL worldgenURL: URL, withNamespace namespace: String) throws {
        let root = worldgenURL.appendingDirectory(path: "density_function")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }
        let decoder = makeDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if !Self.shouldDecodeFile(at: filepath) { continue }
                let densityFunction = try decodeResource(DensityFunctionInitializer.self, at: filepath, using: decoder).value
                self.densityFunctionRegistry.register(
                    densityFunction,
                    forKey: RegistryKey(referencing: DataPack.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath))
                )
            }
        } else {
            throw LoadingErrors.failedToEnumerateDirectory("density_function")
        }
    }

    private func loadNoises(fromWorldgenURL worldgenURL: URL, withNamespace namespace: String) throws {
        let root = worldgenURL.appendingDirectory(path: "noise")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }
        let decoder = makeDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if !Self.shouldDecodeFile(at: filepath) { continue }
                let noise = try decodeResource(NoiseDefinition.self, at: filepath, using: decoder)
                let id = RegistryKey<NoiseDefinition>(referencing: DataPack.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath))
                noise.initHashes(forID: id)
                self.noiseRegistry.register(noise, forKey: id)
            }
        } else {
            throw LoadingErrors.failedToEnumerateDirectory("noise")
        }
    }

    private func loadConfiguredCarvers(fromWorldgenURL worldgenURL: URL, withNamespace namespace: String) throws {
        let root = worldgenURL.appendingDirectory(path: "configured_carver")
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let decoder = makeDecoder()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.producesRelativePathURLs]
        ) else {
            throw LoadingErrors.failedToEnumerateDirectory("configured_carver")
        }
        for case let filepath as URL in enumerator {
            if !Self.shouldDecodeFile(at: filepath) { continue }
            let value = try decodeResource(ConfiguredCarver.self, at: filepath, using: decoder)
            let key = RegistryKey<ConfiguredCarver>(
                referencing: DataPack.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath)
            )
            self.configuredCarverRegistry.register(value, forKey: key)
        }
    }

    private func loadNoiseSettings(fromWorldgenURL worldgenURL: URL, withNamespace namespace: String) throws {
        let root = worldgenURL.appendingDirectory(path: "noise_settings")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }
        let decoder = makeDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if !Self.shouldDecodeFile(at: filepath) { continue }
                let noiseSettings = try decodeResource(NoiseSettings.self, at: filepath, using: decoder)
                let id = RegistryKey<NoiseSettings>(referencing: DataPack.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath))
                self.noiseSettingsRegistry.register(noiseSettings, forKey: id)
            }
        } else {
            throw LoadingErrors.failedToEnumerateDirectory("noise_settings")
        }
    }

    private func loadDimensions(fromNamespaceURL namespaceURL: URL, withNamespace namespace: String) throws {
        let root = namespaceURL.appendingDirectory(path: "dimension")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }
        let decoder = makeDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if !Self.shouldDecodeFile(at: filepath) { continue }
                let dimension = try decodeResource(Dimension.self, at: filepath, using: decoder)
                let id = RegistryKey<Dimension>(referencing: DataPack.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath))
                self.dimensionsRegistry.register(dimension, forKey: id)
            }
        } else {
            throw LoadingErrors.failedToEnumerateDirectory("dimension")
        }
    }

    private func loadEnchantments(fromNamespaceURL namespaceURL: URL, withNamespace namespace: String) throws {
        let root = namespaceURL.appendingDirectory(path: "enchantment")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }
        let decoder = makeDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if !Self.shouldDecodeFile(at: filepath) { continue }
                let enchantment = try decodeResource(Enchantment.self, at: filepath, using: decoder)
                let id = RegistryKey<Enchantment>(referencing: DataPack.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath))
                self.enchantmentRegistry.register(enchantment, forKey: id)
            }
        } else {
            throw LoadingErrors.failedToEnumerateDirectory("enchantment")
        }
    }

    private func loadWorldClocks(fromNamespaceURL namespaceURL: URL, withNamespace namespace: String) throws {
        let root = namespaceURL.appendingDirectory(path: "world_clock")
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let decoder = makeDecoder()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.producesRelativePathURLs]
        ) else {
            throw LoadingErrors.failedToEnumerateDirectory("world_clock")
        }
        for case let filepath as URL in enumerator where Self.shouldDecodeFile(at: filepath) {
            let clock = try decodeResource(WorldClock.self, at: filepath, using: decoder)
            self.worldClockRegistry.register(
                clock,
                forKey: RegistryKey(referencing: Self.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath))
            )
        }
    }

    private func loadBiomes(fromWorldgenURL worldgenURL: URL, withNamespace namespace: String) throws {
        let root = worldgenURL.appendingDirectory(path: "biome")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }
        let decoder = makeDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if !Self.shouldDecodeFile(at: filepath) { continue }
                let biome = try decodeResource(Biome.self, at: filepath, using: decoder)
                let id = RegistryKey<Biome>(referencing: DataPack.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath))
                self.biomeRegistry.register(biome, forKey: id)
            }
        } else {
            throw LoadingErrors.failedToEnumerateDirectory("biome")
        }
    }

    private func loadTags(fromNamespaceURL namespaceURL: URL, withNamespace namespace: String) throws {
        let root = namespaceURL.appendingDirectory(path: "tags")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }

        let decoder = makeDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if !Self.shouldDecodeFile(at: filepath) { continue }
                let tagID = Self.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath)
                let category = tagID.split(separator: ":", maxSplits: 1).last?.split(separator: "/").first.map(String.init) ?? ""
                let renamedCategories: [String: String] = [
                    "blocks": "block", "items": "item", "fluids": "fluid",
                    "entity_types": "entity_type", "game_events": "game_event",
                    "damage_types": "damage_type", "banner_patterns": "banner_pattern",
                    "cat_variants": "cat_variant", "painting_variants": "painting_variant",
                    "point_of_interest_types": "point_of_interest_type"
                ]
                if let singular = renamedCategories[category], packFormat >= Version(major: 43, minor: 0) {
                    throw LoadingErrors.invalidResourcePath(
                        "data/\(namespace)/tags/\(category) is invalid in pack format \(packFormat); use tags/\(singular)"
                    )
                }
                if let plural = renamedCategories.first(where: { $0.value == category })?.key,
                   packFormat < Version(major: 43, minor: 0) {
                    throw LoadingErrors.invalidResourcePath(
                        "data/\(namespace)/tags/\(category) is invalid in pack format \(packFormat); use tags/\(plural)"
                    )
                }
                if category == "functions", packFormat >= Version(major: 45, minor: 0) {
                    throw LoadingErrors.invalidResourcePath(
                        "data/\(namespace)/tags/functions is invalid in pack format \(packFormat); use tags/function"
                    )
                }
                if category == "function", packFormat < Version(major: 45, minor: 0) {
                    throw LoadingErrors.invalidResourcePath(
                        "data/\(namespace)/tags/function is invalid in pack format \(packFormat); use tags/functions"
                    )
                }
                let tag = try decodeResource(TagDefinition.self, at: filepath, using: decoder)
                let id = RegistryKey<TagDefinition>(referencing: DataPack.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath))
                self.tagRegistry.register(tag, forKey: id)
            }
        } else {
            throw LoadingErrors.failedToEnumerateDirectory("tags")
        }
    }

    private func loadStructureTemplates(fromNamespaceURL namespaceURL: URL, withNamespace namespace: String) throws {
        let directory = packFormat >= Version(major: 45, minor: 0) ? "structure" : "structures"
        let root = namespaceURL.appendingDirectory(path: directory)
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }

        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if !Self.shouldDecodeStructureTemplate(at: filepath) { continue }
                let template = try StructureTemplate(fromFileAt: filepath, packFormat: packFormat)
                let id = RegistryKey<StructureTemplate>(referencing: DataPack.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath))
                self.structureTemplateRegistry.register(template, forKey: id)
            }
        } else {
            throw LoadingErrors.failedToEnumerateDirectory("structure")
        }
    }

    private func loadStructureTemplatePools(fromWorldgenURL worldgenURL: URL, withNamespace namespace: String) throws {
        let root = worldgenURL.appendingDirectory(path: "template_pool")
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let decoder = makeDecoder()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) else {
            throw LoadingErrors.failedToEnumerateDirectory("template_pool")
        }
        for case let filepath as URL in enumerator where Self.shouldDecodeFile(at: filepath) {
            let pool = try decodeResource(StructureTemplatePool.self, at: filepath, using: decoder)
            self.structureTemplatePoolRegistry.register(pool, forKey: RegistryKey(referencing: DataPack.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath)))
        }
    }

    private func loadStructureProcessorLists(fromWorldgenURL worldgenURL: URL, withNamespace namespace: String) throws {
        let root = worldgenURL.appendingDirectory(path: "processor_list")
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        let decoder = makeDecoder()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) else {
            throw LoadingErrors.failedToEnumerateDirectory("processor_list")
        }
        for case let filepath as URL in enumerator where Self.shouldDecodeFile(at: filepath) {
            let value = try decodeResource(StructureProcessorList.self, at: filepath, using: decoder)
            self.structureProcessorListRegistry.register(value, forKey: RegistryKey(referencing: DataPack.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath)))
        }
    }

    private func loadStructures(fromWorldgenURL worldgenURL: URL, withNamespace namespace: String) throws {
        let root = worldgenURL.appendingDirectory(path: "structure")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }
        let decoder = makeDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if !Self.shouldDecodeFile(at: filepath) { continue }
                let structure = try decodeResource(Structure.self, at: filepath, using: decoder)
                let id = RegistryKey<Structure>(referencing: DataPack.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath))
                self.structureRegistry.register(structure, forKey: id)
            }
        } else {
            throw LoadingErrors.failedToEnumerateDirectory("structure")
        }
    }

    private func loadStructureSets(fromWorldgenURL worldgenURL: URL, withNamespace namespace: String) throws {
        let root = worldgenURL.appendingDirectory(path: "structure_set")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }
        let decoder = makeDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if !Self.shouldDecodeFile(at: filepath) { continue }
                let structureSet = try decodeResource(StructureSet.self, at: filepath, using: decoder)
                let id = RegistryKey<StructureSet>(referencing: DataPack.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath))
                self.structureSetRegistry.register(structureSet, forKey: id)
            }
        } else {
            throw LoadingErrors.failedToEnumerateDirectory("structure_set")
        }
    }

    enum LoadingErrors: Error, CustomStringConvertible {
        case failedToEnumerateDirectory(String)
        case unsupportedPackVersion(selected: Version, supported: VersionRange)
        case invalidPackMetadata(String)
        case invalidResourcePath(String)
        case invalidResource(path: String, reason: String)

        var description: String {
            switch self {
            case .failedToEnumerateDirectory(let path):
                return "Failed to enumerate data-pack directory '\(path)'"
            case .unsupportedPackVersion(let selected, let supported):
                return "Pack format \(selected) is outside the data pack's supported range \(supported)"
            case .invalidPackMetadata(let message):
                return "Invalid pack.mcmeta: \(message)"
            case .invalidResourcePath(let message):
                return "Invalid data-pack resource path: \(message)"
            case .invalidResource(let path, let reason):
                return "Invalid data-pack resource '\(path)': \(reason)"
            }
        }
    }
}

private struct PackMetadata: Decodable {
    let pack: PackMetadataPack
    let overlays: PackMetadataOverlays?

    func validate(for version: Version) throws {
        try pack.validate()
        if overlays != nil, version < Version(major: 16, minor: 0) {
            throw DataPack.LoadingErrors.invalidPackMetadata(
                "overlays require pack format 16.0 or newer"
            )
        }
        try overlays?.entries.forEach {
            try $0.validate()
            guard Self.isSafeOverlayDirectory($0.directory) else {
                throw DataPack.LoadingErrors.invalidPackMetadata(
                    "overlay directory '\($0.directory)' must be a relative path contained by the pack"
                )
            }
        }
    }

    func applicableOverlayDirectories(for version: Version) throws -> [String] {
        try (overlays?.entries ?? []).compactMap { entry in
            guard try entry.supportedVersions.contains(version) else { return nil }
            return entry.directory
        }
    }

    private static func isSafeOverlayDirectory(_ directory: String) -> Bool {
        guard !directory.isEmpty, !directory.hasPrefix("/"), !directory.hasPrefix("\\") else { return false }
        return !directory.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}

private struct PackMetadataPack: Decodable {
    let packFormat: Version?
    let minFormat: PackFormatBound?
    let maxFormat: PackFormatBound?
    let supportedFormats: LegacySupportedFormats?

    func validate() throws {
        let range = try supportedVersionRange
        let format82 = Version(major: 82, minor: 0)
        let includesLegacyFormats = range.minimum.map { $0 < format82 } ?? false
        let includesModernFormats = range.maximum.map { $0 >= format82 } ?? true

        if includesModernFormats && (minFormat == nil || maxFormat == nil) {
            throw DataPack.LoadingErrors.invalidPackMetadata(
                "min_format and max_format are required when a pack supports format 82.0 or newer"
            )
        }
        if (minFormat != nil || maxFormat != nil) && includesLegacyFormats {
            if packFormat == nil || supportedFormats == nil {
                throw DataPack.LoadingErrors.invalidPackMetadata(
                    "pack_format and supported_formats are required when a pack supports formats before 82.0"
                )
            }
        } else if !includesLegacyFormats, supportedFormats != nil {
            throw DataPack.LoadingErrors.invalidPackMetadata(
                "supported_formats is not allowed when all supported formats are 82.0 or newer; use min_format and max_format"
            )
        }
    }

    func makeVersioning(decodingVersion: Version?) throws -> PackVersioning {
        let supportedVersions = try supportedVersionRange
        guard let selectedVersion = decodingVersion ?? packFormat ?? maxFormat?.selectionVersion ?? minFormat?.selectionVersion else {
            throw DataPack.LoadingErrors.invalidPackMetadata(
                "expected pack_format, supported_formats, or min_format/max_format"
            )
        }
        guard supportedVersions.contains(selectedVersion) else {
            throw DataPack.LoadingErrors.unsupportedPackVersion(selected: selectedVersion, supported: supportedVersions)
        }
        return PackVersioning(supportedVersions: supportedVersions, selectedVersion: selectedVersion)
    }

    private var supportedVersionRange: VersionRange {
        get throws {
            if minFormat != nil || maxFormat != nil {
                guard let minFormat, let maxFormat else {
                    throw DataPack.LoadingErrors.invalidPackMetadata(
                        "min_format and max_format must be specified together"
                    )
                }
                guard minFormat.minimumVersion <= maxFormat.maximumVersion else {
                    throw DataPack.LoadingErrors.invalidPackMetadata("min_format is greater than max_format")
                }
                return .between(minFormat.minimumVersion, maxFormat.maximumVersion)
            }
            if let supportedFormats {
                return supportedFormats.range
            }
            if let packFormat {
                return .exactly(packFormat)
            }
            throw DataPack.LoadingErrors.invalidPackMetadata(
                "expected pack_format, supported_formats, or min_format/max_format"
            )
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let rawPackFormat = try container.decodeIfPresent(Int.self, forKey: .packFormat) {
            guard rawPackFormat >= 0 else {
                throw DecodingError.dataCorruptedError(forKey: .packFormat, in: container, debugDescription: "pack_format cannot be negative")
            }
            self.packFormat = Version(major: rawPackFormat, minor: 0)
        } else {
            self.packFormat = nil
        }
        self.minFormat = try container.decodeIfPresent(PackFormatBound.self, forKey: .minFormat)
        self.maxFormat = try container.decodeIfPresent(PackFormatBound.self, forKey: .maxFormat)
        self.supportedFormats = try container.decodeIfPresent(LegacySupportedFormats.self, forKey: .supportedFormats)

        if packFormat == nil && minFormat == nil && maxFormat == nil {
            throw DecodingError.keyNotFound(
                CodingKeys.packFormat,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected pack_format, supported_formats, or min_format/max_format in pack metadata"
                )
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case packFormat = "pack_format"
        case minFormat = "min_format"
        case maxFormat = "max_format"
        case supportedFormats = "supported_formats"
    }
}

private struct PackMetadataOverlays: Decodable {
    let entries: [PackMetadataOverlayEntry]
}

private struct PackMetadataOverlayEntry: Decodable {
    let directory: String
    let formats: LegacySupportedFormats?
    let minFormat: PackFormatBound?
    let maxFormat: PackFormatBound?

    func validate() throws {
        let range = try supportedVersions
        let includesLegacyFormats = range.minimum.map { $0 < Version(major: 82, minor: 0) } ?? false
        if includesLegacyFormats {
            guard formats != nil else {
                throw DataPack.LoadingErrors.invalidPackMetadata(
                    "overlay '\(directory)' must specify formats when it supports a pack format before 82.0"
                )
            }
        } else if formats != nil {
            throw DataPack.LoadingErrors.invalidPackMetadata(
                "overlay '\(directory)' must use min_format/max_format when all supported formats are 82.0 or newer"
            )
        }
    }

    var supportedVersions: VersionRange {
        get throws {
            if minFormat != nil || maxFormat != nil {
                guard let minFormat, let maxFormat else {
                    throw DataPack.LoadingErrors.invalidPackMetadata(
                        "overlay '\(directory)' must specify min_format and max_format together"
                    )
                }
                guard minFormat.minimumVersion <= maxFormat.maximumVersion else {
                    throw DataPack.LoadingErrors.invalidPackMetadata(
                        "overlay '\(directory)' has min_format greater than max_format"
                    )
                }
                return .between(minFormat.minimumVersion, maxFormat.maximumVersion)
            }
            guard let formats else {
                throw DataPack.LoadingErrors.invalidPackMetadata(
                    "overlay '\(directory)' needs formats or min_format/max_format"
                )
            }
            return formats.range
        }
    }

    private enum CodingKeys: String, CodingKey {
        case directory, formats
        case minFormat = "min_format"
        case maxFormat = "max_format"
    }
}

/// A bound remembers whether it used the one-integer shorthand. Since format
/// 82, an integer maximum means every minor version of that major.
private struct PackFormatBound: Decodable {
    let selectionVersion: Version
    let wasMajorOnly: Bool

    var minimumVersion: Version { selectionVersion }
    var maximumVersion: Version {
        wasMajorOnly
            ? Version(major: selectionVersion.major, minor: Int.max)
            : selectionVersion
    }

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let major = try? single.decode(Int.self) {
            guard major >= 0 else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Pack format cannot be negative"))
            }
            self.selectionVersion = Version(major: major, minor: 0)
            self.wasMajorOnly = true
            return
        }
        if var list = try? decoder.unkeyedContainer() {
            let major = try list.decode(Int.self)
            let minor: Int
            let wasMajorOnly: Bool
            if list.isAtEnd {
                minor = 0
                wasMajorOnly = true
            } else {
                minor = try list.decode(Int.self)
                wasMajorOnly = false
            }
            guard list.isAtEnd else {
                throw DecodingError.dataCorruptedError(in: list, debugDescription: "A full pack-format version must contain one or two integers")
            }
            guard major >= 0 && minor >= 0 else {
                throw DecodingError.dataCorruptedError(in: list, debugDescription: "Pack-format versions cannot be negative")
            }
            self.selectionVersion = Version(major: major, minor: minor)
            self.wasMajorOnly = wasMajorOnly
            return
        }
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "A pack-format bound must be an integer or a list containing one or two integers")
        )
    }
}

/// The pre-82 `supported_formats`/overlay `formats` grammar.
private struct LegacySupportedFormats: Decodable {
    let range: VersionRange

    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let major = try? single.decode(Int.self) {
            guard major >= 0 else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Pack format cannot be negative"))
            }
            self.range = .exactly(Version(major: major, minor: 0))
            return
        }
        if var list = try? decoder.unkeyedContainer() {
            let minimum = try list.decode(Int.self)
            let maximum = try list.decode(Int.self)
            guard list.isAtEnd, minimum >= 0, maximum >= 0, minimum <= maximum else {
                throw DecodingError.dataCorruptedError(in: list, debugDescription: "supported format range must be [minimum, maximum]")
            }
            self.range = .between(Version(major: minimum, minor: 0), Version(major: maximum, minor: 0))
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let minimum = try container.decode(Int.self, forKey: .minimum)
        let maximum = try container.decode(Int.self, forKey: .maximum)
        guard minimum >= 0, maximum >= 0, minimum <= maximum else {
            throw DecodingError.dataCorruptedError(forKey: .maximum, in: container, debugDescription: "max_inclusive must not be below min_inclusive")
        }
        self.range = .between(Version(major: minimum, minor: 0), Version(major: maximum, minor: 0))
    }

    private enum CodingKeys: String, CodingKey {
        case minimum = "min_inclusive"
        case maximum = "max_inclusive"
    }
}
