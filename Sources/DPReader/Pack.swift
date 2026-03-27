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

public struct DataPackRegistryLoadingOptions: OptionSet, Sendable {
    public var rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let noDensityFunctions = DataPackRegistryLoadingOptions(rawValue: 1 << 0)
    public static let noNoises = DataPackRegistryLoadingOptions(rawValue: 1 << 1)
    public static let noNoiseSettings = DataPackRegistryLoadingOptions(rawValue: 1 << 2)
    public static let noDimensions = DataPackRegistryLoadingOptions(rawValue: 1 << 3)
    public static let noBiomes = DataPackRegistryLoadingOptions(rawValue: 1 << 4)
    public static let noStructures = DataPackRegistryLoadingOptions(rawValue: 1 << 5)
    public static let noStructureSets = DataPackRegistryLoadingOptions(rawValue: 1 << 6)
}

/// Represents a data pack.
public final class DataPack {
    public let densityFunctionRegistry = Registry<DensityFunction>()
    public let noiseRegistry = Registry<NoiseDefinition>()
    public let noiseSettingsRegistry = Registry<NoiseSettings>()
    public let dimensionsRegistry = Registry<Dimension>()
    public let biomeRegistry = Registry<Biome>()
    public let tagRegistry = Registry<TagDefinition>()
    public let structureRegistry = Registry<Structure>()
    public let structureSetRegistry = Registry<StructureSet>()

    /// Loads a data pack from the given path. All loading options are turned off by default.
    /// - Parameter rootPath: The path to load the data pack from (i.e. the path containing the `pack.mcmeta` file).
    /// - Throws: Any errors thrown by the loading process.
    public convenience init(fromRootPath rootPath: URL) throws {
        try self.init(fromRootPath: rootPath, loadingOptions: DataPackRegistryLoadingOptions(rawValue: 0))
    }

    /// Loads a data pack from the given path with the given options.
    /// - Parameters:
    ///   - rootPath: The path to load the data pack from (i.e. the path containing the `pack.mcmeta` file).
    ///   - options: The options to use when loading the data pack. These are mostly for debugging purposes,
    /// and not including the right ones may break the data pack. Use with caution.
    /// - Throws: Any errors thrown by the loading process.
    public init(fromRootPath rootPath: URL, loadingOptions options: DataPackRegistryLoadingOptions) throws {
        let namespacesPath = rootPath.appendingDirectory(path: "data")
        for namespaceURL in try FileManager.default.contentsOfDirectory(at: namespacesPath, includingPropertiesForKeys: []) {
            let namespace = namespaceURL.lastPathComponent

            try self.loadTags(fromNamespaceURL: namespaceURL, withNamespace: namespace)
            if !options.contains(.noDimensions) { try self.loadDimensions(fromNamespaceURL: namespaceURL, withNamespace: namespace) }

            let worldgenURL = namespaceURL.appendingDirectory(path: "worldgen")

            if !options.contains(.noDensityFunctions) { try self.loadDensityFunctions(fromWorldgenURL: worldgenURL, withNamespace: namespace) }
            if !options.contains(.noNoises) { try self.loadNoises(fromWorldgenURL: worldgenURL, withNamespace: namespace) }
            if !options.contains(.noNoiseSettings) { try self.loadNoiseSettings(fromWorldgenURL: worldgenURL, withNamespace: namespace) }
            if !options.contains(.noBiomes) { try self.loadBiomes(fromWorldgenURL: worldgenURL, withNamespace: namespace) }
            if !options.contains(.noStructures) { try self.loadStructures(fromWorldgenURL: worldgenURL, withNamespace: namespace) }
            if !options.contains(.noStructureSets) { try self.loadStructureSets(fromWorldgenURL: worldgenURL, withNamespace: namespace) }
        }
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

    private func loadDensityFunctions(fromWorldgenURL worldgenURL: URL, withNamespace namespace: String) throws {
        let root = worldgenURL.appendingDirectory(path: "density_function")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }
        let decoder = JSONDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if !Self.shouldDecodeFile(at: filepath) { continue }
                let data = try Data(contentsOf: filepath)
                let densityFunction = try decoder.decode(DensityFunctionInitializer.self, from: data).value
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
        let decoder = JSONDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if !Self.shouldDecodeFile(at: filepath) { continue }
                let data = try Data(contentsOf: filepath)
                let noise = try decoder.decode(NoiseDefinition.self, from: data)
                let id = RegistryKey<NoiseDefinition>(referencing: DataPack.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath))
                noise.initHashes(forID: id)
                self.noiseRegistry.register(noise, forKey: id)
            }
        } else {
            throw LoadingErrors.failedToEnumerateDirectory("noise")
        }
    }

    private func loadNoiseSettings(fromWorldgenURL worldgenURL: URL, withNamespace namespace: String) throws {
        let root = worldgenURL.appendingDirectory(path: "noise_settings")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }
        let decoder = JSONDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if !Self.shouldDecodeFile(at: filepath) { continue }
                let data = try Data(contentsOf: filepath)
                let noiseSettings = try decoder.decode(NoiseSettings.self, from: data)
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
        let decoder = JSONDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if !Self.shouldDecodeFile(at: filepath) { continue }
                let data = try Data(contentsOf: filepath)
                let dimension = try decoder.decode(Dimension.self, from: data)
                let id = RegistryKey<Dimension>(referencing: DataPack.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath))
                self.dimensionsRegistry.register(dimension, forKey: id)
            }
        } else {
            throw LoadingErrors.failedToEnumerateDirectory("dimension")
        }
    }

    private func loadBiomes(fromWorldgenURL worldgenURL: URL, withNamespace namespace: String) throws {
        let root = worldgenURL.appendingDirectory(path: "biome")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }
        let decoder = JSONDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if !Self.shouldDecodeFile(at: filepath) { continue }
                let data = try Data(contentsOf: filepath)
                let biome = try decoder.decode(Biome.self, from: data)
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

        let decoder = JSONDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if !Self.shouldDecodeFile(at: filepath) { continue }
                let data = try Data(contentsOf: filepath)
                let tag = try decoder.decode(TagDefinition.self, from: data)
                let id = RegistryKey<TagDefinition>(referencing: DataPack.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath))
                self.tagRegistry.register(tag, forKey: id)
            }
        } else {
            throw LoadingErrors.failedToEnumerateDirectory("tags")
        }
    }

    private func loadStructures(fromWorldgenURL worldgenURL: URL, withNamespace namespace: String) throws {
        let root = worldgenURL.appendingDirectory(path: "structure")
        guard FileManager.default.fileExists(atPath: root.path) else {
            return
        }
        let decoder = JSONDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if !Self.shouldDecodeFile(at: filepath) { continue }
                let data = try Data(contentsOf: filepath)
                let structure = try decoder.decode(Structure.self, from: data)
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
        let decoder = JSONDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if !Self.shouldDecodeFile(at: filepath) { continue }
                let data = try Data(contentsOf: filepath)
                let structureSet = try decoder.decode(StructureSet.self, from: data)
                let id = RegistryKey<StructureSet>(referencing: DataPack.namespacedID(fromNamespace: namespace, relativeTo: root, withURL: filepath))
                self.structureSetRegistry.register(structureSet, forKey: id)
            }
        } else {
            throw LoadingErrors.failedToEnumerateDirectory("structure_set")
        }
    }

    enum LoadingErrors: Error {
        case failedToEnumerateDirectory(String)
    }
}
