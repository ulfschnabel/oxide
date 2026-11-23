/// The open remote sessions in the order they were opened, and which one is
/// shown. Swiping steps through them and wraps around.
public struct SessionRing<ID: Hashable & Sendable>: Sendable {
    public private(set) var ids: [ID] = []
    public private(set) var current: ID?
    /// The session in the second pane, when two are on screen.
    public private(set) var second: ID?

    public init() {}

    /// Shows `id`, adding it at the end if it isn't open yet. If it's the
    /// one in the second pane, the split ends.
    public mutating func open(_ id: ID) {
        if !ids.contains(id) { ids.append(id) }
        if second == id { second = nil }
        current = id
    }

    /// Shows the next session in a second pane; nil (no change) when there's
    /// no other one.
    @discardableResult
    public mutating func split() -> ID? {
        guard second == nil, let current, let i = ids.firstIndex(of: current), ids.count > 1 else { return second }
        second = ids[(i + 1) % ids.count]
        return second
    }

    public mutating func unsplit() {
        second = nil
    }

    /// Shows the session `offset` places on; nil (and no change) when there's
    /// nothing else to show.
    @discardableResult
    public mutating func step(_ offset: Int) -> ID? {
        step(offset, pane: 0)
    }

    /// Steps the session in one pane (0: the first, 1: the second), past the
    /// one shown in the other pane; nil (no change) when there's no other.
    @discardableResult
    public mutating func step(_ offset: Int, pane: Int) -> ID? {
        let from = pane == 0 ? current : second
        let other = pane == 0 ? second : current
        guard let from, let i = ids.firstIndex(of: from) else { return nil }
        var j = i
        for _ in 0..<ids.count {
            j = ((j + offset) % ids.count + ids.count) % ids.count
            let candidate = ids[j]
            guard candidate != from, candidate != other else { continue }
            if pane == 0 { current = candidate } else { second = candidate }
            return candidate
        }
        return nil
    }

    /// Removes `id`. If it was shown, the one after it is shown, or the one
    /// before when it was last.
    public mutating func close(_ id: ID) {
        guard let i = ids.firstIndex(of: id) else { return }
        ids.remove(at: i)
        // A pane closed: the other one's session is the one shown.
        if second == id {
            second = nil
            return
        }
        if current == id, let other = second {
            current = other
            second = nil
            return
        }
        guard current == id else { return }
        current = ids.isEmpty ? nil : ids[min(i, ids.count - 1)]
    }

    /// The shown session's place (from 0) among the open ones.
    public var position: (index: Int, count: Int)? {
        guard let current, let i = ids.firstIndex(of: current) else { return nil }
        return (i, ids.count)
    }
}
