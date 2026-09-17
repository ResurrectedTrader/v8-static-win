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
    # Generated into the objdir rather than the source tree; v8config.h includes
    # it by name from its own directory when V8_GN_HEADER is defined.
    $gnHeader = Join-Path $out 'gen\include\v8-gn.h'
    if (-not (Test-Path $gnHeader)) { Die "no v8-gn.h at $gnHeader" }
    Copy-Item $gnHeader (Join-Path $dist 'include')

    $crt = if ($Config -eq 'Debug') { '/MTd (libcmtd)' } else { '/MT (libcmt)' }
    @"
V8 $Version ($Arch $Config), static CRT.

  link against : v8_monolith.lib
  include path : include
  compile with : /DV8_GN_HEADER
  CRT          : $crt - must match the consuming project
  system libs  : winmm.lib dbghelp.lib advapi32.lib shlwapi.lib

V8_GN_HEADER makes v8config.h pull in the bundled include/v8-gn.h, which carries
the exact define set this library was built with. Without it the public headers
fall back to their defaults - a different internal field count, no pointer
compression - and lay objects out differently from the library, which is an ABI
mismatch rather than a compile error. V8::Initialize() catches the subset it can
see and aborts; the rest corrupts silently.

Built with v8_monolithic=true and is_component_build=false; the latter is what
selects the static CRT in Chromium's Windows config.

Pointer compression and the sandbox are enabled on x64 and disabled on x86
(pointer compression is unsupported there, and the sandbox depends on it).
i18n, WebAssembly and Temporal are disabled.
"@ | Set-Content -Encoding ascii (Join-Path $dist 'README.txt')
    Ok "dist: $dist"
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

        v8::Local<v8::String> source = v8::String::NewFromUtf8Literal(isolate, "40 + 2");
        v8::Local<v8::Script> script;
        v8::Local<v8::Value> result;
        int32_t value = 0;
        if (!v8::Script::Compile(context, source).ToLocal(&script)) rc = 1;
        else if (!script->Run(context).ToLocal(&result))            rc = 2;
        else if (!result->Int32Value(context).To(&value))           rc = 3;
        else if (value != 42)                                       rc = 4;
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
                    "/I$Dist\include", 'verify.cpp', '/Foverify.obj')
        Invoke-Native {
            & "$llvm\clang-cl.exe" @cargs 2>&1 | Where-Object { $_ -match 'error' }
        } 'verify compile' -AllowFailure
        if (-not (Test-Path 'verify.obj')) { Die "verify compile failed ($Arch $Config)" }

        $sys = @('winmm', 'dbghelp', 'advapi32', 'shlwapi', 'ws2_32',
                 'user32', 'kernel32', 'ole32', 'oleaut32', 'psapi', 'version') |
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
        Ok 'executed JavaScript successfully (40 + 2 == 42)'
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
