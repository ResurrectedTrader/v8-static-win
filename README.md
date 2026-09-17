# v8-static-win

Build V8 on Windows as a **monolithic static library** linked against the
**static CRT**, so it can be embedded in a DLL that carries no
`vcruntime140.dll` / `msvcp140.dll` dependency.

```powershell
.\build-v8.ps1 -Root C:\v8b -Version 14.8.180 -Arch x86 -Config Release
```

Output per configuration, under `dist-<arch>-<config>\`:

| File | Purpose |
|---|---|
| `v8_monolith.lib` | the engine, one archive |
| `include\` | V8's public headers |
| `README.txt` | the CRT and system libs a consumer needs |

Unlike SpiderMonkey, **no packaging step is needed** — `v8_monolithic = true`
emits a genuine self-contained archive.

## Version support

This is the part that matters most, because the version determines whether the
build is possible at all.

| V8 | 64-bit | 32-bit | Notes |
|---|---|---|---|
| ≤ 14.3.x | ✅ | ✅ | no patches needed |
| 14.4 – 14.8.x | ✅ | ✅ | needs the two source patches below |
| ≥ 14.9 | ✅ | ❌ | `ExtendedMap` breaks 32-bit (see below) |
| ≥ 15.x | ✅ | ❌ | also hardcodes a Windows SDK most machines do not have |

**Verified**: 14.8.180 x86 Release — 1,038 MB monolith, `libcmt`/`libcpmt`, zero
dynamic-CRT references.

### Why 32-bit stops at 14.8

On 2026-04-28, `067131a2` *"[maps] Support customizable map shapes"* (landed
during 14.9) introduced `ExtendedMap` as a `V8_ABSTRACT_OBJECT` — `pack(1)`,
deliberately no tail padding, with subclasses expected to occupy that space.
Torque models the derived class's first field at `sizeof(ExtendedMap)`; under
the MSVC ABI clang-cl places it elsewhere, so the generated assertions fail:

```
error: static assertion failed:
  Value of JSInterceptorMap::kFlagsOffset defined in Torque and offset of
  field JSInterceptorMap::flags in C++ do not match
```

`14.8.180` is the newest release before that change. Fixing it upstream looks
tractable — the trigger commit is known and the failure is deterministic — but
it has not been attempted here.

### Why ≥ 15.x needs an SDK you probably lack

V8 15.3 hardcodes `SDK_VERSION = '10.0.28000.0'` (in
`build/toolchain/win/setup_toolchain.py` and `build/vs_toolchain.py`) and sets
`NTDDI_VERSION=NTDDI_WIN11_BR`. On a machine with SDK 10.0.26100.0 the NTDDI
symbol is undefined, so it expands to `0` and **every** version gate in the SDK's
own headers closes, producing baffling errors like `fileapi.h` not knowing
`FILE_INFO_BY_HANDLE_CLASS`. 14.8.180 wants 10.0.26100.0 and `NTDDI_WIN11_GE`,
so it needs no such patching.

## The two source patches

Both exist because V8 is developed against libc++, while
`use_custom_libcxx = false` — required so the library interoperates with a
project built against MSVC's STL — gives it MSVC's. Both are in code upstream's
Windows bots evidently do not compile. The script applies them and reports if a
pattern is absent, so a future version that fixes them upstream is handled.

| File | Change | Why |
|---|---|---|
| `src/runtime/runtime-test.cc` | `std::atomic_flag f{false}` → `std::atomic_flag f` | `atomic_flag(bool)` is a libc++ extension; the standard and MSVC provide only a default constructor |
| `src/objects/backing-store.cc` | `gc_retry` parameter `const std::function<bool()>&` → `auto&&` | MSVC's `std::function` inherits `operator()` from `_Func_class`, so V8's `ExtractCallableRunTypeImpl<Callable::*>` trait never matches |

The second arrived with `RetryCustomAllocate` (2025-11-24, V8 14.4), so it
affects 14.4 onwards.

## Prerequisites

| Requirement | Notes |
|---|---|
| Visual Studio with ClangCL | V8 builds with clang-cl, not MSVC proper |
| Windows SDK | 10.0.26100.0 for 14.8.x; see the version table |
| Python 3, git | depot_tools needs both |
| ~25 GB disk | ~11 GB synced source, ~8 GB build output, ~1 GB library |

depot_tools is fetched into `-Root` by the script.

## Things that fail confusingly

* **Run it from a native Windows shell.** depot_tools' CIPD helper shells out to
  `cmd.exe`; under a cygwin `PATH` without `System32` it fails with
  `exec: "cmd.exe": executable file not found in %PATH%`.
* **`DEPOT_TOOLS_WIN_TOOLCHAIN=0` is mandatory** for non-Googlers, or it tries to
  fetch Google's internal packaged toolchain instead of your Visual Studio.
* **`DEPOT_TOOLS_UPDATE=0`** if depot_tools has local modifications — otherwise
  its self-update fails and blocks every command.
* **A version change needs a clean objdir.** `gn gen` happily reuses a populated
  one and the resulting errors point at V8's source rather than the stale output.
  The giveaway is hundreds of targets "building" in seconds. The script stamps
  the objdir with its version and wipes it on a mismatch.
* **`build/` is a separate repo** managed by gclient. Edits there survive a V8 tag
  checkout, are invisible to `git status` in `v8/`, and a dirty `build/` silently
  blocks `gclient sync` — leaving dependencies on the previous version's pins
  while everything *looks* fine. The script verifies `build/` against the DEPS pin
  after syncing.

## The build arguments

```gn
v8_monolithic = true
v8_static_library = true
is_component_build = false      # this is what selects /MT
v8_use_external_startup_data = false
use_custom_libcxx = false       # MSVC's STL, not the bundled libc++
v8_enable_pointer_compression   # true on x64, unsupported on x86
v8_enable_sandbox               # true on x64; needs the external code space,
                                # which needs pointer compression
v8_enable_i18n_support = false
v8_enable_webassembly = false
v8_enable_temporal_support = false
```

**`/MT` comes for free.** Chromium's `build/config/win/BUILD.gn` selects the CRT
from `is_component_build` — `false` gives `/MT` plus
`-Ctarget-feature=+crt-static` for the Rust components. `v8_monolithic` asserts
on the same flag, so a monolith is necessarily a static-CRT build.

**Temporal stays off** because `temporal_capi` is a Rust *static library*, and a
`v8_static_library` archives object files from source sets — not other static
libraries. With Temporal enabled the monolith references its symbols without
containing them, and the fix is to add it to the monolith's `deps`/`public_deps`
by hand. Leaving the flag off avoids the problem.

## Continuous integration

`.github/workflows/build.yml` is `workflow_dispatch` only. The output changes
only when the pinned V8 version does, so consumers download published assets
rather than building.

Disk is the constraint: ~11 GB of synced source plus ~8 GB of build output for
one x86 Release configuration, against roughly 33 GB free on a hosted runner. A
64-bit Debug build is close to twice the output and may not fit.
