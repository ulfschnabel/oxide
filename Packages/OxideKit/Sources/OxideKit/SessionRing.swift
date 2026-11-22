/// The open remote sessions in the order they were opened, and which one is
/// shown. Swiping steps through them and wraps around.
public struct SessionRing<ID: Hashable & Sendable>: Sendable {
    public private(set) var ids: [ID] = []
    public private(set) var current: ID?

    public init() {}

    /// Shows `id`, adding it at the end if it isn't open yet.
    public mutating func open(_ id: ID) {
        if !ids.contains(id) { ids.append(id) }
        current = id
    }

    /// Shows the session `offset` places on; nil (and no change) when there's
    /// nothing else to show.
    @discardableResult
    public mutating func step(_ offset: Int) -> ID? {
        guard ids.count > 1, let current, let i = ids.firstIndex(of: current) else { return nil }
        let next = ids[((i + offset) % ids.count + ids.count) % ids.count]
        self.current = next
        return next
    }

    /// Removes `id`. If it was shown, the one after it is shown, or the one
    /// before when it was last.
    public mutating func close(_ id: ID) {
        guard let i = ids.firstIndex(of: id) else { return }
        ids.remove(at: i)
        guard current == id else { return }
        current = ids.isEmpty ? nil : ids[min(i, ids.count - 1)]
    }

    /// The shown session's place (from 0) among the open ones.
    public var position: (index: Int, count: Int)? {
        guard let current, let i = ids.firstIndex(of: current) else { return nil }
        return (i, ids.count)
    }
}
