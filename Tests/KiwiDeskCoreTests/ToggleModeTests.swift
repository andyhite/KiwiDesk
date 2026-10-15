import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import KiwiDeskCore

@Suite("Space toggle base")
struct SpaceToggleBaseTests {
    private let w1 = WindowID(1)
    private let w2 = WindowID(2)
    private let w3 = WindowID(3)

    private func base() -> Space {
        var space = Space(id: SpaceID("1"), mode: .track)
        space.windows = [w3, w1, w2]
        space.focused = w3
        space.stackWeights = [w1: 2]
        space.trackBreaks = [w2]
        space.sessionRatios.masterRatio = 0.3
        return space
    }

    private func toggled(_ base: Space) -> Space {
        var live = base
        live.mode = .monocle
        live.stackWeights = [:]
        live.trackBreaks = []
        live.sessionRatios = SessionRatios()
        live.toggleBase = .space(base)
        return live
    }

    @Test("ending restores the base layout and keeps the live focus")
    func restoresBase() {
        var live = toggled(base())
        live.focused = w1
        let ended = live.endingToggle()
        #expect(ended.mode == .track)
        #expect(ended.windows == [w3, w1, w2])
        #expect(ended.stackWeights == [w1: 2])
        #expect(ended.trackBreaks == [w2])
        #expect(ended.sessionRatios.masterRatio == 0.3)
        #expect(ended.focused == w1)
        #expect(ended.toggleBase == nil)
    }

    @Test("a departed member's break passes to its successor")
    func departedMemberLeavesThroughRemove() {
        var live = toggled(base())
        live.remove(w1)
        var expected = base()
        expected.remove(w1)
        let ended = live.endingToggle()
        #expect(ended.windows == [w3, w2])
        #expect(ended.trackBreaks == expected.trackBreaks)
    }

    @Test("a member that joined is appended last")
    func joinedMemberAppends() {
        var live = toggled(base())
        live.append(WindowID(9))
        #expect(live.endingToggle().windows == [w3, w1, w2, WindowID(9)])
    }

    @Test("baseMode names the layout a write would record")
    func baseModeFollowsToggle() {
        let live = toggled(base())
        #expect(live.mode == .monocle)
        #expect(live.baseMode == .track)
        #expect(live.endingToggle().baseMode == .track)
    }
}

@MainActor
private func makeCore() -> KiwiCore {
    let core = makeTestCore(
        configDirectory: FileManager.default
            .temporaryDirectory
            .appendingPathComponent("kiwi-toggle-\(UUID().uuidString)")
    )
    core.tiler.visibleBounds = { _ in
        CGRect(x: 0, y: 25, width: 1440, height: 875)
    }
    return core
}

@MainActor
private func makeSpace(_ core: KiwiCore) -> SpaceID {
    for id in 1...3 {
        core.state.apply(
            .windowCreated(
                ManagedWindow(
                    id: WindowID(UInt32(id)),
                    pid: pid_t(id),
                    appName: "App\(id)"
                )
            )
        )
    }
    let id = core.state.workspaces.space(of: WindowID(1))!
    core.state.workspaces.activate(id)
    core.state.workspaces.withSpace(id) {
        $0.windows = [WindowID(3), WindowID(1), WindowID(2)]
        $0.sessionRatios.splitRatioH = 0.3
    }
    return id
}

@Suite(
    "toggle_mode",
    .serialized,
    .enabled(if: NSScreen.main != nil)
)
@MainActor
struct ToggleModeTests {
    private func space(_ core: KiwiCore, _ id: SpaceID) -> Space {
        core.state.workspaces[id]!
    }

    @Test("a second call restores layout, order and sizing")
    func roundTrip() {
        let core = makeCore()
        let id = makeSpace(core)
        let start = space(core, id).mode
        #expect(
            core.execute("toggle_mode", args: [.string("monocle")]).isSuccess
        )
        #expect(space(core, id).mode == .monocle)
        #expect(space(core, id).toggleBase != nil)
        #expect(
            core.execute("toggle_mode", args: [.string("monocle")]).isSuccess
        )
        let back = space(core, id)
        #expect(back.mode == start)
        #expect(back.sessionRatios.splitRatioH == 0.3)
        #expect(back.windows == [WindowID(3), WindowID(1), WindowID(2)])
        #expect(back.toggleBase == nil)
    }

    @Test("temporary to temporary re-enters from the base")
    func temporaryToTemporary() {
        let core = makeCore()
        let id = makeSpace(core)
        let start = space(core, id).mode
        core.execute("toggle_mode", args: [.string("monocle")])
        core.execute("toggle_mode", args: [.string("stack")])
        #expect(space(core, id).mode == .stack)
        #expect(space(core, id).baseMode == start)
        core.execute("toggle_mode", args: [.string("stack")])
        let back = space(core, id)
        #expect(back.mode == start)
        #expect(back.sessionRatios.splitRatioH == 0.3)
    }

    @Test("toggling to the layout already shown changes nothing")
    func noOp() {
        let core = makeCore()
        let id = makeSpace(core)
        let mode = space(core, id).mode
        let response = core.execute(
            "toggle_mode",
            args: [.string(mode.rawValue)]
        )
        #expect(response.isSuccess)
        #expect(space(core, id).toggleBase == nil)
        #expect(space(core, id).mode == mode)
    }

    @Test("set_mode ends the toggle after restoring the base")
    func setModeEndsToggle() {
        let core = makeCore()
        let id = makeSpace(core)
        let start = space(core, id).mode
        core.execute("toggle_mode", args: [.string("monocle")])
        core.execute(
            "set_mode",
            args: [.string(id.raw), .string(start.rawValue)]
        )
        let after = space(core, id)
        #expect(after.toggleBase == nil)
        #expect(after.mode == start)
        #expect(after.sessionRatios.splitRatioH == 0.3)
    }

    @Test("arrangement writes and snapshots record the base layout")
    func writesRecordTheBase() {
        let core = makeCore()
        let id = makeSpace(core)
        let start = space(core, id).mode
        core.execute("toggle_mode", args: [.string("monocle")])
        #expect(core.snapshotSpaces.first { $0.id == id }?.mode == start)
        #expect(
            core.state.snapshot().spaces.first { $0.id == id.raw }?.mode
                == start
        )
    }

    @Test("a native-tab rekey during a toggle survives toggling back")
    func rekeyDuringToggle() {
        let core = makeCore()
        let id = makeSpace(core)
        core.state.workspaces.withSpace(id) {
            $0.stackWeights = [WindowID(1): 2]
            $0.trackWeights = [WindowID(1): 3]
            $0.trackBreaks = [WindowID(1)]
        }
        core.execute("toggle_mode", args: [.string("monocle")])
        core.state.workspaces.withSpace(id) {
            $0.rekey(WindowID(1), to: WindowID(9))
        }
        core.execute("toggle_mode", args: [.string("monocle")])
        let back = space(core, id)
        #expect(back.windows == [WindowID(3), WindowID(9), WindowID(2)])
        #expect(back.stackWeights == [WindowID(9): 2])
        #expect(back.trackWeights == [WindowID(9): 3])
        #expect(back.trackBreaks == [WindowID(9)])
        #expect(back.sessionRatios.splitRatioH == 0.3)
    }

    @Test("reset_layout_sizing clears the base sizing too")
    func resetReachesBase() {
        let core = makeCore()
        let id = makeSpace(core)
        core.state.workspaces.withSpace(id) {
            $0.stackWeights = [WindowID(1): 2]
            $0.trackWeights = [WindowID(1): 3]
        }
        core.execute("toggle_mode", args: [.string("monocle")])
        core.execute("reset_layout_sizing", args: [.string(id.raw)])
        core.execute("toggle_mode", args: [.string("monocle")])
        let back = space(core, id)
        #expect(back.sessionRatios == SessionRatios())
        #expect(back.stackWeights.isEmpty)
        #expect(back.trackWeights.isEmpty)
    }

    @Test("an explicit ratio clear is not undone by toggling back")
    func clearReachesBase() {
        let core = makeCore()
        let id = makeSpace(core)
        core.execute("toggle_mode", args: [.string("monocle")])
        core.clearSessionRatios { $0.splitRatioH = nil }
        core.execute("toggle_mode", args: [.string("monocle")])
        #expect(space(core, id).sessionRatios.splitRatioH == nil)
        // Seed anew: the per-space door alone must clear the base.
        core.state.workspaces.withSpace(id) {
            $0.sessionRatios.splitRatioH = 0.4
        }
        core.execute("toggle_mode", args: [.string("monocle")])
        core.clearSessionRatios(for: id) { $0.splitRatioH = nil }
        core.execute("toggle_mode", args: [.string("monocle")])
        #expect(space(core, id).sessionRatios.splitRatioH == nil)
    }

    @Test("a profile reload during a toggle cannot restore stale sizing")
    func profileReloadReachesBase() throws {
        let core = makeCore()
        let id = makeSpace(core)
        try core.profiles.save(
            Profile(
                name: "p",
                monitorSets: [MonitorSet(monitors: [])],
                spaceModes: [:],
                settings: TilingSettings()
            )
        )
        core.execute("load_profile", args: [.string("p")])
        core.state.workspaces.withSpace(id) {
            $0.sessionRatios.splitRatioH = 0.3
        }
        core.execute("toggle_mode", args: [.string("monocle")])
        core.execute("load_profile", args: [.string("p")])
        core.state.workspaces.withSpace(id) { $0.endToggle() }
        #expect(space(core, id).toggleBase == nil)
        #expect(space(core, id).sessionRatios.splitRatioH == nil)
    }

    @Test("entering monocle owes the focus raise")
    func monocleRaise() {
        let core = makeCore()
        _ = makeSpace(core)
        guard let screen = NSScreen.main else { return }
        core.tiler.animation.animate(
            window: WindowID(999),
            on: screen,
            from: CGRect(x: 0, y: 0, width: 100, height: 100),
            to: CGRect(x: 800, y: 0, width: 100, height: 100)
        )
        guard core.tiler.animation.activeCount > 0 else { return }
        core.execute("toggle_mode", args: [.string("monocle")])
        #expect(core.pendingZOrderRestore)
    }

    @Test("an unknown layout is refused")
    func badArgument() {
        let core = makeCore()
        _ = makeSpace(core)
        let response = core.execute("toggle_mode", args: [.string("nope")])
        #expect(!response.isSuccess)
    }
}
