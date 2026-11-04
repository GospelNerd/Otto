# Otto agent working agreement

## Checkout ownership

- Use one active coding task per Git worktree and one unique `codex/...` branch.
- Treat the repository root on `main` as the integration checkout. Do not perform parallel feature work there.
- Before editing, run `pwd`, `git branch --show-current`, and `git status --short`.
- Do not create worktrees under `/tmp`, `.claude`, application caches, or a second workspace root. Use `scripts/otto-worktree create <task-name>` so durable agent worktrees live under the single sibling `Otto-worktrees/` directory. Worktrees created before the rename stay in the sibling `Muse-worktrees/` directory; `otto-worktree remove` still finds them. Never move an existing worktree.
- Never remove a worktree until its dirty state and commits have been audited.
- Use `scripts/otto-worktree remove <task-name>` for cleanup. It refuses dirty worktrees and archives the final commit before removal.

## SwiftPM

- Never invoke `swift build`, `swift test`, `swift run`, or `swift package` directly during agent work.
- Use `scripts/otto-swift <command> ...`. It assigns a cache and scratch directory unique to the current worktree, prevents concurrent use of that directory, applies a timeout, and cleans up the complete process group when cancelled.
- Normal builds and tests must use `Package.resolved` without remote updates. Use `scripts/otto-swift resolve` only as a deliberate integration task and commit any resulting `Package.resolved` change.
- Set `OTTO_SWIFT_TIMEOUT=0` only for an intentionally unbounded interactive run.
- If SwiftPM appears stuck, run `scripts/otto-swift-doctor`. Do not use broad commands such as `pkill swift` or `killall git`.
- The old `scripts/muse-swift`, `muse-worktree` and `muse-swift-doctor` names are thin wrappers kept for agents that still call them. The pre-rename `MUSE_SWIFT_*` variables are still read when the `OTTO_SWIFT_*` one is unset, and SwiftPM state stays in an existing `~/Library/Caches/Muse/SwiftPM` until the app migrates it to `~/Library/Caches/Otto/SwiftPM`.

## Handoff

- Commit completed work on the task branch and report the worktree path, branch, and commit SHA.
- Report uncommitted changes explicitly. Do not silently move or copy them between worktrees.
- Integrate task commits into `main` from the integration checkout using a reviewed merge or cherry-pick.

## Design

- Anything a person sees is designed before it is built. Read `DESIGN.md` (the design system) and
  follow the `otto-design` skill in `.agents/skills/otto-design/`: design in Paper on Otto's real
  frame and tokens, show Max on Shorelight, then write SwiftUI through `@Environment(\.ottoPalette)`.
- Project skills live in `.agents/skills/` and are linked from `.claude/skills/`. `frontend-design`
  applies to all UI; `components-build` and `superdesign` are for web surfaces only.
