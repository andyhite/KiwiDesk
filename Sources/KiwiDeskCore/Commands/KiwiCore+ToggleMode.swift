import Foundation

extension KiwiCore {
    /// `toggle_mode(layout)`: the active Space stands on `layout`
    /// until the verb is called again, which restores the previous
    /// layout, order and sizing whole. No arrangement write records
    /// the temporary layout (`snapshotSpaces`).
    func toggleMode(_ args: [JSONValue]) -> CommandResponse {
        guard
            let raw = args.first?.stringValue,
            let layout = LayoutMode(rawValue: raw)
        else { return Self.toggleModeError }
        guard
            let id = state.workspaces.activeSpace,
            let space = state.workspaces[id]
        else { return .fail("no active space") }
        let before = space.mode
        let leaving =
            space.toggleBase.map {
                layout == space.mode || layout == $0.space.mode
            } ?? false
        // Ending first means temporary → temporary re-enters from
        // the base and never stacks toggles.
        state.workspaces.withSpace(id) { $0.endToggle() }
        if !leaving, let base = state.workspaces[id],
            base.mode != layout
        {
            setSpaceMode(id, layout)
            state.workspaces.withSpace(id) {
                $0.toggleBase = .space(base)
            }
        }
        retile(pass: .apply)
        guard let after = state.workspaces[id] else { return .ok() }
        emitLayoutChange(space: after)
        if after.mode != before { scheduleZOrderRestore() }
        return .ok()
    }

    private static let toggleModeError = CommandResponse.expected(
        LayoutMode.self
    )
}
