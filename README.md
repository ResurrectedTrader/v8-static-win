# v8-static-win

Build V8 on Windows as a **monolithic static library** linked against the
**static CRT**, so it can be embedded in a DLL that carries no
`vcruntime140.dll` / `msvcp140.dll` dependency.

```powershell
.\build-v8.ps1 -Root C:\v8b -Version 14.8.180 -Arch x86 -Config Release -Verify
```

`-Arch` and `-Config` each also take `both`, building up to four configurations
in sequence into one root, sharing the checkout.

Output per configuration, under `dist-<arch>-<config>\`:

| File | Purpose |
|---|---|
| `v8_monolith.lib` | the engine, one archive |
| `include\` | V8's public headers, plus the generated `v8-gn.h` |
| `README.txt` | the defines, CRT and system libs a consumer needs |

Unlike SpiderMonkey, **no packaging step is needed** — `v8_monolithic = true`
emits a genuine self-contained archive.

`-Verify` compiles a small embedder against the result, links it into a DLL, and
evaluates JavaScript through it. CI always passes it.

## Consuming the result

Compile with **`/DV8_GN_HEADER`** and `include\` on the include path. Nothing
else is required.

That one define is load-bearing. V8's public headers are configured by macros
the GN build passes on the command line, and an embedder that does not repeat
them gets headers that lay objects out differently from the library it is
linking. `v8_generate_external_defines_header = true` makes the build emit
`include\v8-gn.h` carrying the exact set, and `v8config.h` includes it when
`V8_GN_HEADER` is defined — so the set travels with the library instead of
being reconstructed from the build arguments.

For the x86 Release configuration the defaults differ from the build in at
least three ways that a compiler cannot see:

| Macro | Header default | This build |
|---|---|---|
| `V8_ARRAY_BUFFER_INTERNAL_FIELD_COUNT` | `2` | `0` |
| `CPPGC_ENABLE_LARGER_CAGE` | off | on |
| `CPPGC_SLIM_WRITE_BARRIER` | off | on |

None of those produce a diagnostic. A spike that only evaluates an expression
links and runs fine without the define; the damage shows up later, in embedder
fields and in cppgc's inlined write barrier. `v8-gn.h` also `#error`s if you
define something the build disabled, so a contradiction fails at compile time
rather than at runtime.

`V8::Initialize()` separately checks pointer compression, Smi width and the
sandbox against the library and aborts on a mismatch — but that covers only
those three.

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
dynamic-CRT imports in a DLL linked against it, and `40 + 2 === 42` evaluated
through that DLL.

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
| ~10 GB disk | measured cold, one x86 Release: 4.9 GB checkout, 2.7 GB build output, 1.0 GB library, 0.7 GB depot_tools |
| ~11 min on 32 cores | cold, end to end; 7 of that is ninja. Budget an hour or two on 4 cores |

depot_tools is fetched into `-Root` by the script.

## Things that fail confusingly

* **Run it from a native Windows shell.** depot_tools' CIPD helper shells out to
  `cmd.exe`; under a cygwin `PATH` without `System32` it fails with
  `exec: "cmd.exe": executable file not found in %PATH%`.
* **`DEPOT_TOOLS_WIN_TOOLCHAIN=0` is mandatory** for non-Googlers, or it tries to
  fetch Google's internal packaged toolchain instead of your Visual Studio.
* **`DEPOT_TOOLS_UPDATE=0`** if depot_tools has local modifications — otherwise
  its self-update fails and blocks every command. But setting it on a *fresh*
  clone breaks the clone: a clone ships no Python, and the bootstrap that
  installs it only runs from `update_depot_tools.bat`, which that variable
  suppresses. `gclient` limps along, but `gn` and `autoninja` die with
  `python3_bin_reldir.txt not found. need to initialize depot_tools by running
  gclient or update_depot_tools`. The script runs `bootstrap\win_tools.bat`
  directly once, before setting the variable.
* **An existing depot_tools on `PATH` hijacks a second one.** `gclient.bat`
  *appends* its own directory to `PATH` and then calls `vpython3` unqualified,
  so a system-wide install runs this checkout's scripts under its interpreter —
  which surfaces as an unrelated `ImportError` from `metrics_utils`. The script
  prepends its own depot_tools to `PATH` for that reason.
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
v8_generate_external_defines_header = true   # emits include/v8-gn.h
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

## Verification

With `-Verify`, each configuration is checked once everything is packaged. The
workflow always passes it. For each one the script:

1. compiles a ~40-line embedder against `dist-<arch>-<config>\include` with
   `/DV8_GN_HEADER` and the matching CRT flag, using **V8's own bundled
   clang-cl** rather than Visual Studio's — the compiler that built the library
   cannot disagree with it about ABI;
2. links it into a DLL against `v8_monolith.lib` with `lld-link`;
3. walks the DLL's PE import table and fails if anything matching
   `vcruntime` / `msvcp` / `msvcr` / `api-ms-win-crt` appears. The table is
   parsed directly rather than through `dumpbin` or `llvm-readobj`, neither of
   which the build otherwise needs;
4. loads the DLL from a host process of the right bitness (a 32-bit DLL needs
   32-bit PowerShell) and calls into it, which initialises V8, creates an
   isolate and a context, and evaluates `40 + 2`.

Step 4 is the one that matters. An archive can be well-formed, correctly sized
and full of the right symbols while still being unable to initialise — the
CRT-directive check alone never catches that.

## Continuous integration

`.github/workflows/build.yml` is `workflow_dispatch` only. The output changes
only when the pinned V8 version does, so consumers download published assets
rather than building.

It takes a **version** and a **configurations** choice — one cell
(`x86-release`), a row or column (`x86`, `x64`, `release`, `debug`), or `all`.
A `plan` job expands that into a `strategy.matrix`, which cannot be done from a
`workflow_dispatch` input directly. Each configuration then gets its own runner:
`fail-fast: false`, because they are independent and an hour of work each.

Building them in one job instead is not an option — four in sequence would run
past GitHub's 360-minute job ceiling.

`plan` also validates the tag before a runner spends anything on a sync, and
**drops** the 32-bit cells when the version is past 14.8.x rather than letting
them fail mid-build, so `all` on a 15.x tag still builds its 64-bit half. If the
selection leaves nothing, it fails there with that as the reason.

Neither disk nor time is especially tight. A cold x86 Release run measures
**9.3 GB** all in against the ~33 GB free on a hosted runner, and **~11 minutes**
on 32 cores — 7 of which is ninja. A runner has 4 cores, so expect an hour or
two; `timeout-minutes` is set well above that rather than close to it, because
a timeout loses the whole run. A 64-bit Debug build is larger on both axes.

Most of the disk saving is the shallow clone: V8's full history is ~2 GB of
`.git` against 36 MB for a single tag.
