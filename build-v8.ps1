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
  Compile and link a small DLL against the result and run a script through it.

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
    # Its self-update fails if the tree has local modifications (symlink
    # typechanges are common on Windows) and then blocks every command.
    $env:DEPOT_TOOLS_UPDATE = '0'
    # Mandatory for non-Googlers: otherwise it tries to fetch Google's internal
    # packaged toolchain instead of using the local Visual Studio.
    $env:DEPOT_TOOLS_WIN_TOOLCHAIN = '0'
    $env:PATH = "$dt;$env:PATH"
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
        Info "cloning v8 (this is the slow part)"
        Invoke-Native {
            git clone --no-checkout https://chromium.googlesource.com/v8/v8.git $src 2>&1 | Out-Null
        } 'v8 clone'
    }

    Push-Location $src
    try {
        Invoke-Native { git fetch --no-tags origin tag $Version 2>&1 | Out-Null } "fetch tag $Version" -AllowFailure
        # A dirty build/ blocks gclient sync, so make sure dependencies are clean
        # before switching versions.
        if (Test-Path 'build\.git') {
            Push-Location build
            Invoke-Native { git checkout -- . 2>&1 | Out-Null } 'clean build/' -AllowFailure
            Pop-Location
        }
        Invoke-Native { git checkout -q $Version 2>&1 | Out-Null } "checkout $Version"
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
        }
    )

    $applied = 0
    foreach ($p in $patches) {
        $path = Join-Path $Src $p.File
        if (-not (Test-Path $path)) { continue }          # not present in this version
        $text = Get-Content $path -Raw
        if ($text.Contains($p.New) -and -not $text.Contains($p.Old)) { continue }   # already patched
        if (-not $text.Contains($p.Old)) {
            Ok "  skipped $($p.File) - pattern absent (fixed upstream?)"
            continue
        }
        $text.Replace($p.Old, $p.New) | Set-Content -Encoding ascii -NoNewline $path
        Ok "  patched $($p.File) - $($p.Why)"
        $applied++
    }
    if ($applied) { Info "applied $applied source patch(es)" } else { Ok 'no source patches needed' }
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

# MSVC's STL rather than the bundled libc++.
use_custom_libcxx = false
use_custom_libcxx_for_host = false

# Pointer compression is unsupported on x86, and the sandbox requires the
# external code space, which in turn requires pointer compression.
v8_enable_pointer_compression = $(if ($is64) { 'true' } else { 'false' })
v8_enable_sandbox = $(if ($is64) { 'true' } else { 'false' })

v8_enable_backtrace = $(if ($Config -eq 'Debug') { 'true' } else { 'false' })
v8_enable_slow_dchecks = $(if ($Config -eq 'Debug') { 'true' } else { 'false' })
v8_optimized_debug = $(if ($Config -eq 'Debug') { 'true' } else { 'false' })
enable_iterator_debugging = $(if ($Config -eq 'Debug') { 'true' } else { 'false' })

v8_enable_i18n_support = false
v8_enable_webassembly = false
# Keeping Temporal off avoids the monolith referencing temporal_capi, a Rust
# static library whose objects a v8_static_library does not archive.
v8_enable_temporal_support = false
treat_warnings_as_errors = false
"@
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

    # The monolith is self-contained, so "packaging" is a copy.
    $dist = Join-Path $Root "dist-$tag"
    if (Test-Path $dist) { [System.IO.Directory]::Delete($dist, $true) }
    New-Item -ItemType Directory -Force (Join-Path $dist 'include') | Out-Null
    Copy-Item $lib (Join-Path $dist 'v8_monolith.lib')
    Copy-Item (Join-Path $Src 'include\*') (Join-Path $dist 'include') -Recurse

    $crt = if ($Config -eq 'Debug') { '/MTd (libcmtd)' } else { '/MT (libcmt)' }
    @"
V8 $Version ($Arch $Config), static CRT.

  link against : v8_monolith.lib
  include path : include
  CRT          : $crt - must match the consuming project
  system libs  : winmm.lib dbghelp.lib advapi32.lib shlwapi.lib

Built with v8_monolithic=true and is_component_build=false; the latter is what
selects the static CRT in Chromium's Windows config.

Pointer compression and the sandbox are enabled on x64 and disabled on x86
(pointer compression is unsupported there, and the sandbox depends on it).
i18n, WebAssembly and Temporal are disabled.
"@ | Set-Content -Encoding ascii (Join-Path $dist 'README.txt')
    Ok "dist: $dist"
    return $dist
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

$arches  = if ($Arch   -eq 'both') { @('x86', 'x64') }        else { @($Arch) }
$configs = if ($Config -eq 'both') { @('Release', 'Debug') }  else { @($Config) }

$built = [ordered]@{}
foreach ($a in $arches) {
    foreach ($c in $configs) {
        $built["$a-$($c.ToLower())"] = Invoke-Build -Src $src -DepotTools $dt -Arch $a -Config $c
    }
}

Info 'done'
foreach ($k in $built.Keys) { Ok "$k -> $($built[$k])" }
