# Sift

Sift: a desktop database explorer built on [MetalUI](https://github.com/mburger89/MetalUI) (work in progress).

It is for checking that what your code meant to write actually landed in a Postgres database, in the right shape and in the right related rows, and for searching a database for data you need. It is mostly a read-and-inspect tool. It is also a peer app that tests MetalUI on macOS, Linux and Windows.

Design: [docs/superpowers/specs/2026-11-18-sift-design.md](docs/superpowers/specs/2026-11-18-sift-design.md)

## Status: phase 5, checking what landed

Selecting a connected database opens its schema map (pan, zoom, a minimap, fly-to search, double-click to open a table) or a table in a paged grid, and the SQL editor runs and cancels queries with history. Phase 5 adds the checks for what your code wrote: a table opens newest-first when that is cheap, Refresh (Cmd/Ctrl-R) highlights the rows that changed since you last looked and Only changes narrows to them, a foreign key is followed with a double-click, Return, the inspector or the row menu, and Back and Forward (Cmd/Ctrl-[ and Cmd/Ctrl-]) retrace the jumps.

### Phase 0: libpq from Swift

`SiftPG` wraps libpq. `siftpg-probe` round-trips one row of every supported type against a real server, and CI runs it on macOS, Linux and Windows.

### Building

Sift builds against a sibling checkout of [MetalUI](https://github.com/mburger89/MetalUI): `Package.swift` depends on `../MetalUI` by path, so clone both into one folder (CI pins the MetalUI commit in `METALUI_REF` at the top of `.github/workflows/ci.yml`). On Linux and Windows MetalUI's `SDL` and `AccessKit` traits are on, so SDL3 and AccessKit's C bindings must be installed too (see below). `swift run Sift` opens the window.

libpq must be installed.

- **macOS:** `brew install libpq`. It is keg-only, so build with `PKG_CONFIG_PATH=$(brew --prefix libpq)/lib/pkgconfig swift build`. The phase-0 work installed it for testing; you may keep it or remove it with `brew uninstall libpq`.
- **Linux:** `apt install libpq-dev pkg-config`.
- **Windows:** there is no pkg-config, so pass the paths by hand. `Sources/CLibPQ` links `pq`, so the import library must be named `pq.lib`; copy `libpq.lib` to `pq.lib` in a directory of your own. With a PostgreSQL install (the EDB installer, or the copy preinstalled on GitHub's Windows runners) at `$pg`:

  ```powershell
  $stage = "C:\pqdev"
  New-Item -ItemType Directory -Force "$stage\include", "$stage\lib" | Out-Null
  Copy-Item "$pg\include\*" "$stage\include" -Recurse
  Copy-Item "$pg\lib\libpq.lib" "$stage\lib\pq.lib"
  $env:PATH = "$pg\bin;$env:PATH"      # libpq.dll and its OpenSSL DLLs, found at run time
  swift build -Xcc "-I$stage\include" -Xlinker "-L$stage\lib"
  swift test  -Xcc "-I$stage\include" -Xlinker "-L$stage\lib"
  ```

SDL3 and AccessKit (Linux and Windows only; macOS uses AppKit):

- **Linux:** build SDL 3.4.16 from source into `/usr` (Ubuntu 24.04 ships only SDL2), then `python3 ../MetalUI/Backends/SDL/scripts/fetch-accesskit.py --prefix /usr`.
- **Windows:** unpack `SDL3-devel-3.4.16-VC.zip`, put its `lib\x64` on `PATH`, and add `-Xcc -I<SDL3>\include -Xswiftc -L<SDL3>\lib\x64` plus the flags `python ..\MetalUI\Backends\SDL\scripts\fetch-accesskit.py --print-flags` prints (one per line) to every `swift` call, next to the libpq flags.
- **Headless:** `METALUI_SDL_HEADLESS=1` hides the window; the UI tests never need SDL, they run in a headless `TestWindow`.

### Running

```sh
export SIFT_PG_URL=postgresql://postgres:sift@127.0.0.1:55432/postgres
swift run siftpg-probe     # exits 0 when every decoded value matches
swift test                 # the integration test is skipped when SIFT_PG_URL is unset
```

### Linting

```sh
brew install swiftlint
swiftlint lint --strict    # CI runs the same command; every warning fails it
```

The rules and thresholds are in `.swiftlint.yml`; `Tests/.swiftlint.yml` loosens the size limits for tests. A suppression is a `// swiftlint:disable:next <rule> - <reason>` comment naming one rule and why.
