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

    public static let loadDensityFunctions = DataPackRegistryLoadingOptions(rawValue: 1 << 0)
    public static let loadNoises = DataPackRegistryLoadingOptions(rawValue: 1 << 1)
}

/// Represents a data pack.
public final class DataPack {
    public let densityFunctionRegistry = Registry<DensityFunction>()
    public let noiseRegistry = Registry<NoiseDefinition>()

    public convenience init(fromRootPath rootPath: URL) throws {
        try self.init(fromRootPath: rootPath, loadingOptions: DataPackRegistryLoadingOptions(rawValue: UInt64.max))
    }

    public init(fromRootPath rootPath: URL, loadingOptions options: DataPackRegistryLoadingOptions) throws {
        let namespacesPath = rootPath.appendingDirectory(path: "data")
        for namespaceURL in try FileManager.default.contentsOfDirectory(at: namespacesPath, includingPropertiesForKeys: []) {
            let namespace = namespaceURL.lastPathComponent
            let worldgenURL = namespaceURL.appendingDirectory(path: "worldgen")

            if options.contains(.loadDensityFunctions) { try self.loadDensityFunctions(fromWorldgenURL: worldgenURL, withNamespace: namespace) }
            if options.contains(.loadNoises) { try self.loadNoises(fromWorldgenURL: worldgenURL, withNamespace: namespace) }
        }
    }

    private static func namespacedID(fromNamespace namespace: String, withURL url: URL) -> String {
        return namespace + ":" + (url.relativeString as NSString).deletingPathExtension
    }

    private func loadDensityFunctions(fromWorldgenURL worldgenURL: URL, withNamespace namespace: String) throws {
        let root = worldgenURL.appendingDirectory(path: "density_function")
        let decoder = JSONDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if filepath.isDirectory { continue }
                let data = try Data(contentsOf: filepath)
                let densityFunction = try decoder.decode(DensityFunctionInitializer.self, from: data).value
                self.densityFunctionRegistry.register(densityFunction, forKey: RegistryKey(referencing: DataPack.namespacedID(fromNamespace: namespace, withURL: filepath)))
            }
        } else {
            throw LoadingErrors.failedToEnumerateDirectory("density_function")
        }
    }

    private func loadNoises(fromWorldgenURL worldgenURL: URL, withNamespace namespace: String) throws {
        let root = worldgenURL.appendingDirectory(path: "noise")
        let decoder = JSONDecoder()
        if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.producesRelativePathURLs]) {
            for case let filepath as URL in enumerator {
                if filepath.isDirectory { continue }
                let data = try Data(contentsOf: filepath)
                let noise = try decoder.decode(NoiseDefinition.self, from: data)
                self.noiseRegistry.register(noise, forKey: RegistryKey(referencing: DataPack.namespacedID(fromNamespace: namespace, withURL: filepath)))
            }
        } else {
            throw LoadingErrors.failedToEnumerateDirectory("noise")
        }
    }

    enum LoadingErrors: Error {
        case failedToEnumerateDirectory(String)
    }
}