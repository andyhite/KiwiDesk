extension Space {
    /// Boxes the whole pre-toggle Space (indirect: a Space cannot
    /// hold a Space inline). No field list to mirror.
    public indirect enum ToggleBase: Sendable, Equatable {
        case space(Space)

        public var space: Space {
            switch self {
            case .space(let s): return s
            }
        }
    }

    /// The layout an arrangement write records: the toggle base's
    /// mode while a toggle holds, else `mode`.
    public var baseMode: LayoutMode { toggleBase?.space.mode ?? mode }

    /// This Space with any toggle ended: the base's mode, order and
    /// sizing; members that left since are removed through
    /// `remove(_:)` (hands track breaks on); members that joined are
    /// appended in live order; the LIVE focus is kept.
    public func endingToggle() -> Space {
        guard let base = toggleBase?.space else { return self }
        var ended = base
        for gone in base.windows where !windows.contains(gone) {
            ended.remove(gone)
        }
        for joined in windows where !ended.windows.contains(joined) {
            ended.append(joined)
        }
        ended.focused = focused
        ended.toggleBase = nil
        return ended
    }

    public mutating func endToggle() { self = endingToggle() }

    /// Applies `edit` to the stored base too, so a write that must
    /// survive the toggle ending (rekey, sizing reset or clear) is
    /// not undone by the restore. No-op while no toggle holds.
    public mutating func editBase(_ edit: (inout Space) -> Void) {
        guard var base = toggleBase?.space else { return }
        edit(&base)
        toggleBase = .space(base)
    }
}
