import Foundation

/// Decides which viewport sizes become remote window-change requests.
///
/// The first change after a flush is sent immediately. Later changes within
/// the same coalescing window replace one pending size. A flush sends only the
/// newest pending value and closes the window.
struct ResizeCoalescer: Sendable {
    struct Limits: Equatable, Sendable {
        let minimumColumns: Int
        let minimumRows: Int
        let maximumColumns: Int
        let maximumRows: Int

        static let standard = Limits(
            minimumColumns: 2,
            minimumRows: 1,
            maximumColumns: 500,
            maximumRows: 500
        )
    }

    struct Size: Equatable, Sendable {
        let columns: Int
        let rows: Int
    }

    struct Decision: Equatable, Sendable {
        let sendNow: Size?
        let pending: Size?
    }

    private(set) var pendingSize: Size?
    private let limits: Limits
    private var lastSent: Size?
    private var isCoalescing = false

    init(limits: Limits = .standard) {
        self.limits = limits
    }

    func normalized(columns rawColumns: Int, rows rawRows: Int) -> Size {
        Size(
            columns: max(limits.minimumColumns, min(limits.maximumColumns, rawColumns)),
            rows: max(limits.minimumRows, min(limits.maximumRows, rawRows))
        )
    }

    mutating func submit(columns rawColumns: Int, rows rawRows: Int) -> Decision? {
        let size = normalized(columns: rawColumns, rows: rawRows)

        guard size != pendingSize, size != lastSent else {
            return nil
        }

        if !isCoalescing {
            isCoalescing = true
            lastSent = size
            return Decision(sendNow: size, pending: nil)
        }

        pendingSize = size
        return Decision(sendNow: nil, pending: size)
    }

    /// Makes the next viewport measurement start a new coalescing window.
    mutating func clearLastSent() {
        lastSent = nil
        pendingSize = nil
        isCoalescing = false
    }

    /// Sends the newest deferred size, if any, and closes the window.
    mutating func flush() -> Size? {
        defer {
            pendingSize = nil
            isCoalescing = false
        }
        guard let pendingSize else {
            return nil
        }
        lastSent = pendingSize
        return pendingSize
    }

    var hasPending: Bool {
        pendingSize != nil
    }
}
