/// A registry associates keys with values.
public final class Registry<T> {
    private var registry: [RegistryKey<T>: T] = [:]
    private var order: [RegistryKey<T>] = []

    /// Registers a value at a given key. Overwrites any previous value stored at that key.
    /// - Parameters:
    ///   - value: The value to register.
    ///   - key: The key to register the value at.
    public func register(_ value: T, forKey key: RegistryKey<T>) {
        if self.registry[key] == nil {
            self.order.append(key)
        }
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
        self.order.removeAll { $0 == key }
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
        for key in self.order {
            guard let value = self.registry[key] else {
                continue
            }
            try body((key: key, value: value))
        }
    }

    /// Replace every value in each key-value pair in this registry with the output of calling body on it.
    /// - Parameter body: The function to call and get the new value from.
    public func map(_ body: ((key: RegistryKey<T>, value: T)) throws -> T) rethrows {
        var mapped: [RegistryKey<T>: T] = [:]
        for key in self.order {
            guard let value = self.registry[key] else {
                continue
            }
            mapped[key] = try body((key: key, value: value))
        }
        self.registry = mapped
    }

    public func entries() -> [(key: RegistryKey<T>, value: T)] {
        self.order.compactMap { key in
            guard let value = self.registry[key] else {
                return nil
            }
            return (key: key, value: value)
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
