# Sift: design

A desktop database explorer built on MetalUI. 2026-11-18. The user opted out of further questions, so the calls marked **(call)** are the coordinator's.

## Intent

Two reasons, equal weight:

1. **The user's need.** The user stands Postgres databases up and tears them down in OrbStack, and also uses remote ones. Sift is for checking that what their code meant to write actually landed, in the right shape and in the right related rows, and for searching a database for data they need. It is mostly a read-and-inspect tool.
2. **Testing MetalUI for real.** Sift is a peer app, like Alloy, MetalFlow and MetalCreator, whose job is to find MetalUI's gaps and fix them in MetalUI. It pushes these areas:
   - a grid virtualised on both axes;
   - drawing large amounts of text;
   - editing inside recycled cells;
   - column drag and resize;
   - table accessibility;
   - daily use on Linux and Windows through the SDL backend.

## Goals for version 1

- **Connections**
  - Saved connections.
  - Postgres containers running in OrbStack or Docker, found automatically. Sift reads each one's image, published port and `POSTGRES_USER`, `POSTGRES_DB` and `POSTGRES_PASSWORD`.
  - Direct remote Postgres, with TLS or plain.
  - Reconnecting after a container is recreated is painless.
- **Schema browser:** schemas, tables, views, columns with their Postgres types, keys, indexes and row counts.
- **Grid:** a virtualised table of rows. Millions of rows and hundreds of columns scroll smoothly. Column headers stay put, and columns can be resized and reordered. Sort and filter on any column, and search the table.
  - Postgres types are shown properly:
    - `jsonb`, expandable;
    - arrays;
    - `uuid`;
    - `timestamptz` in the local time zone;
    - `numeric`;
    - enums;
    - `NULL` drawn distinctly from an empty value.
- **Checking what landed:**
  - newest rows first, ordered by a timestamp or serial column;
  - "what changed since I last looked": re-run the query and highlight the new or changed rows. Changes are rows whose `xmin` is newer than the marker taken at the last look; deleted rows are not shown;
  - foreign keys you can click to jump to the referenced row, and a back-link from a row to the rows that reference it.
- **Schema map** (requested by the user, 2026-11-18): a view that draws the database as a map, so the user can see it as a whole.
  - Each table is a node card showing its name, its key columns and its row count. Each foreign key is a link drawn from the referencing column to the referenced table.
  - The map is laid out automatically, **(call)** with a layered (Sugiyama-style) layout: referenced tables sit to the right of the tables that reference them, and crossings are reduced. Positions the user drags into place are remembered per database.
  - Pan and zoom, with a minimap. Search for a table and fly to it.
  - Hovering or selecting a table highlights its neighbours and links and dims the rest. Opening a table shows its rows in the grid. Clicking a link shows the column pair it joins.
  - Filter by schema. Show or hide views. Self-references and many-to-many join tables are drawn clearly.
  - It must stay smooth at about 500 tables and 1,000 links: culling and level of detail when zoomed out (at low zoom a card shows only its name).
  - **What it tests in MetalUI:** canvas drawing at scale, pan and zoom (the effect-replay path), dragging nodes (FP-U), hit-testing and accessibility of a graph, as MetalFlow's node canvas does. The MetalUI pieces MetalFlow already uses are reused; gaps are fixed in MetalUI.
- **SQL editor:** a `CodeView` with SQL highlighting, run with ⌘Return (Ctrl+Return off Apple platforms), results in the same grid, cancellable, and query history.
- **Read-only by default.** Editing is behind an explicit per-connection switch. Writes run in a transaction with a preview of the SQL.
- **Secondary sources:** SQLite files, and CSV for smaller data sets. Both open in the same grid with the same sort, filter and search. A query result can be exported as CSV.
- **Platforms:** macOS (AppKit and Metal) is the main one. Linux and Windows (SDL) are built and tested in CI from the start.

## Non-goals for version 1

- An SSH tunnel. **(call)** It comes in version 1.x, by running the system `ssh -L`.
- MySQL, SQL Server and other engines.
- Schema migrations, an editable ER designer and a visual query builder. The schema map is for viewing, not for editing the schema.
- Multi-user use, sync and accounts.

## Anti-goals

- Changing a database by accident. Read-only is the default, and destructive statements always ask first.
- Leaking secrets. A password never goes to logs or plain files. A container's password is shown as "from container env", masked. Keychain, Secret Service or Credential Manager is used only on explicit consent.
- Working around MetalUI. A missing framework piece is fixed in MetalUI under its own rules, never hacked around in Sift.

## Decided approach (from research, 2026-11-18)

| Area | Choice | Why |
|---|---|---|
| Postgres client | **libpq**, wrapped behind a small `SiftPG` protocol, with one serial queue per connection | PostgresNIO needs SwiftNIO, which does not build on Windows (2025–2026 forum status). libpq is the proven client: all auth methods, TLS, cancel, LISTEN. Packaging: Homebrew `libpq` on macOS (bundled into the .app later), `libpq-dev` on Linux, vcpkg on Windows with the DLLs next to the exe. The protocol keeps a later pure-Swift client possible. |
| Docker discovery | Sift's own small HTTP/1.1 client: a unix socket on macOS and Linux, a named pipe on Windows | URLSession cannot use unix sockets, and swift-nio's HTTP client does not build on Windows. Socket order: `DOCKER_HOST`, then the current docker context, then `~/.orbstack/run/docker.sock`, then `/var/run/docker.sock`, then rootless `$XDG_RUNTIME_DIR/docker.sock`. |
| SQLite | A bundled copy of the C source as `CSQLite`, following MetalUI's vendoring pattern (`VENDORED.md` and notices) | Identical on every platform. Windows has no system SQLite. |
| CSV | Sift's own RFC 4180 parser: a memory-mapped byte state machine, a record-offset index, sniffing of the delimiter and of types | Gives random access by row for the grid. |
| Grid | A new MetalUI **`Table`**, shaped like SwiftUI's (`Table`, `TableColumn`, `sortOrder`, selection), virtualised on rows **and columns**, with a sticky header and resizable columns | MetalUI has no `Table` and no grid virtualised on two axes. Lazy containers window only one axis. It is built in MetalUI under its own rules: a spec, decisions, divergences, inventory, tests and an Opus plan. |
| SQL highlighting | A hand-written SQL tokenizer feeding `CodeView`'s `CodeStyleRun`s | MetalUI has no SQL grammar, and a tokenizer is small. |

## Repository shape **(call)**

The layout follows Alloy:

- **`~/Developer/Sift`**, a public GitHub repo `mburger89/Sift`, MIT licence (Alloy and MetalFlow are public). Default branch `main`.
- **MetalUI dependency:** `Package.swift` depends on it by local path, `../MetalUI`, as Alloy does. `swift-tools-version` 6.1, macOS 14.
- **UI-free targets**, each with its own test target:
  - `SiftCore`: the data model for values, columns, result pages and the source protocol;
  - `SiftPG`: libpq;
  - `SiftSQLite`, with `CSQLite`;
  - `SiftCSV`;
  - `SiftDocker`.
- **`SiftKit`:** all the UI, tested with `MetalUITesting`.
- **`Sift`:** a thin executable.
- **`SiftTestSupport`:** fakes, plus a fixture Postgres.
- **CI** follows MetalUI's `swift.yml` (`xcode-27`, the Linux container, Windows x64), plus a Postgres service container on Linux for the `SiftPG` integration tests. Those tests skip when no server is reachable.

## Phases

Each phase is planned (Opus), built by Sonnet agents and merged when green.

0. **Spike: libpq on three platforms.** Connect to, query and decode a Postgres from a CLI target in CI on macOS, Linux and Windows. This settles libpq on Windows before anything depends on it. The fallback, if Windows fails, is to ship Windows later and keep the protocol.
1. **MetalUI `Table`.** A spec and Opus plan inside MetalUI, then the build. Rows and columns are windowed, with a sticky header, resizing, sort and selection, accessibility roles, and steady-frame cost tests.
2. **Sift skeleton.** The repo, the targets, the connections sidebar, Docker/OrbStack discovery and the schema browser. It can run with the stock `List` before the `Table` lands.
2b. **Schema map.** It needs only the schema metadata from phase 2: the layered layout, the card canvas with pan, zoom and minimap, neighbour highlighting, and opening a table from it. It can run in parallel with phase 1.
3. **Grid browsing.** `Table` over a paged result source, with type rendering, sort, filter and search. **Built** (PR "Phase 3: grid browsing"; plan `docs/superpowers/plans/2026-11-21-sift-phase3-grid.md`).
4. **SQL editor.** The tokenizer, run and cancel, history, and results. **Built** (PR "Phase 4: SQL editor"; plan `docs/superpowers/plans/2026-11-23-sift-phase4-sql-editor.md`).
5. **Checking what landed.** Newest-first, "changed since I last looked", and following foreign keys forward and back. **Built** (PR "Phase 5: checking what landed"; plan `docs/superpowers/plans/2026-11-23-sift-phase5-landed.md`).
6. **SQLite and CSV sources, and CSV export.**
7. **Edit mode, packaging** (a macOS .app, with Linux and Windows archives) and the SSH tunnel (1.x).

## Left to the builder

Visual design within MetalUI's defaults, the internal APIs, paging sizes and the exact interaction details. When a choice is between a SwiftUI-shaped and a custom approach, it follows MetalUI's rule: SwiftUI is the design authority.

## 11. MetalUI gaps (phases 3–5)

Phase 3 is the first consumer of `Table`, cell mode (`tableActiveCell`) and `copyable`. Each gap is filed as MetalUI work, under MetalUI's rules, and is never hacked around in Sift. Numbering continues the phase-2 plan's table (G1 to G12; G1 `SecureField`, G6 `Table` and G12 `textSelection` are answered by MetalUI at `dc52cd37`).

| # | Gap | Where it is hit | Blocking? | What Sift does meanwhile |
|---|---|---|---|---|
| G13 | **No tertiary label colour.** `Color` has `.primary` and `.secondary` only (divergence 116). A NULL, an empty-string marker and a loading placeholder want a third, fainter level. | `GridCell`, `ValueInspector` | No | **Answered** by MetalUI #406 (595c474a): `.foregroundStyle(.tertiary)` (CR-AE). Sift now uses it, and `GridPalette.tertiary` is gone. |
| G14 | **A write to an `@Observable` that only a memoized (`.equatable()`) component reads still rebuilds the plain components above it, once.** A page landing (`GridModel.pagesVersion`, read in `GridTable`'s body, which is `.equatable()`) rebuilds `RelationDetailView` and `GridView` once each, though neither reads the model. Measured with a `bodyCount` on each (a counting `RelationDetailView` showed +1 per page landing, with or without a read of the model inside the table's cell closures). The memoized children (toolbar, inspector, sidebar rows) are skipped, so the cost is the two thin parents. Repro: `GridCostTests/aPageArrivingRebuildsOnlyTheTable` with a `bodyCount` added to `RelationDetailView`. | `GridCostTests` | No | Recorded in MetalUI as divergence 243, with the engine fix deferred to IV-H. Sift keeps its `.equatable()` parents: every part of the grid is its own `.equatable()` component (equal while its `GridModel` is the same object), so a page rebuilds the table, and the status bar's loading text, and nothing else of weight. |
| G15 | **`CodeStyle` has no italic or weight.** A highlight style carries a foreground, a background and an underline, so a `CodeView` cannot draw comments in italic. The SQL editor's decision is "comments `.secondary` italic". Repro: `CodeStyle(foreground: .secondary)` is the whole of what a comment style can say (`CodeStyle` in `Sources/MetalUI/Code/CodeDecorations.swift`); a run of it draws upright. | `SQLTheme.comment`, `SQLHighlighterTests/keywordsStringsAndCommentsGetTheirStyles` | No | **Answered** by MetalUI #408 (CV-BY): `CodeStyle` has `italic` and `weight`, drawn with the font's real faces. `SQLTheme.style(for:)` gives comments `CodeStyle(foreground: .secondary, italic: true)`, in one place (`SQLTheme`); the colour is unchanged. |
| G16 | **`TestWindow.typeText` drops a newline.** `typeText("a\nb")` types `ab`: the `\n` is neither a character nor a Return key press, and nothing says so. Repro: a `CodeView` holding `""`, focused; `window.typeText("select 1;\nselect 2;")` leaves `select 1;select 2;` in the buffer. | `QueryViewTests` | No | **Answered** by MetalUI #407 (HT-AD): `typeText` delivers `\n`, `\r` and `\r\n` as one Return key press and `\t` as Tab. `QueryViewTests` types its two lines in one `typeText("...\n...")`. |
| G17 | **Windows test-worker threads have a 1 MB stack.** In a debug build, a large result builder held inline among its siblings (a 3-segment `Picker` inside `MapToolbar`'s `HStack`) gets a stack frame of about 1.2 MB and overflows it (`c00000fd`; MetalUI PE-K). | `DetailModePicker`, `MapToolbar` | No | **Answered** by MetalUI #409 (PE-AB): builders use a pack-based `TupleGroup`, so debug stack use grows linearly instead of with a `Pair` chain. PE-K still advises splitting very wide blocks into sub-Components (about 35 KiB per child in debug), so Sift keeps its splits (`DetailModePicker`, `MapToolbar`'s parts) and its shallow views, and adds no large inline builders. |
| G18 | **A `Component` has no `.accessibilityValue` modifier.** | `GridCell`, `GridCellText` | No | **Answered** by MetalUI #412 (AB-AH): `Component.accessibilityLabel` and `.accessibilityValue` return a layout-neutral `AccessibilityGroup`. `GridCell` puts the change mark's value on the `GridCellText` component, and the per-`Text` `shown` helper is gone. The labels, values and identifiers are unchanged. |
| G19 | **MetalUITesting cannot read an element's drawn text colour.** | Link-coloured FK cells (`GridCell`) | No | **Answered** by MetalUI #412 (HT-AE): `TestWindow.drawnTextColors(in:)` returns the colours an element's text drew in. `FollowTests/fkColumnsDrawInTheLinkColour` reads the drawn colour: an FK cell draws in `LinkAccent`, the others do not, and it fails when `GridTable.content` stops passing `linkColumns`. |
