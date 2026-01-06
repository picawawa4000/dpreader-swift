/// A registry associates keys with values.
final class Registry<T> {
    private var registry: [RegistryKey<T>: T] = [:]

    /// Registers a value at a given key. Overwrites any previous value stored at that key.
    /// - Parameters:
    ///   - value: The value to register.
    ///   - key: The key to register the value at.
    func register(_ value: T, forKey key: RegistryKey<T>) {
        self.registry[key] = value
    }

    /// Gets the value at a given key.
    /// - Parameter key: The key to get the value at.
    /// - Returns: The value at the given key.
    func get(_ key: RegistryKey<T>) -> T? {
        return self.registry[key]
    }

    /// Removes the value at a given key, if it exists.
    /// - Parameter key: The key to remove the value at.
    func remove(at key: RegistryKey<T>) {
        guard let index = self.registry.index(forKey: key) else { return }
        self.registry.remove(at: index)
    }

    /// Adds all elements of other to self.
    /// - Parameter other: The other registry.
    func mergeDown(with other: Registry<T>) {
        other.map { (key, value) in
            self.registry[key] = value
        }
    }

    /// Call body on every key-value pair in this registry.
    /// - Parameter body: The function to call on every key-value pair in this registry.
    func map(_ body: ((key: RegistryKey<T>, value: T)) -> Void) {
        self.registry.forEach(body)
    }
}

/// A typed key for use in a registry.
final class RegistryKey<T>: Hashable {
    let name: String

    init(referencing name: String) {
        self.name = name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.name)
    }

    @inline(__always) func convertType<Q>() -> RegistryKey<Q> {
        return RegistryKey<Q>(referencing: self.name)
    }

    static func ==(first: RegistryKey<T>, second: RegistryKey<T>) -> Bool {
        return first.name == second.name
    }
}