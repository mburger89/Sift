# Sift

Sift: a desktop database explorer built on [MetalUI](https://github.com/mburger89/MetalUI) (work in progress).

It is for checking that what your code meant to write actually landed in a Postgres database, in the right shape and in the right related rows, and for searching a database for data you need. It is mostly a read-and-inspect tool. It is also a peer app that tests MetalUI on macOS, Linux and Windows.

Design: [docs/superpowers/specs/2026-11-18-sift-design.md](docs/superpowers/specs/2026-11-18-sift-design.md)

## Status: phase 0, libpq from Swift

`SiftPG` wraps libpq. `siftpg-probe` round-trips one row of every supported type against a real server, and CI runs it on macOS, Linux and Windows.

### Building

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

### Running

```sh
export SIFT_PG_URL=postgresql://postgres:sift@127.0.0.1:55432/postgres
swift run siftpg-probe     # exits 0 when every decoded value matches
swift test                 # the integration test is skipped when SIFT_PG_URL is unset
```
