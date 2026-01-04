final class Registry<T> {
    private var registry: [RegistryKey<T>: T] = [:]

    func register(_ value: T, forKey key: RegistryKey<T>) {
        self.registry[key] = value
    }

    func get(_ key: RegistryKey<T>) -> T? {
        return self.registry[key]
    }
}

final class RegistryKey<T>: Hashable {
    let name: String

    init(referencing name: String) {
        self.name = name
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(self.name)
    }

    static func ==(first: RegistryKey<T>, second: RegistryKey<T>) -> Bool {
        return first.name == second.name
    }
}