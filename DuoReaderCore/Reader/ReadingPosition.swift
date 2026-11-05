import Foundation

extension Book {
    /// The imported file inside the library folder.
    public func fileURL(in booksFolder: URL) -> URL {
        booksFolder.appending(path: relativeFilePath, directoryHint: .notDirectory)
    }

    /// Records where the reader is, so the book reopens at the same place.
    ///
    /// - Parameters:
    ///   - locatorJSON: The reader's position, serialized as JSON.
    ///   - progression: How far through the whole book the position is, from
    ///     0 to 1. Values outside that range are clamped, and a missing or
    ///     non-finite value leaves `progress` unchanged.
    ///   - date: When the book was read.
    public func recordReadingPosition(locatorJSON: String, progression: Double?, at date: Date = .now) {
        readingLocator = locatorJSON
        if let progression, progression.isFinite {
            progress = min(max(progression, 0), 1)
        }
        lastOpened = date
    }
}

/// Coalesces rapid position updates (one per page turn) into occasional saves.
///
/// Page turns can arrive several times a second while someone flicks through a
/// book. Writing the store on every one is wasteful, so the reader records each
/// position on the model immediately and asks this to save at most once per
/// `interval`, plus once more when the reader closes or the app goes to the
/// background.
@MainActor
public final class SaveThrottle {
    private let interval: Duration
    private let clock: any Clock<Duration>
    private let save: @MainActor () -> Void
    private var pending: Task<Void, Never>?

    public init(interval: Duration = .seconds(2), clock: any Clock<Duration> = ContinuousClock(), save: @escaping @MainActor () -> Void) {
        self.interval = interval
        self.clock = clock
        self.save = save
    }

    /// Schedules a save unless one is already scheduled.
    public func request() {
        guard pending == nil else { return }
        pending = Task { [interval, clock] in
            try? await clock.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self.pending = nil
            self.save()
        }
    }

    /// Saves now and cancels any scheduled save.
    public func flush() {
        pending?.cancel()
        pending = nil
        save()
    }

    /// Whether a save is waiting to run.
    public var hasPendingSave: Bool { pending != nil }

    /// Waits for the scheduled save, if any, to run. For tests.
    func waitForPendingSave() async {
        await pending?.value
    }
}
