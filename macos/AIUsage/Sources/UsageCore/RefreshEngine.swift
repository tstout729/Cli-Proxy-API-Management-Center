import Foundation

public actor RefreshEngine {
    private let configuration: ConnectionConfiguration
    private let client: ManagementClient
    private let keyLoader: @Sendable (String) throws -> String
    private var snapshot = RefreshSnapshot()
    private var inFlight: Task<RefreshSnapshot, Never>?

    public init(configuration: ConnectionConfiguration,
                transport: any ManagementTransport = URLSessionTransport(),
                keyLoader: @escaping @Sendable (String) throws -> String = { try ManagementKey.read(path: $0) }) {
        self.configuration = configuration
        client = ManagementClient(configuration: configuration, transport: transport)
        self.keyLoader = keyLoader
    }

    public func refresh(now: Date? = nil) async -> RefreshSnapshot {
        if let inFlight { return await inFlight.value }
        let previous = snapshot, client = self.client, configuration = self.configuration, keyLoader = self.keyLoader
        let task = Task { await Self.perform(previous: previous, client: client, configuration: configuration,
                                             keyLoader: keyLoader, now: now) }
        inFlight = task
        let result = await task.value
        snapshot = result
        inFlight = nil
        return result
    }

    private static func perform(previous: RefreshSnapshot, client: ManagementClient,
                                configuration: ConnectionConfiguration,
                                keyLoader: @Sendable (String) throws -> String, now: Date?) async -> RefreshSnapshot {
        let attemptedAt = now ?? Date()
        let key: String
        let inventory: [Credential]
        do {
            key = try keyLoader(configuration.keyPath)
            inventory = try await client.credentials(key: key)
        } catch {
            let failure = (error as? UsageFailure) ?? .connection
            var result = previous
            result.attemptedAt = attemptedAt
            result.connectionFailure = failure
            result.usageSuccesses = 0
            result.usageErrors = 0
            result.accounts = previous.accounts.map {
                AccountState(credential: $0.credential, reading: $0.reading, failure: failure)
            }
            return result
        }
        let inventoryUpdatedAt = now ?? Date()
        let old = Dictionary(uniqueKeysWithValues: previous.accounts.map { ($0.id, $0) })
        var accounts: [AccountState] = []
        var successes = 0, errors = 0
        // Three workers share a bounded queue via task-group completion. No per-account polling.
        await withTaskGroup(of: AccountState.self) { group in
            var pending = inventory.makeIterator()
            func enqueue(_ credential: Credential) {
                group.addTask {
                    if credential.disabled { return AccountState(credential: credential) }
                    do {
                        let reading = try await client.usage(for: credential, key: key, now: now)
                        return AccountState(credential: credential, reading: reading)
                    } catch {
                        return AccountState(credential: credential, reading: old[credential.id]?.reading,
                                            failure: (error as? UsageFailure) ?? .connection)
                    }
                }
            }
            for _ in 0..<3 { if let credential = pending.next() { enqueue(credential) } }
            while let account = await group.next() {
                accounts.append(account)
                if !account.credential.disabled {
                    if account.failure == nil { successes += 1 } else { errors += 1 }
                }
                if let credential = pending.next() { enqueue(credential) }
            }
        }
        accounts.sort {
            if $0.credential.provider != $1.credential.provider {
                return $0.credential.provider.rawValue < $1.credential.provider.rawValue
            }
            let order = $0.credential.label.localizedStandardCompare($1.credential.label)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        return RefreshSnapshot(accounts: accounts, attemptedAt: attemptedAt, inventoryUpdatedAt: inventoryUpdatedAt,
                               connectionFailure: accounts.compactMap(\.failure).first(where: \.isConnection),
                               usageSuccesses: successes, usageErrors: errors)
    }
}
