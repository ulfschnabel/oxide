import Foundation

/// A display mode, width × height in pixels.
public struct Mode: Hashable, Sendable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }

    public init(_ r: Hbb_Resolution) {
        self.init(Int(r.width), Int(r.height))
    }

    /// A display's reported size as a mode. Mac hosts report backing pixels
    /// (`DisplayInfo.scale` 2) but list modes in points; Windows uses 1.
    public init(pixels width: Int, _ height: Int, scale: Double) {
        let s = scale > 0 ? scale : 1
        self.init(Int((Double(width) / s).rounded()), Int((Double(height) / s).rounded()))
    }

    var aspect: Double { Double(width) / Double(height) }
    var area: Double { Double(width) * Double(height) }
    public var description: String { "\(width)×\(height)" }
}

/// Which of the host's modes suits a screen best. The host switches only to
/// modes it lists (docs/protocol/resolution.md §2), so this picks from them.
public enum ResolutionPicker {
    /// How much a size mismatch counts against an aspect mismatch (both in
    /// log terms): a 2× larger area weighs like a ~19% wider aspect.
    static let sizeWeight = 0.25
    /// Modes whose shape is further off than this (~35%) aren't worth it.
    static let maxAspectError = 0.3

    /// When no mode has a similar shape, how much shape still counts
    /// against getting the scale right.
    static let letterboxAspectWeight = 0.25
    /// The smallest mode worth letterboxing into, if the host has one this
    /// big: Windows dialogs need about this much.
    static let usableMinimum = Mode(1024, 720)

    public static func best(from modes: [Mode], for target: Mode) -> Mode? {
        guard target.width > 0, target.height > 0 else { return nil }
        let valid = modes.filter { $0.width > 0 && $0.height > 0 }
        func aspectError(_ m: Mode) -> Double { abs(log(m.aspect) - log(target.aspect)) }
        func score(_ m: Mode) -> Double { aspectError(m) + sizeWeight * abs(log(m.area / target.area)) }
        let similar = valid.filter { aspectError($0) <= maxAspectError }
        if !similar.isEmpty {
            return similar.min { (score($0), -$0.area) < (score($1), -$1.area) }
        }
        return letterboxed(from: valid, for: target)
    }

    /// Nothing has the screen's shape (an upright phone against a host that
    /// only lists landscape modes): the picture will be letterboxed, so what
    /// matters is the scale it's shown at. Picks the mode whose fitted scale
    /// is closest to the target's, with a small preference for squarer modes
    /// (they fill more of an upright screen).
    static func letterboxed(from modes: [Mode], for target: Mode) -> Mode? {
        let usable = modes.filter { $0.width >= usableMinimum.width && $0.height >= usableMinimum.height }
        let pool = usable.isEmpty ? modes : usable
        func score(_ m: Mode) -> Double {
            // How much the mode is scaled to fit the target: 1 is just right.
            let fit = min(Double(target.width) / Double(m.width), Double(target.height) / Double(m.height))
            return abs(log(fit)) + letterboxAspectWeight * abs(log(m.aspect) - log(target.aspect))
        }
        return pool.min { (score($0), -$0.area) < (score($1), -$1.area) }
    }
}

/// Changing the host display's resolution to suit this screen, and back.
/// Changes are confirmed by the host reporting the new size; a request the
/// host ignores (it fails silently) times out and that mode isn't tried again.
public struct ResolutionController: Sendable {
    public static let confirmTimeout: TimeInterval = 3

    public private(set) var display: Int32 = 0
    public private(set) var current: Mode?
    public private(set) var original: Mode?
    public private(set) var modes: [Mode] = []
    public private(set) var pending: (mode: Mode, deadline: Date)?
    private var failed: Set<Mode> = []
    private var restoreRequested = false
    /// The target of the request in flight, and the last target the host
    /// answered with some other mode: not pushed again, so a host that
    /// reports sizes differently can't make this cycle through modes.
    private var requestedFor: Mode?
    private var settledFor: Mode?

    public init() {}

    /// What the host says about the display (login, or a SwitchDisplay).
    public mutating func update(display: Int32, current: Mode, original: Mode?, modes: [Mode]) {
        let previous = self.current
        // Failures belong to one display's mode list.
        if display != self.display || (!modes.isEmpty && modes != self.modes) { failed.removeAll() }
        // A mode the host is now in didn't fail, however late it was confirmed.
        failed.remove(current)
        self.display = display
        self.current = current
        if let original, original.width > 0 { self.original = original }
        if !modes.isEmpty { self.modes = modes }
        if let p = pending {
            if p.mode != current, current != previous {
                // The host switched, just not to what was asked.
                settledFor = requestedFor
            }
            if p.mode == current || current != previous { pending = nil }
        }
        if current != self.original { restoreRequested = false }
    }

    /// A request for the mode that suits `target` (this screen, in pixels),
    /// or nil when nothing should change.
    public mutating func target(_ target: Mode, now: Date) -> Hbb_Message? {
        tick(now: now)
        guard pending == nil, target != settledFor,
              let best = ResolutionPicker.best(from: modes.filter { !failed.contains($0) }, for: target),
              best != current
        else { return nil }
        pending = (best, now.addingTimeInterval(Self.confirmTimeout))
        requestedFor = target
        restoreRequested = false
        return request(best)
    }

    /// Gives up on a request the host hasn't confirmed in time.
    public mutating func tick(now: Date) {
        if let p = pending, now >= p.deadline {
            failed.insert(p.mode)
            pending = nil
        }
    }

    /// Back to the mode the display had before (when matching is turned
    /// off). The host also restores it by itself when the last session ends.
    public mutating func restore() -> Hbb_Message? {
        guard let original, original != current, !restoreRequested else { return nil }
        restoreRequested = true
        pending = nil
        settledFor = nil
        return request(original)
    }

    private func request(_ mode: Mode) -> Hbb_Message {
        var m = Hbb_Message()
        m.misc.changeDisplayResolution = .with {
            $0.display = display
            $0.resolution = .with {
                $0.width = Int32(mode.width)
                $0.height = Int32(mode.height)
            }
        }
        return m
    }
}
