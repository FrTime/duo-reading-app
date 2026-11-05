import Foundation
import SwiftData

/// Version 1 of the library store.
///
/// Changing a model means adding `DuoReaderSchemaV2` with its own copies of the
/// models, moving the `Book` typealias to it, and adding a migration stage to
/// `DuoReaderMigrationPlan`. Never edit a shipped schema version in place.
public enum DuoReaderSchemaV1: VersionedSchema {
    public static let versionIdentifier = Schema.Version(1, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [Book.self]
    }
}

public enum DuoReaderMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [DuoReaderSchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}

public enum LibraryStore {
    /// The model container for the app. Pass `inMemory: true` in tests and previews.
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(versionedSchema: DuoReaderSchemaV1.self)
        let configuration = ModelConfiguration(
            "Library",
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: DuoReaderMigrationPlan.self,
            configurations: [configuration]
        )
    }
}
