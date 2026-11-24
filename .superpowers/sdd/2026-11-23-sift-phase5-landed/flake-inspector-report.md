# Flake: GridCostTests.aPageLandingElsewhereDoesNotRebuildTheInspectorOfALoadedCell

## Reproduction
- Single-test loop: 0 of 30 (too fast to hit). `--no-parallel --filter GridCostTests` loop: 1 of 25 uninstrumented, 4 of 30 and 1 of 40 with trace output on.
- Same failure: `InspectorBody.bodyCount == body` (4 vs 3).
- Second failure mode, found while measuring the fix: `runUntil` timed out after 10 s (about 2 of 80).

## Root cause
Not a leaked counter (a trace of the grid identity showed the rebuild is this test's own grid and cell). Not a missed setup frame either.
- `selectedRow`, `links` and `activePosition` did not change inside the window.
- The stack of the extra body shows it ran from `Component.requestGroupLayout`, that is a layout pass reaching the component, not a dirty invalidation.
- `InspectorBody` is a bare (non-Equatable) `Component`. MetalUI evaluates a bare component's `content` on every layout pass that reaches it. `ValueInspector` is equatable, but its memo only skips that component's own `content`. The children are still walked unless a retained graft record replays them.
- `METALUI_TRACE_RETAINED=1` shows that in the failing runs the first frame after `releaseAll()` (page lands, `pagesVersion` fires) is built with replay disallowed (`grafted=false`, `replayDisallowed`; the loading animation is running). That frame re-evaluates `InspectorBody`. Passing runs replay it. Whether replay is allowed in that frame depends on timing, hence the flake.
- This is a real cost bug (hypothesis 3, in a different form): the inspector rebuilt for a page landing elsewhere. The cause is the missing equatable memo, not a read of `isLoading` or the count.
- The second mode is test hygiene: `runUntil { cachedPages.count == 2 }` never holds when the far page and its neighbour land in one round (cachedPages jumps from 1 to 3).

## Fix
- `InspectorBody` is now `Equatable` (grid identity and position) and `ValueInspector` uses `.equatable()`. Its `content` re-runs only when the cell changes or an observed read fires (`selectedRow`, `links`, or `pagesVersion` while the value is still nil). The assertion is unchanged.
- In the test, `pageCalls.count == 2` and `cachedPages.count == 2` became `>= 2`. The assertion is not loosened.

## Rates
- Before: about 1 in 25 to 1 in 8 for the full-suite loop (the task reported about 1 in 4).
- After: 0 of 100 runs of `--no-parallel --filter GridCostTests`, none of them failing this test. (A first 80-run check with only the equatable fix showed 2 failures, both the `runUntil` timeout, none the body count; the `>=` change addressed those.)
- Full `swift test --no-parallel --filter SiftKitTests`: 298 tests passed.

## Predates Task 6
Yes. ValueInspector.swift and GridCostTests.swift are identical at bff9e74 and HEAD, and the test came with c5f87e4. At bff9e74 `InspectorBody` was already a bare Component (`git show bff9e74:Sources/SiftKit/Grid/ValueInspector.swift`, line 38).

## Not fixed (separate)
`aSiblingRedrawDoesNotRebuildAnUnfocusedGrid` flakes too (`tableRowsRealized` 26 instead of 0), seen in 3 of about 100 runs. That is the same family (a frame that cannot replay) and is not part of this commit.
