/// A registry associates keys with values.
public final class Registry<T> {
    private var registry: [RegistryKey<T>: T] = [:]

    /// Registers a value at a given key. Overwrites any previous value stored at that key.
    /// - Parameters:
    ///   - value: The value to register.
    ///   - key: The key to register the value at.
    public func register(_ value: T, forKey key: RegistryKey<T>) {
        self.registry[key] = value
    }

    /// Gets the value at a given key.
    /// - Parameter key: The key to get the value at.
    /// - Returns: The value at the given key.
    public func get(_ key: RegistryKey<T>) -> T? {
        return self.registry[key]
    }

    /// Removes the value at a given key, if it exists.
    /// - Parameter key: The key to remove the value at.
    public func remove(at key: RegistryKey<T>) {
        guard let index = self.registry.index(forKey: key) else { return }
        self.registry.remove(at: index)
    }

    /// Adds all elements of other to self.
    /// - Parameter other: The other registry.
    public func mergeDown(with other: Registry<T>) {
        other.forEach { (key, value) in
            self.registry[key] = value
        }
    }

    /// Call body on every key-value pair in this registry.
    /// - Parameter body: The function to call on every key-value pair in this registry.
    public func forEach(_ body: ((key: RegistryKey<T>, value: T)) throws -> Void) rethrows {
        try self.registry.forEach(body)
    }

    /// Replace every value in each key-value pair in this registry with the output of calling body on it.
    /// - Parameter body: The function to call and get the new value from.
    public func map(_ body: ((key: RegistryKey<T>, value: T)) throws -> T) rethrows {
        self.registry = try self.registry.reduce(into: [:]) { partialResult, pair in
            partialResult[pair.key] = try body(pair)
        }
    }
}

/// A typed key for use in a registry.
public final class RegistryKey<T>: Hashable {
    public let name: String

    public init(referencing name: String) {
        self.name = name
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.name)
    }

    /// Utility function to explicitly convert this `RegistryKey`'s reference type.
    /// - Returns: A new `RegistryKey` with the same name but a different type.
    @inline(__always) public func convertType<Q>() -> RegistryKey<Q> {
        return RegistryKey<Q>(referencing: self.name)
    }

    public static func ==(first: RegistryKey<T>, second: RegistryKey<T>) -> Bool {
        return first.name == second.name
    }
}