# v8-static-win

Build V8 on Windows as a **monolithic static library** linked against the
**static CRT**, so it can be embedded in a DLL that carries no
`vcruntime140.dll` / `msvcp140.dll` dependency.

```powershell
.\build-v8.ps1 -Root C:\v8b -Version 15.6.8 -Arch x86 -Config Release -Verify
```

`-Arch` and `-Config` each also take `both`, building up to four configurations
in sequence into one root, sharing the checkout.

Output per configuration, under `dist-<arch>-<config>\`:

| File | Purpose |
|---|---|
| `v8_monolith.lib` | the engine, one archive |
| `include\` | V8's public headers, plus the generated `v8-gn.h` |
| `README.txt` | the defines, CRT, system libs and toolset a consumer needs |
| `toolset.txt` | the MSVC toolset it was built with, machine-readable |

`v8_monolithic = true` emits a self-contained archive of V8's own objects.
Temporal is Rust, which that does **not** cover, so its archives are folded in
afterwards — see [Temporal](#temporal). The result is still one `.lib`.

`-Verify` compiles a small embedder against the result, links it into a DLL, and
evaluates both plain JavaScript and a Temporal computation through it. CI always
passes it. `-Temporal:$false` builds without Temporal.

## Consuming the result

Compile with **`/DV8_GN_HEADER`** and `include\` on the include path. Nothing
else is required, in either configuration.

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

### Debug keeps checked iterators

A Debug library is only useful if it links against Debug code built the ordinary
way, so this one keeps MSVC's `_ITERATOR_DEBUG_LEVEL=2`. Getting there took a
patch, because V8 sorts its ~864-entry flag table in a `constexpr` initialiser
and MSVC's `std::sort` adds a predicate-ordering check to every comparison when
checked iterators are on:

```
error: constexpr variable 'sorted_indices' must be initialized by a constant expression
note: constexpr evaluation hit maximum step limit; possible infinite loop?
      for (_BidIt _Prev = _Hole; _DEBUG_LT_PRED(_Pred, _Val, *--_Prev); ...)
```

Raising `-fconstexpr-steps` does not rescue it — 100,000,000 still fails, with
the flag verifiably on the command line. Replacing that one `std::sort` with a
hand-rolled heapsort does: same result, O(n log n) comparisons instead of
`std::sort`'s introsort plus the debug predicate, comfortably inside the budget.

Turning the checked iterators off would have been the smaller patch, but it sets
`_ITERATOR_DEBUG_LEVEL=0` for the whole binary — every other static library a
consumer links would have to be rebuilt to match, or the linker rejects it.

## Version support

Both architectures build on current V8. Two things stand between a stock
checkout and a working 32-bit library, and the script handles both:

| V8 | Needs | Handled by |
|---|---|---|
| 14.4 onwards | MSVC's `std::function` rejects V8's callable trait | a one-line source patch |
| 14.9 onwards | `ExtendedMap` assumes the Itanium ABI's packing rules | four small layout patches |
| 15.x onwards | a Windows SDK pin most machines cannot satisfy | retargeting at the installed SDK |

Older releases need fewer of these; a patch whose text is absent is reported and
skipped rather than failing, so the same script covers the range.

**Verified on 15.6.8**, the newest release at the time of writing, across all
four configurations — each one linked into a DLL with zero dynamic-CRT imports
and evaluated both plain JavaScript and a Temporal computation. 14.8.180 is
verified the same way.

### `ExtendedMap`, and why 32-bit used to stop at 14.8

During 14.9, `ExtendedMap` arrived as a `V8_ABSTRACT_OBJECT` — `#pragma pack(1)`
— ending in a `uint8_t` and carrying the comment *"Leaves kTaggedSize-1 unused
bytes, they will be used by subclasses."* That only works where `pack(1)` also
lowers the class's **alignment**, which the Itanium ABI does and the MSVC ABI
does not. So `sizeof(ExtendedMap)` is `sizeof(Map) + 1` under one and rounds up
to `sizeof(Map) + 4` under the other, and Torque's generated assertion fails:

```
gen/torque-generated/src/objects/map-tq.cc(102): static assertion failed
  static_assert(kSize == sizeof(ExtendedMap));
  note: expression evaluates to '41 == 44'
```

The fix is to stop relying on the trick: name those bytes as a padding field in
both `map.h` and `map.tq`, and shrink the one subclass's own padding to match.
The layout then comes out the same under either ABI. Exactly one class uses
`V8_ABSTRACT_OBJECT` and exactly one class derives from it, so it stays four
small edits.

### The Windows SDK pin

15.x hardcodes `SDK_VERSION = '10.0.28000.0'` (in `build/vs_toolchain.py` and
`build/toolchain/win/setup_toolchain.py`) and `NTDDI_VERSION=NTDDI_WIN11_BR`.
With an older SDK that does not fail cleanly: the NTDDI symbol is simply
undefined, expands to `0`, and **every** version gate in the SDK's own headers
closes — surfacing as things like `fileapi.h` not knowing
`FILE_INFO_BY_HANDLE_CLASS`.

The script finds the newest SDK actually installed and retargets both, picking
the NTDDI symbol by **value** rather than name (the two-letter suffixes — `ZN`,
`GA`, `GE`, `BR` — do not sort in release order). It leaves them alone when the
pinned SDK is present. These files live in `build/`, a separate gclient repo,
which is why the edits happen after the sync and are reverted before the next
one.

## The source patches

Most exist because V8 is developed against libc++ and its Windows bots evidently
do not compile this code, while `use_custom_libcxx = false` — required so the
library interoperates with a project built against MSVC's STL — gives it MSVC's.
Each is applied by exact text match; a version where the text is absent is
reported and skipped, so both older versions and ones upstream has since fixed
are handled without editing this list.

| File | Change | Why |
|---|---|---|
| `src/runtime/runtime-test.cc` | `std::atomic_flag f{false}` → `std::atomic_flag f` | `atomic_flag(bool)` is a libc++ extension; the standard and MSVC provide only a default constructor. **Fixed upstream by 15.6** |
| `src/objects/backing-store.cc` | `gc_retry` parameter `const std::function<bool()>&` → `auto&&` | MSVC's `std::function` inherits `operator()` from `_Func_class`, so V8's `ExtractCallableRunTypeImpl<Callable::*>` trait never matches. Arrived with `RetryCustomAllocate` in 14.4 |
| `src/objects/map.h` | reserve `extended_base_padding_[kTaggedSize - 1]` | gives `ExtendedMap` the same size under both ABIs — see above |
| `src/objects/map.tq` | declare the same padding | so Torque's `kSize` matches `sizeof` |
| `src/objects/js-interceptor-map.h` | `extended_padding_[kTaggedSize - 2]` → `[- 1]` | `ExtendedMap` no longer donates a byte, so its one subclass pads a byte further |
| `src/objects/js-interceptor-map.tq` | `extended_padding[2]`→`[3]`, `[6]`→`[7]` | the same, for both tagged-pointer sizes |
| `src/flags/flags.cc` | that one `std::sort` → a hand-rolled heapsort | lets Debug keep checked iterators — see above |

## Temporal

`Temporal` is implemented in Rust (`//third_party/rust/temporal_capi`), and that
is awkward for a single-archive build. `v8_static_library` sets gn's
`complete_static_lib`, which archives transitive **C++** objects but not Rust
rlibs — so the monolith references `temporal_rs_*` without containing it, and a
consumer gets about twenty undefined symbols at link time.

The build therefore folds the Rust graph into the archive after linking it:
every `.rlib` under the objdir plus the locally built Rust sysroot, ~50
archives. `lld-link` doubles as the librarian, so this needs no tool the build
did not already require, and the Rust toolchain itself comes from `gclient` —
Temporal adds no host prerequisite.

Two details cost time to find:

* **`clang_rt.builtins` has to go in too.** Rust's f16 helpers (`__extendhfsf2`,
  `__truncsfhf2`) live there and nothing else in the archive supplies them.
  Without it you are left with exactly those two undefined symbols.
* **`lld-link`'s `/lib` must be the literal first argument.** Inside a response
  file it is ignored with a warning, and the invocation silently becomes a link,
  which then fails for unrelated-looking reasons (`subsystem must be defined`).

It also drags in system libraries V8 alone never needed: Rust's standard library
reaches `ntdll` directly, so a consumer links `ntdll.lib`, `userenv.lib` and
`bcrypt.lib` on top of the usual set. Each archive's `README.txt` lists them.

Temporal is built in but still behind a runtime flag — enable it with
`--harmony-temporal`. `-Temporal:$false` turns the whole thing off, and then no
merge happens.

## Prerequisites

| Requirement | Notes |
|---|---|
| Visual Studio with ClangCL | V8 builds with clang-cl, not MSVC proper |
| Windows SDK | 10.0.26100.0 for 14.8.x; see the version table |
| Python 3, git | depot_tools needs both |
| ~12 GB disk | measured for one x86 Release with Temporal: 5.4 GB checkout, 4.8 GB build output, 1.2 GB library, 0.6 GB depot_tools. Debug is ~2 GB more |
| Time | ~11 min cold on 32 cores without Temporal; Temporal adds a Rust sysroot build. Budget an hour or two on 4 cores |

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
* **A library is only linkable by a toolchain at least as new as the one that
  built it.** MSVC's STL headers call helpers that live in its own
  `libcpmt.lib`, so a consumer on an older Visual Studio gets undefined symbols
  with no hint of the cause:

  ```
  lld-link: error: undefined symbol: ___std_max_element_8i@8
  ```

  This is why the workflow defaults to the **older** runner image. It is also
  the reason `use_custom_libcxx = false` is not the whole story: matching MSVC's
  STL is necessary, but a compatible *version* of it is what actually links.
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
v8_enable_sandbox = false       # unavailable here - see below
enable_iterator_debugging           # true in Debug, as MSVC defaults it
v8_enable_i18n_support = false
v8_enable_webassembly = false
v8_enable_temporal_support = true   # needs the Rust merge - see below
```

**The sandbox cannot be enabled**, on any architecture. `BUILD.gn` asserts it
needs libc++ hardening, and that is `use_safe_libcxx = use_custom_libcxx &&
enable_safe_libcxx` — so it requires V8's bundled libc++, which this build must
not use if the result is to link against a project compiled with MSVC's STL.
`gn gen` fails outright rather than degrading:

```
ERROR at //BUILD.gn:812:1: Assertion failed.
assert(!v8_enable_sandbox || use_safe_libcxx, "The sandbox requires libc++ hardening")
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
   isolate and a context, and evaluates two expressions: `40 + 2`, and a
   `Temporal.PlainDate` difference that must come out as 38 days.

Step 4 is the one that matters. An archive can be well-formed, correctly sized
and full of the right symbols while still being unable to initialise — the
CRT-directive check alone never catches that. The Temporal expression earns its
place separately: those symbols come from archives merged in after the fact, and
linking proves only that they exist, not that they run.

The spike sets no `_HAS_ITERATOR_DEBUGGING` of its own, so it is compiled the
way a consumer's code would be — a library built at a different
`_ITERATOR_DEBUG_LEVEL` fails this link rather than theirs.

## Continuous integration

`.github/workflows/build.yml` is `workflow_dispatch` only. The output changes
only when the pinned V8 version does, so consumers download published assets
rather than building.

It takes a **version**, a **configurations** choice — one cell
(`x86-release`), a row or column (`x86`, `x64`, `release`, `debug`), or `all` —
and a **runner**.
A `plan` job expands that into a `strategy.matrix`, which cannot be done from a
`workflow_dispatch` input directly. Each configuration then gets its own runner:
`fail-fast: false`, because they are independent and an hour of work each.

Building them in one job instead is not an option — four in sequence would run
past GitHub's 360-minute job ceiling.

`plan` also validates the tag before a runner spends anything on a multi-gigabyte
sync.

Published archives carry the toolset in the name —
`v8-15.6.8-x86-release-msvc14.44.zip` — so which one you can use is visible
before downloading a gigabyte. The name comes from the `toolset.txt` the build
writes, so it cannot drift from what actually compiled the library.

That version is a **floor, not a match**: 14.44 links on 14.44, 14.50 and newer.
Each MSVC release only adds `__std_*` helpers and never drops one — 14.29 defines
125, 14.44 defines 231, 14.50 defines 280 — so building low and consuming high
always works, and the reverse never does.

**The runner choice decides who can link the result.** It defaults to
`windows-2022` (Visual Studio 2022) rather than `windows-latest`, which is now
Visual Studio 2026: an artifact built there needs a consumer on a Visual Studio
at least as new, or the link fails on missing STL helpers. Building on the older
image costs nothing and widens who can use the output. `windows-latest` stays
selectable for when that stops being true.

**Re-running for a version already built replaces it.** Artifacts upload with
`overwrite: true`, and publishing edits the existing release's notes and
re-uploads its assets with `--clobber` instead of failing on the tag.

Neither disk nor time is especially tight. One x86 Release configuration
measures ~12 GB against the ~33 GB free on a hosted runner, and ~11 minutes on
32 cores before Temporal is counted. A runner has 4 cores, so expect an hour or
two; `timeout-minutes` is set well above that rather than close to it, because
a timeout loses the whole run. Debug is larger on both axes.

Most of the disk saving is the shallow clone: V8's full history is ~2 GB of
`.git` against 36 MB for a single tag.
