<#
.SYNOPSIS
  Build V8 as a monolithic static library linked against the STATIC CRT (/MT),
  for embedding in an injected DLL.

.DESCRIPTION
  Bootstraps depot_tools, checks out a V8 tag, syncs its dependencies, and
  builds v8_monolith for the requested architectures and configurations. The
  monolith is already self-contained, so there is no packaging step - the
  library and headers are simply copied into dist-<arch>-<config>\.

.PARAMETER Root
  Working directory. Everything - depot_tools, the checkout, build output -
  lives here.

.PARAMETER Version
  V8 tag, e.g. 14.8.180. See NOTES on why this matters more than it looks.

.PARAMETER Arch
  x86, x64, or both.

.PARAMETER Config
  Release, Debug, or both.

.PARAMETER Verify
  After building, compile and link a small DLL against the result and run a
  script through it. x86 verification runs under 32-bit PowerShell.

.EXAMPLE
  .\build-v8.ps1 -Arch x86 -Config Release -Verify

.NOTES
  * 32-BIT IS CAPPED AT V8 14.8.x. On 2026-04-28 the commit "[maps] Support
    customizable map shapes" (067131a2, landed during 14.9) introduced
    ExtendedMap as a V8_ABSTRACT_OBJECT (pack(1), no tail padding) with
    subclasses expected to occupy that space. Under the MSVC ABI, Torque's
    `kFlagsOffset = sizeof(ExtendedMap)` model and clang-cl's actual layout
    disagree, so generated static assertions fail:
        Value of JSInterceptorMap::kFlagsOffset defined in Torque and offset
        of field JSInterceptorMap::flags in C++ do not match
    14.8.180 is the newest release before that change.

  * V8 15.3 also hardcodes Windows SDK 10.0.28000.0 and NTDDI_WIN11_BR, neither
    of which exists on a machine with SDK 10.0.26100.0. 14.8.180 wants
    10.0.26100.0 and NTDDI_WIN11_GE, so it needs no patching at all.

  * /MT COMES FOR FREE. Chromium's build/config/win/BUILD.gn selects the CRT
    from is_component_build - false gives "/MT" plus
    "-Ctarget-feature=+crt-static" for Rust. v8_monolithic asserts on the same
    flag, so a monolith is necessarily a static-CRT build.

  * MUST RUN FROM A NATIVE WINDOWS SHELL. depot_tools' CIPD helper shells out
    to cmd.exe; under a cygwin PATH without System32 it fails with
    'exec: "cmd.exe": executable file not found in %PATH%'.

  * A VERSION CHANGE NEEDS A CLEAN OBJDIR. `gn gen` reuses a populated one
    happily, and the resulting errors point at V8's source rather than at the
    stale output. The giveaway is hundreds of targets "building" in seconds.

  * build/ IS A SEPARATE REPO managed by gclient. Edits there survive a V8 tag
    checkout, are invisible to `git status` in v8/, and a dirty build/ silently
    blocks `gclient sync`.
#>

[CmdletBinding()]
param(
    [string]$Root    = "C:\v8b",
    [string]$Version = '14.8.180',
    [ValidateSet('x86', 'x64', 'both')]
    [string]$Arch    = 'x86',
    [ValidateSet('Release', 'Debug', 'both')]
    [string]$Config  = 'Release',
    [bool]$Temporal  = $true,
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

function Info { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Ok   { param($m) Write-Host "    $m" -ForegroundColor Green }
function Die  { param($m) Write-Host "ERROR: $m" -ForegroundColor Red; exit 1 }

# Native tools write progress to stderr; under $ErrorActionPreference='Stop'
# PowerShell turns that into a terminating error even on success.
function Invoke-Native {
    param([scriptblock]$Script, [string]$What, [switch]$AllowFailure)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Script } finally { $ErrorActionPreference = $prev }
    if (-not $AllowFailure -and $LASTEXITCODE -ne 0) { Die "$What failed (exit $LASTEXITCODE)" }
}

function Initialize-DepotTools {
    $dt = Join-Path $Root 'depot_tools'
    if (-not (Test-Path (Join-Path $dt 'gclient.bat'))) {
        Info 'fetching depot_tools'
        Invoke-Native {
            git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git $dt 2>&1 | Out-Null
        } 'depot_tools clone'
    }
    # Mandatory for non-Googlers: otherwise it tries to fetch Google's internal
    # packaged toolchain instead of using the local Visual Studio.
    $env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
    # Prepended, not appended: gclient.bat resolves `vpython3` off PATH, so a
    # depot_tools already installed system-wide would otherwise win and run this
    # checkout's scripts under its interpreter.
    $env:PATH = "$dt;$env:PATH"

    # A clone carries no Python. bootstrap\win_tools.bat installs the bundled
    # interpreter and writes python3_bin_reldir.txt, which gn.bat and
    # autoninja.bat both require - without it they fail with "python3_bin_reldir
    # .txt not found. need to initialize depot_tools by running gclient or
    # update_depot_tools". That bootstrap normally runs from
    # update_depot_tools.bat, which DEPOT_TOOLS_UPDATE=0 below suppresses, so
    # call it directly - it also avoids update_depot_tools.bat's pull to
    # origin/main, which a pinned checkout does not want.
    if (-not (Test-Path (Join-Path $dt 'python3_bin_reldir.txt'))) {
        Info 'bootstrapping depot_tools (downloads its bundled Python)'
        Invoke-Native {
            & (Join-Path $dt 'bootstrap\win_tools.bat') 2>&1 | Out-Null
        } 'depot_tools bootstrap'
        if (-not (Test-Path (Join-Path $dt 'python3_bin_reldir.txt'))) {
            Die 'depot_tools bootstrap produced no python3_bin_reldir.txt'
        }
    }

    # Its self-update fails if the tree has local modifications (symlink
    # typechanges are common on Windows) and then blocks every command.
    $env:DEPOT_TOOLS_UPDATE = '0'
    Ok "depot_tools: $dt"
    return $dt
}

function Initialize-Checkout {
    param($DepotTools)

    $src = Join-Path $Root 'v8'
    if (-not (Test-Path (Join-Path $Root '.gclient'))) {
        @'
solutions = [
  {
    "name": "v8",
    "url": "https://chromium.googlesource.com/v8/v8.git",
    "deps_file": "DEPS",
    "managed": False,
    "custom_deps": {},
  },
]
'@ | Set-Content -Encoding ascii (Join-Path $Root '.gclient')
    }

    if (-not (Test-Path (Join-Path $src '.git'))) {
        # Shallow, straight at the tag. V8's full history is ~2 GB and minutes of
        # transfer against 36 MB and seconds for the one commit, and nothing in
        # this build reads history - the dependencies are separate repos, synced
        # shallow in their own right by the gclient call below.
        Info "cloning v8 at $Version (shallow)"
        Invoke-Native {
            git clone --depth 1 --no-checkout --branch $Version `
                https://chromium.googlesource.com/v8/v8.git $src 2>&1 | Out-Null
        } 'v8 clone'
    }

    Push-Location $src
    try {
        # Keep a shallow clone shallow when switching versions - a bare `git
        # fetch` would back-fill the history the clone deliberately skipped -
        # but never make a full checkout shallow, in case -Root points at one.
        $depth = if (Test-Path '.git\shallow') { @('--depth', '1') } else { @() }
        Invoke-Native { git fetch @depth --no-tags origin tag $Version 2>&1 | Out-Null } "fetch tag $Version" -AllowFailure
        # A dirty build/ blocks gclient sync, so make sure dependencies are clean
        # before switching versions.
        if (Test-Path 'build\.git') {
            Push-Location build
            Invoke-Native { git checkout -- . 2>&1 | Out-Null } 'clean build/' -AllowFailure
            Pop-Location
        }
        # refs/tags/ spelled out: cloning with --branch <tag> also leaves a
        # local branch of the same name, so the bare name is ambiguous.
        Invoke-Native { git checkout -q "refs/tags/$Version" 2>&1 | Out-Null } "checkout $Version"
        Invoke-Native { $script:desc = @(git describe --tags 2>&1) } 'git describe' -AllowFailure
        Ok "v8 at $($script:desc[0])"
    } finally { Pop-Location }

    Info 'gclient sync (downloads dependencies)'
    Push-Location $Root
    try {
        Invoke-Native {
            & (Join-Path $DepotTools 'gclient.bat') sync -D --no-history --shallow 2>&1 |
                Select-String -Pattern 'error|Error|fatal' | Out-Null
        } 'gclient sync'
    } finally { Pop-Location }

    # Verify the dependency actually moved: a silent sync failure leaves build/
    # on the previous version's pin, and the build then fails confusingly.
    $pin = (Select-String -Path (Join-Path $src 'DEPS') -Pattern "build\.git'\s*\+\s*'@'\s*\+\s*'([0-9a-f]{40})'" |
            Select-Object -First 1).Matches.Groups[1].Value
    Push-Location (Join-Path $src 'build')
    Invoke-Native { $script:at = @(git rev-parse HEAD 2>&1) } 'build rev-parse' -AllowFailure
    Pop-Location
    if ($pin -and $script:at[0] -ne $pin) {
        Die "build/ is at $($script:at[0]) but DEPS pins $pin - the sync did not complete."
    }
    Ok "dependencies synced (build/ at $($pin.Substring(0,10)))"
    return $src
}

function Invoke-SourcePatches {
    param($Src)

    # V8 is developed against libc++. `use_custom_libcxx = false` - required so
    # the library interoperates with a project built against MSVC's STL - exposes
    # two places where V8 relies on libc++ behaviour. Both are in code that
    # upstream's Windows bots evidently do not compile.
    $patches = @(
        @{
            File = 'src/runtime/runtime-test.cc'
            Old  = 'static std::atomic_flag printed_warning{false};'
            New  = 'static std::atomic_flag printed_warning;'
            Why  = 'atomic_flag(bool) is a libc++ extension; the standard (and MSVC) provide only a default ctor'
        },
        @{
            File = 'src/objects/backing-store.cc'
            Old  = 'auto gc_retry = [&](const std::function<bool()>& fn) {'
            New  = 'auto gc_retry = [&](auto&& fn) {'
            Why  = "MSVC's std::function inherits operator() from _Func_class, so V8's ExtractCallableRunTypeImpl<Callable::*> trait never matches"
        },

        # ExtendedMap (15.x) ends in a uint8 under #pragma pack(1) and leaves the
        # rest of the tagged word as tail padding for its subclass to occupy.
        # That only works under the Itanium ABI, where pack(1) also lowers the
        # class's alignment: there sizeof(ExtendedMap) is 40+1, while under the
        # MSVC ABI the base keeps alignment 4 and it rounds to 44, so Torque's
        # generated `static_assert(kSize == sizeof(ExtendedMap))` fails 41 == 44.
        # Naming the bytes instead of leaving them as padding makes the layout
        # identical under both ABIs; the single subclass then starts one word
        # later and its own padding shrinks to match.
        @{
            File = 'src/objects/map.h'
            Old  = '  // Leaves kTaggedSize-1 unused bytes, they will be used by subclasses.'
            New  = "  // Reserved rather than left as tail padding for subclasses: the MSVC ABI`n  // does not lower a base class's alignment for #pragma pack, so the implicit`n  // version of these bytes makes sizeof disagree with Torque's kSize.`n  uint8_t extended_base_padding_[kTaggedSize - 1];"
            Why  = 'gives ExtendedMap the same size under the MSVC and Itanium ABIs'
        },
        @{
            File = 'src/objects/map.tq'
            Old  = '  // Leaves kTaggedSize-1 unused bytes, they will be used by subclasses.'
            New  = "  @ifnot(TAGGED_SIZE_8_BYTES) extended_base_padding[3]: uint8;`n  @if(TAGGED_SIZE_8_BYTES) extended_base_padding[7]: uint8;"
            Why  = "teaches Torque about the bytes map.h now reserves, so kSize matches sizeof"
        },
        @{
            File = 'src/objects/js-interceptor-map.h'
            Old  = '  uint8_t extended_padding_[kTaggedSize - 2];'
            New  = '  uint8_t extended_padding_[kTaggedSize - 1];'
            Why  = 'ExtendedMap no longer donates a byte, so the subclass pads a byte further'
        },
        @{
            File = 'src/objects/js-interceptor-map.tq'
            Old  = '  @ifnot(TAGGED_SIZE_8_BYTES) extended_padding[2]: uint8;'
            New  = '  @ifnot(TAGGED_SIZE_8_BYTES) extended_padding[3]: uint8;'
            Why  = 'matches the widened padding in js-interceptor-map.h (4-byte tagged)'
        },
        @{
            File = 'src/objects/js-interceptor-map.tq'
            Old  = '  @if(TAGGED_SIZE_8_BYTES) extended_padding[6]: uint8;'
            New  = '  @if(TAGGED_SIZE_8_BYTES) extended_padding[7]: uint8;'
            Why  = 'matches the widened padding in js-interceptor-map.h (8-byte tagged)'
        },

        # V8 sorts its flag table (~864 entries) in a constexpr initialiser. With
        # iterator debugging on, MSVC's std::sort adds a predicate-ordering check
        # to every comparison and the initialiser overruns clang's constexpr
        # budget - raising -fconstexpr-steps does not rescue it. A hand-rolled
        # heapsort keeps the same result at a fraction of the steps, which is
        # what lets Debug keep _ITERATOR_DEBUG_LEVEL at its default. The two
        # entries differ only in how the version spells the comparison.
        @{
            File = 'src/flags/flags.cc'
            Old  = "  std::sort(indices.begin(), indices.end(), [](int i, int j) {`n    return FlagHelpers::FlagNamesCmp(kFlagsMetadata[i].name,`n                                     kFlagsMetadata[j].name) < 0;`n  });"
            New  = "  auto less = [](int i, int j) {`n    return FlagHelpers::FlagNamesCmp(kFlagsMetadata[i].name,`n                                     kFlagsMetadata[j].name) < 0;`n  };`n  auto sift = [&](size_t root, size_t count) {`n    for (size_t child = (2 * root) + 1; child < count; child = (2 * root) + 1) {`n      if (child + 1 < count && less(indices[child], indices[child + 1])) ++child;`n      if (!less(indices[root], indices[child])) return;`n      const int tmp = indices[root];`n      indices[root] = indices[child];`n      indices[child] = tmp;`n      root = child;`n    }`n  };`n  for (size_t i = kNumAllFlags / 2; i-- > 0;) sift(i, kNumAllFlags);`n  for (size_t end = kNumAllFlags; end-- > 1;) {`n    const int tmp = indices[0];`n    indices[0] = indices[end];`n    indices[end] = tmp;`n    sift(0, end);`n  }"
            Why  = 'sorts the flag table within the constexpr budget, so Debug keeps checked iterators'
        },
        @{
            File = 'src/flags/flags.cc'
            Old  = "  std::sort(indices.begin(), indices.end(), [&](int i, int j) {`n    return FlagHelpers::FlagNamesCmp(kFlagNames[i], kFlagNames[j]) < 0;`n  });"
            New  = "  auto less = [&](int i, int j) {`n    return FlagHelpers::FlagNamesCmp(kFlagNames[i], kFlagNames[j]) < 0;`n  };`n  auto sift = [&](size_t root, size_t count) {`n    for (size_t child = (2 * root) + 1; child < count; child = (2 * root) + 1) {`n      if (child + 1 < count && less(indices[child], indices[child + 1])) ++child;`n      if (!less(indices[root], indices[child])) return;`n      const int tmp = indices[root];`n      indices[root] = indices[child];`n      indices[child] = tmp;`n      root = child;`n    }`n  };`n  for (size_t i = kNumFlags / 2; i-- > 0;) sift(i, kNumFlags);`n  for (size_t end = kNumFlags; end-- > 1;) {`n    const int tmp = indices[0];`n    indices[0] = indices[end];`n    indices[end] = tmp;`n    sift(0, end);`n  }"
            Why  = 'the same, for versions that index a flat kFlagNames table'
        }
    )

    $applied = 0
    foreach ($p in $patches) {
        $path = Join-Path $Src $p.File
        if (-not (Test-Path $path)) { continue }          # not present in this version
        $text = Get-Content $path -Raw
        if ($text.Contains($p.New) -and -not $text.Contains($p.Old)) { continue }   # already patched
        if (-not $text.Contains($p.Old)) {
            # Either the version predates the code being patched, or upstream
            # has since fixed it. Both are fine; only a half-applied patch
            # would not be, and that cannot happen from here.
            Ok "  skipped $($p.File) - nothing matching in this version"
            continue
        }
        $text.Replace($p.Old, $p.New) | Set-Content -Encoding ascii -NoNewline $path
        Ok "  patched $($p.File) - $($p.Why)"
        $applied++
    }
    if ($applied) { Info "applied $applied source patch(es)" } else { Ok 'no source patches needed' }
}

# The newest Windows SDK actually installed, and the highest NTDDI_WIN11_*
# symbol its headers define. Picked by value rather than by name, because the
# two-letter suffixes (ZN, GA, GE, BR ...) do not sort in release order.
function Get-WindowsSdk {
    $root = @(
        (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SDKs\Windows\v10.0' -ErrorAction SilentlyContinue).InstallationFolder
        (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SDKs\Windows\v10.0' -ErrorAction SilentlyContinue).InstallationFolder
        "${env:ProgramFiles(x86)}\Windows Kits\10\"
    ) | Where-Object { $_ -and (Test-Path (Join-Path $_ 'Include')) } | Select-Object -First 1
    if (-not $root) { return $null }

    $ver = Get-ChildItem (Join-Path $root 'Include') -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match '^10\.\d+\.\d+\.\d+$' -and
                          (Test-Path (Join-Path $_.FullName 'shared\sdkddkver.h')) } |
           Sort-Object { [version]$_.Name } | Select-Object -Last 1
    if (-not $ver) { return $null }

    $best = $null; $bestValue = 0
    Select-String -Path (Join-Path $ver.FullName 'shared\sdkddkver.h') `
                  -Pattern '^#define\s+(NTDDI_WIN11_\w+)\s+(0x[0-9A-Fa-f]+)' |
        ForEach-Object {
            $g = $_.Matches[0].Groups
            $value = [Convert]::ToUInt32($g[2].Value, 16)
            if ($value -gt $bestValue) { $bestValue = $value; $best = $g[1].Value }
        }
    [pscustomobject]@{ Root = $root; Version = $ver.Name; Ntddi = $best }
}

# The MSVC toolset the build will use, which is the one thing a consumer has to
# match: its STL headers call helpers that live in its own libcpmt.lib, so
# linking against this library needs that toolset or newer. Identified by
# toolset version rather than by Visual Studio year, because the two do not
# correspond - 14.44 ships under both 2022 and 2026.
function Get-MsvcToolset {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) { return $null }

    Invoke-Native { $script:vsPath = @(& $vswhere -latest -property installationPath 2>&1) } 'vswhere' -AllowFailure
    Invoke-Native { $script:vsName = @(& $vswhere -latest -property displayName 2>&1) } 'vswhere' -AllowFailure
    $root = $script:vsPath | Where-Object { $_ } | Select-Object -First 1
    if (-not $root) { return $null }

    # V8's own toolchain resolution picks the newest toolset, so match that.
    $toolset = Get-ChildItem (Join-Path $root 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue |
               Sort-Object { [version]$_.Name } | Select-Object -Last 1
    if (-not $toolset) { return $null }

    $parts = $toolset.Name.Split('.')
    [pscustomobject]@{
        Version = $toolset.Name
        Short   = "$($parts[0]).$($parts[1])"
        Display = ($script:vsName | Where-Object { $_ } | Select-Object -First 1)
    }
}

# V8 15.x pins a Windows SDK version and an NTDDI symbol that ships with it. On
# a machine with an older SDK the pin does not fail cleanly: the NTDDI symbol is
# simply undefined, so it expands to 0, every version gate in the SDK's own
# headers closes, and the build dies somewhere unrelated - fileapi.h not knowing
# FILE_INFO_BY_HANDLE_CLASS, say. Retarget both at whatever is installed.
#
# These files live in build/, a separate gclient-managed repo. That is why the
# edits are made after the sync, and why Initialize-Checkout reverts build/
# before the next one.
function Invoke-ToolchainPatches {
    param($Src)

    $sdk = Get-WindowsSdk
    if (-not $sdk) { Die 'no Windows 10/11 SDK found - install one via the Visual Studio installer' }

    $changed = @()
    foreach ($rel in 'build\vs_toolchain.py', 'build\toolchain\win\setup_toolchain.py') {
        $path = Join-Path $Src $rel
        if (-not (Test-Path $path)) { continue }
        $text = Get-Content $path -Raw
        if ($text -notmatch "SDK_VERSION\s*=\s*'([\d.]+)'") { continue }
        $want = $Matches[1]
        if ($want -eq $sdk.Version) { continue }
        if (Test-Path (Join-Path $sdk.Root "Include\$want")) { continue }   # pinned one is present after all
        ($text -replace "SDK_VERSION\s*=\s*'[\d.]+'", "SDK_VERSION = '$($sdk.Version)'") |
            Set-Content -Encoding ascii -NoNewline $path
        $changed += "$rel : $want -> $($sdk.Version)"
    }

    $path = Join-Path $Src 'build\config\win\BUILD.gn'
    if (Test-Path $path) {
        $text = Get-Content $path -Raw
        if ($text -match 'NTDDI_VERSION=(NTDDI_\w+)') {
            $want = $Matches[1]
            $header = Join-Path $sdk.Root "Include\$($sdk.Version)\shared\sdkddkver.h"
            if (-not (Select-String -Path $header -Pattern "define\s+$want\b" -Quiet)) {
                if (-not $sdk.Ntddi) { Die "the installed SDK defines no NTDDI_WIN11_* symbol to replace $want with" }
                $text.Replace("NTDDI_VERSION=$want", "NTDDI_VERSION=$($sdk.Ntddi)") |
                    Set-Content -Encoding ascii -NoNewline $path
                $changed += "build\config\win\BUILD.gn : $want -> $($sdk.Ntddi)"
            }
        }
    }

    if ($changed) {
        Info "retargeted the build at the installed SDK $($sdk.Version)"
        $changed | ForEach-Object { Ok "  $_" }
    } else {
        Ok "toolchain already matches the installed SDK ($($sdk.Version))"
    }
}

function New-Args {
    param($Arch, $Config)
    $is64 = $Arch -eq 'x64'
    @"
is_debug = $(if ($Config -eq 'Debug') { 'true' } else { 'false' })
target_cpu = "$Arch"
v8_target_cpu = "$Arch"
is_clang = true

# Monolithic static library. is_component_build=false is also what selects /MT
# (build/config/win/BUILD.gn); v8_monolithic asserts on it.
v8_monolithic = true
v8_static_library = true
is_component_build = false
v8_use_external_startup_data = false

# Emit include/v8-gn.h, so a consumer reproduces this build's define set with a
# single -DV8_GN_HEADER instead of replicating a dozen macros by hand. Several
# of them (the *_INTERNAL_FIELD_COUNT values, V8_COMPRESS_POINTERS,
# V8_ENABLE_SANDBOX) change public object layout, so getting them wrong is a
# silent ABI mismatch. The generated header #errors on a contradiction, and
# V8::Initialize() re-checks the layout-affecting ones at runtime.
v8_generate_external_defines_header = true

# MSVC's STL rather than the bundled libc++.
use_custom_libcxx = false
use_custom_libcxx_for_host = false

# Pointer compression is unsupported on x86.
v8_enable_pointer_compression = $(if ($is64) { 'true' } else { 'false' })

# The sandbox is unavailable here on every architecture, not just x86. BUILD.gn
# asserts it needs libc++ hardening, and that is
# use_safe_libcxx = use_custom_libcxx && enable_safe_libcxx - so it cannot be
# had without V8's bundled libc++, which this build must not use if the result
# is to interoperate with a project compiled against MSVC's STL.
v8_enable_sandbox = false

v8_enable_backtrace = $(if ($Config -eq 'Debug') { 'true' } else { 'false' })
v8_enable_slow_dchecks = $(if ($Config -eq 'Debug') { 'true' } else { 'false' })
v8_optimized_debug = $(if ($Config -eq 'Debug') { 'true' } else { 'false' })
# Left at the MSVC default, so a Debug library matches what everything else in a
# Debug build is compiled with and needs no _HAS_ITERATOR_DEBUGGING on the
# consumer side. The flag-table sort that this would otherwise break is patched
# in Invoke-SourcePatches.
enable_iterator_debugging = $(if ($Config -eq 'Debug') { 'true' } else { 'false' })

v8_enable_i18n_support = false
v8_enable_webassembly = false
# Temporal is implemented in Rust. v8_static_library sets complete_static_lib,
# which archives transitive C++ objects but not Rust rlibs, so the monolith ends
# up referencing temporal_rs_* without containing it. Add-RustArchives folds
# them in afterwards; without that step this has to be false.
v8_enable_temporal_support = $(if ($Temporal) { 'true' } else { 'false' })
treat_warnings_as_errors = false
"@
}

# Temporal is Rust, and gn's complete_static_lib archives transitive C++ objects
# but not Rust rlibs - so the monolith references temporal_rs_* without
# containing it, and a consumer gets ~20 undefined symbols at link time. Fold the
# whole Rust graph in, plus clang's builtins: Rust's f16 helpers (__extendhfsf2 /
# __truncsfhf2) live there and nothing else in the archive supplies them.
#
# lld-link doubles as the librarian, so this needs no tool the build did not
# already require. Its /lib must be the literal first argument - inside a
# response file it is ignored with a warning and the invocation turns into a
# link, which then fails for unrelated reasons.
function Add-RustArchives {
    param($Src, $Out, $Arch, $Lib)

    $rlibs = @(
        Get-ChildItem (Join-Path $Out 'obj') -Recurse -Filter *.rlib -File -ErrorAction SilentlyContinue
        Get-ChildItem (Join-Path $Out 'local_rustc_sysroot') -Recurse -Filter *.rlib -File -ErrorAction SilentlyContinue
    )
    if (-not $rlibs) { return $Lib }        # Temporal off - nothing to fold in

    $llvm     = Join-Path $Src 'third_party\llvm-build\Release+Asserts\bin'
    $machine  = if ($Arch -eq 'x64') { 'X64' } else { 'X86' }
    $rtName   = if ($Arch -eq 'x64') { 'clang_rt.builtins-x86_64.lib' } else { 'clang_rt.builtins-i386.lib' }
    $builtins = Get-ChildItem (Join-Path $Src 'third_party\llvm-build\Release+Asserts\lib\clang') `
                              -Recurse -Filter $rtName -File -ErrorAction SilentlyContinue |
                Select-Object -First 1 -ExpandProperty FullName

    $merged = Join-Path $Out 'obj\v8_monolith_full.lib'
    $rsp    = Join-Path $Out 'merge.rsp'
    $items  = @("/out:$merged", "/machine:$machine", $Lib)
    if ($builtins) { $items += $builtins }
    $items += ($rlibs | Select-Object -ExpandProperty FullName)
    $items | Set-Content -Encoding ascii $rsp

    Invoke-Native {
        & (Join-Path $llvm 'lld-link.exe') /lib "@$rsp" 2>&1 | Where-Object { $_ -match 'error' }
    } 'folding the Rust archives into the monolith'
    if (-not (Test-Path $merged)) { Die "the Rust merge produced nothing at $merged" }

    Ok ("folded in {0} Rust archives -> {1:N0} MB" -f $rlibs.Count, ((Get-Item $merged).Length / 1MB))
    return $merged
}

function Invoke-Build {
    param($Src, $DepotTools, $Arch, $Config)

    $tag = "$Arch-$($Config.ToLower())"
    $out = Join-Path $Src "out\$tag"
    $argsText = New-Args -Arch $Arch -Config $Config

    # A stale objdir from another version compiles current sources against old
    # generated headers; gn gen will not notice.
    $stamp = Join-Path $out '.built-version'
    if ((Test-Path $out) -and ((-not (Test-Path $stamp)) -or ((Get-Content $stamp -Raw).Trim() -ne $Version))) {
        Info "objdir was built from a different version - wiping $tag"
        [System.IO.Directory]::Delete($out, $true)
    }
    New-Item -ItemType Directory -Force $out | Out-Null
    $argsText | Set-Content -Encoding ascii (Join-Path $out 'args.gn')

    Push-Location $Src
    try {
        Info "gn gen ($tag)"
        Invoke-Native { & (Join-Path $DepotTools 'gn.bat') gen "out/$tag" 2>&1 | Out-Null } "gn gen ($tag)"

        Info "building v8_monolith ($tag)"
        $log = Join-Path $Root "build-$tag.log"
        $ninja = Join-Path $DepotTools 'autoninja.bat'
        Invoke-Native { & $ninja -C "out/$tag" v8_monolith *> $log } "ninja ($tag)" -AllowFailure
        if ($LASTEXITCODE -ne 0) {
            Get-Content (Join-Path $Root "build-$tag.log") -Tail 20
            Die "build failed ($tag); see build-$tag.log"
        }
    } finally { Pop-Location }

    $lib = Join-Path $out 'obj\v8_monolith.lib'
    if (-not (Test-Path $lib)) { Die "no monolith at $lib" }
    $Version | Set-Content -Encoding ascii $stamp
    Ok ("v8_monolith.lib {0:N0} MB" -f ((Get-Item $lib).Length / 1MB))

    $lib = Add-RustArchives -Src $Src -Out $out -Arch $Arch -Lib $lib

    # Self-contained by now, so "packaging" is a copy.
    $dist = Join-Path $Root "dist-$tag"
    if (Test-Path $dist) { [System.IO.Directory]::Delete($dist, $true) }
    New-Item -ItemType Directory -Force (Join-Path $dist 'include') | Out-Null
    Copy-Item $lib (Join-Path $dist 'v8_monolith.lib')
    Copy-Item (Join-Path $Src 'include\*') (Join-Path $dist 'include') -Recurse
    # Generated into the objdir rather than the source tree; v8config.h includes
    # it by name from its own directory when V8_GN_HEADER is defined.
    $gnHeader = Join-Path $out 'gen\include\v8-gn.h'
    if (-not (Test-Path $gnHeader)) { Die "no v8-gn.h at $gnHeader" }
    Copy-Item $gnHeader (Join-Path $dist 'include')

    $crt = if ($Config -eq 'Debug') { '/MTd (libcmtd)' } else { '/MT (libcmt)' }
    $defines = '/DV8_GN_HEADER'
    $toolset = Get-MsvcToolset
    $builtWith = if ($toolset) { "$($toolset.Version)  ($($toolset.Display))" } else { 'unknown' }
    $idl = if ($Config -ne 'Debug') { '' } else { @'

This Debug library keeps MSVC's checked iterators (_ITERATOR_DEBUG_LEVEL=2, the
default), so it links against Debug code built the ordinary way - no
_HAS_ITERATOR_DEBUGGING on the consumer side, and no rebuild of any other static
library to match.
'@ }
    @"
V8 $Version ($Arch $Config), static CRT.

  link against : v8_monolith.lib
  include path : include
  compile with : $defines
  CRT          : $crt - must match the consuming project
  built with   : MSVC $builtWith
  system libs  : winmm.lib dbghelp.lib advapi32.lib shlwapi.lib ws2_32.lib
                 user32.lib kernel32.lib ole32.lib oleaut32.lib psapi.lib
                 version.lib ntdll.lib userenv.lib bcrypt.lib

Link this with MSVC $($toolset.Short) or newer. An older toolset fails with
undefined __std_* symbols: the STL headers this was compiled against call
helpers that ship in that toolset's own libcpmt.lib. Note the toolset version is
what matters, not the Visual Studio year - 14.44 ships under both 2022 and 2026.
$idl
V8_GN_HEADER makes v8config.h pull in the bundled include/v8-gn.h, which carries
the exact define set this library was built with. Without it the public headers
fall back to their defaults - a different internal field count, no pointer
compression - and lay objects out differently from the library, which is an ABI
mismatch rather than a compile error. V8::Initialize() catches the subset it can
see and aborts; the rest corrupts silently.

Built with v8_monolithic=true and is_component_build=false; the latter is what
selects the static CRT in Chromium's Windows config.

Pointer compression is enabled on x64 and unsupported on x86. The sandbox is off
everywhere: it requires V8's hardened libc++, which cannot be used by a library
that has to interoperate with MSVC's STL. i18n and WebAssembly are disabled.

Temporal is built in - its Rust archives are part of this .lib, so nothing extra
needs linking - but it stays behind a runtime flag: pass --harmony-temporal.
"@ | Set-Content -Encoding ascii (Join-Path $dist 'README.txt')

    # Machine-readable counterpart to the "built with" line above, so packaging
    # can label an archive with the toolset it needs without re-deriving it.
    if ($toolset) { $toolset.Short | Set-Content -Encoding ascii (Join-Path $dist 'toolset.txt') }

    Ok "dist: $dist$(if ($toolset) { " (MSVC $($toolset.Short))" })"
    return $dist
}

# The PE import table, parsed directly. V8 bundles its own clang but no
# object-inspection tools, and dumpbin / llvm-readobj would each add a
# prerequisite the build itself does not need.
function Get-ImportedDll {
    param([string]$Path)

    $b     = [System.IO.File]::ReadAllBytes($Path)
    $pe    = [BitConverter]::ToInt32($b, 0x3C)
    $opt   = $pe + 24
    # 0x20B is PE32+, whose optional header is 16 bytes longer before the data
    # directories; entry 1 of those is the import table.
    $dirs  = $opt + $(if ([BitConverter]::ToUInt16($b, $opt) -eq 0x20B) { 112 } else { 96 })
    $impRva = [BitConverter]::ToUInt32($b, $dirs + 8)
    if ($impRva -eq 0) { return @() }

    $sections = @()
    $secBase  = $opt + [BitConverter]::ToUInt16($b, $pe + 20)
    foreach ($i in 0..([BitConverter]::ToUInt16($b, $pe + 6) - 1)) {
        $s = $secBase + ($i * 40)
        $sections += , @([BitConverter]::ToUInt32($b, $s + 12),   # virtual address
                         [BitConverter]::ToUInt32($b, $s + 16),   # virtual size
                         [BitConverter]::ToUInt32($b, $s + 20))   # raw file offset
    }
    $toFile = {
        param($rva)
        foreach ($s in $sections) {
            if ($rva -ge $s[0] -and $rva -lt ($s[0] + $s[1])) { return $s[2] + ($rva - $s[0]) }
        }
        0
    }

    $names = @()
    $desc  = & $toFile $impRva
    # Descriptors are 20 bytes and the array ends with an all-zero one, so a
    # null name RVA is the terminator.
    while ($desc -and ([BitConverter]::ToUInt32($b, $desc + 12) -ne 0)) {
        $p = & $toFile ([BitConverter]::ToUInt32($b, $desc + 12))
        $e = $p
        while ($b[$e] -ne 0) { $e++ }
        $names += [System.Text.Encoding]::ASCII.GetString($b, $p, $e - $p)
        $desc += 20
    }
    $names
}

function Test-Package {
    param($Src, $Arch, $Config, $Dist)

    # V8's own bundled clang, not Visual Studio's: it is the compiler that built
    # the library, so the spike cannot drift from it on ABI or CRT selection.
    $llvm = Join-Path $Src 'third_party\llvm-build\Release+Asserts\bin'
    if (-not (Test-Path (Join-Path $llvm 'clang-cl.exe'))) { Die "no bundled clang-cl at $llvm" }

    $work = Join-Path $Root "verify-$Arch-$($Config.ToLower())"
    if (Test-Path $work) { [System.IO.Directory]::Delete($work, $true) }
    New-Item -ItemType Directory -Force $work | Out-Null
    Info "verifying ($Arch $Config)"

    @'
#include <memory>

#include "libplatform/libplatform.h"
#include "v8.h"

// V8::Initialize() hashes pointer compression, Smi width and the sandbox out of
// the headers and checks them against the library, so reaching the evaluation at
// all already proves the shipped v8-gn.h agrees with what was built.
extern "C" __declspec(dllexport) int SpikeRun() {
#if EXPECT_TEMPORAL
    // Built in, but still behind a runtime flag.
    v8::V8::SetFlagsFromString("--harmony-temporal");
#endif
    std::unique_ptr<v8::Platform> platform = v8::platform::NewDefaultPlatform();
    v8::V8::InitializePlatform(platform.get());
    v8::V8::Initialize();

    int rc = 0;
    v8::Isolate::CreateParams params;
    params.array_buffer_allocator = v8::ArrayBuffer::Allocator::NewDefaultAllocator();
    v8::Isolate* isolate = v8::Isolate::New(params);
    {
        v8::Isolate::Scope isolateScope(isolate);
        v8::HandleScope handleScope(isolate);
        v8::Local<v8::Context> context = v8::Context::New(isolate);
        v8::Context::Scope contextScope(context);

        // Two expressions. The first proves the engine runs at all. The second
        // is Rust code folded into the archive after the fact, so evaluating it
        // is the only way to prove that merge produced something callable
        // rather than merely something that links.
        const char* sources[] = {
            "40 + 2",
            "typeof Temporal === 'undefined' ? -1 :"
            " Temporal.PlainDate.from('2020-01-23')"
            "         .until(Temporal.PlainDate.from('2020-03-01')).days",
        };
        const int32_t expected[] = {42, EXPECT_TEMPORAL ? 38 : -1};

        for (int i = 0; i < 2 && rc == 0; ++i) {
            v8::Local<v8::String> source;
            if (!v8::String::NewFromUtf8(isolate, sources[i]).ToLocal(&source)) { rc = 1; break; }
            v8::Local<v8::Script> script;
            v8::Local<v8::Value> result;
            int32_t value = 0;
            if (!v8::Script::Compile(context, source).ToLocal(&script)) rc = 10 * (i + 1) + 1;
            else if (!script->Run(context).ToLocal(&result))            rc = 10 * (i + 1) + 2;
            else if (!result->Int32Value(context).To(&value))           rc = 10 * (i + 1) + 3;
            else if (value != expected[i])                              rc = 10 * (i + 1) + 4;
        }
    }
    isolate->Dispose();
    delete params.array_buffer_allocator;
    v8::V8::Dispose();
    v8::V8::DisposePlatform();
    return rc;
}
'@ | Set-Content -Encoding ascii (Join-Path $work 'verify.cpp')

    Push-Location $work
    try {
        # One argument array: mixing inline splatting with literal arguments
        # mangles the native command line.
        $cargs = @()
        if ($Arch -eq 'x86') { $cargs += '-m32' }
        $cargs += @('-c', '/nologo', '/std:c++20', '/EHsc',
                    $(if ($Config -eq 'Debug') { '/MTd' } else { '/MT' }),
                    '/DV8_GN_HEADER', '/DWIN32', '/D_WINDOWS', '/DNOMINMAX',
                    "/DEXPECT_TEMPORAL=$(if ($Temporal) { 1 } else { 0 })",
                    # Nothing sets _HAS_ITERATOR_DEBUGGING here on purpose: the
                    # spike is compiled the way a consumer's own code would be,
                    # so a library built with a different _ITERATOR_DEBUG_LEVEL
                    # fails this link rather than theirs.
                    "/I$Dist\include", 'verify.cpp', '/Foverify.obj')
        Invoke-Native {
            & "$llvm\clang-cl.exe" @cargs 2>&1 | Where-Object { $_ -match 'error' }
        } 'verify compile' -AllowFailure
        if (-not (Test-Path 'verify.obj')) { Die "verify compile failed ($Arch $Config)" }

        # ntdll / userenv / bcrypt are Rust's, not V8's: its standard library
        # reaches ntdll directly (NtOpenFile and friends), which is why they only
        # became necessary once Temporal brought Rust into the archive.
        $sys = @('winmm', 'dbghelp', 'advapi32', 'shlwapi', 'ws2_32',
                 'user32', 'kernel32', 'ole32', 'oleaut32', 'psapi', 'version',
                 'ntdll', 'userenv', 'bcrypt') |
               ForEach-Object { "$_.lib" }
        $largs = @('/DLL', '/OUT:verify.dll', '/NOLOGO', '/SUBSYSTEM:WINDOWS',
                   $(if ($Arch -eq 'x86') { '/MACHINE:X86' } else { '/MACHINE:X64' }),
                   'verify.obj', (Join-Path $Dist 'v8_monolith.lib')) + $sys
        # A response file: the monolith's path plus the system set overruns the
        # command-line limit on some hosts.
        $largs | Set-Content -Encoding ascii 'verify.rsp'
        Invoke-Native {
            & "$llvm\lld-link.exe" '@verify.rsp' 2>&1 | Where-Object { $_ -match 'error' }
        } 'verify link' -AllowFailure
        if (-not (Test-Path 'verify.dll')) { Die "verify link failed ($Arch $Config)" }

        $crt = @(Get-ImportedDll (Join-Path $work 'verify.dll') |
                 Where-Object { $_ -match 'vcruntime|msvcp|msvcr|api-ms-win-crt' })
        if ($crt.Count) { Die "verify.dll imports $($crt -join ', ') - the static CRT did not take" }
        Ok 'linked, 0 dynamic-CRT imports'

        $runner = @"
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class V {
    [DllImport(@"$work\verify.dll", EntryPoint="SpikeRun", CallingConvention=CallingConvention.Cdecl)]
    public static extern int Run();
}
'@
exit [V]::Run()
"@
        $runner | Set-Content -Encoding ascii 'run.ps1'
        # A 32-bit DLL needs a 32-bit host process.
        $ps = if ($Arch -eq 'x86') { "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" }
              else                 { "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }
        Invoke-Native {
            & $ps -NoProfile -ExecutionPolicy Bypass -File (Join-Path $work 'run.ps1')
        } 'verify run' -AllowFailure
        if ($LASTEXITCODE -ne 0) { Die "verify.dll ran but returned $LASTEXITCODE (expected 0)" }
        Ok $(if ($Temporal) { 'executed JavaScript, arithmetic and Temporal both correct' }
             else           { 'executed JavaScript successfully (40 + 2 == 42)' })
    } finally { Pop-Location }
}

# --- main ------------------------------------------------------------------

New-Item -ItemType Directory -Force $Root | Out-Null
$Root = (Resolve-Path $Root).Path
Info "root: $Root"
Info "version: $Version"

$dt  = Initialize-DepotTools
$src = Initialize-Checkout -DepotTools $dt
# After sync: patching before it would leave a dirty tree, which silently blocks
# gclient and leaves dependencies on the previous version's pins.
Invoke-SourcePatches -Src $src
Invoke-ToolchainPatches -Src $src

$arches  = if ($Arch   -eq 'both') { @('x86', 'x64') }        else { @($Arch) }
$configs = if ($Config -eq 'both') { @('Release', 'Debug') }  else { @($Config) }

$built = [ordered]@{}
foreach ($a in $arches) {
    foreach ($c in $configs) {
        $built["$a-$($c.ToLower())"] = @{
            Dist = (Invoke-Build -Src $src -DepotTools $dt -Arch $a -Config $c); Arch = $a; Config = $c
        }
    }
}
if ($Verify) {
    foreach ($k in $built.Keys) {
        Test-Package -Src $src -Arch $built[$k].Arch -Config $built[$k].Config -Dist $built[$k].Dist
    }
}

Info 'done'
foreach ($k in $built.Keys) { Ok "$k -> $($built[$k].Dist)" }
