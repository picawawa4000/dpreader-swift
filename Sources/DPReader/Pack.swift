import Foundation

fileprivate extension URL {
    var isDirectory: Bool {
       (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}

struct DataPackRegistryLoadingOptions: OptionSet {
    var rawValue: UInt64

    static let loadDensityFunctions = DataPackRegistryLoadingOptions(rawValue: 1 << 0)
    static let loadNoises = DataPackRegistryLoadingOptions(rawValue: 1 << 1)
}

/// Represents a data pack.
final class DataPack {
    let densityFunctionRegistry = Registry<DensityFunction>()
    let noiseRegistry = Registry<NoiseDefinition>()

    convenience init(fromRootPath rootPath: URL) throws {
        try self.init(fromRootPath: rootPath, loadingOptions: DataPackRegistryLoadingOptions(rawValue: UInt64.max))
    }

    init(fromRootPath rootPath: URL, loadingOptions options: DataPackRegistryLoadingOptions) throws {
        let namespacesPath = rootPath.appending(path: "data", directoryHint: .isDirectory)
        for namespaceURL in try FileManager.default.contentsOfDirectory(at: namespacesPath, includingPropertiesForKeys: []) {
            let namespace = namespaceURL.lastPathComponent
            let worldgenURL = namespaceURL.appending(component: "worldgen")

            if options.contains(.loadDensityFunctions) { try self.loadDensityFunctions(fromWorldgenURL: worldgenURL, withNamespace: namespace) }
            if options.contains(.loadNoises) { try self.loadNoises(fromWorldgenURL: worldgenURL, withNamespace: namespace) }
        }
    }

    private static func namespacedID(fromNamespace namespace: String, withURL url: URL) -> String {
        return namespace + ":" + (url.relativeString as NSString).deletingPathExtension
    }

    private func loadDensityFunctions(fromWorldgenURL worldgenURL: URL, withNamespace namespace: String) throws {
        let root = worldgenURL.appending(component: "density_function")
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
        let root = worldgenURL.appending(component: "noise")
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