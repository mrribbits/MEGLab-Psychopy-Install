#Requires -Version 5.1
<#
.SYNOPSIS
    Installer for PsychoPy + VPixx (pypixxlib) + SR Research EyeLink (pylink).
    Two modes: a per-user conda environment, or the Standalone PsychoPy app.

.DESCRIPTION
    Mode 'conda'      : installs a per-user Miniconda if needed (no admin), creates a
                        conda env, pip-installs PsychoPy, then wires in the VPixx and
                        EyeLink Python APIs and (optionally) psychtoolbox.

    Mode 'standalone' : downloads the latest StandalonePsychoPy Windows installer from
                        PsychoPy's GitHub releases, runs it, then wires the VPixx and
                        EyeLink APIs into the app's bundled Python. (psychtoolbox already
                        ships inside Standalone.)

    The VPixx tarball and the EyeLink pylink folder live in machine-specific locations,
    so they are auto-detected. Override with -VpixxTarball / -PylinkDir.

.PARAMETER Mode
    'conda', 'standalone', 'uninstall-conda', 'uninstall-standalone', or 'ask'
    (default - prompts interactively with a 1-4 menu).

.PARAMETER Facility
    Scully facility being set up, which decides the API set:
    'mri'/'eeg'/'eyetracking' -> pylink; 'meg' -> pylink + VPixx; 'tms'/'testing' -> neither.
    'ask' (default) prompts with a 1-6 menu. PsychoPy installs regardless of facility.

.PARAMETER PsychopyVersion
    PsychoPy version to install, e.g. '2024.2.4'. 'latest' installs the newest available.
    'ask' (default) prompts (blank entry = latest). Conda mode -> pip; standalone mode ->
    the matching GitHub release.

.PARAMETER EnvName
    Conda environment name (conda mode). Default: psychopy

.PARAMETER PyVersion
    Python version for the conda env / the StandalonePsychoPy build to pick. Default: 3.10

.PARAMETER VpixxTarball
    Full path to pypixxlib-<ver>.tar.gz. Auto-detected if omitted.

.PARAMETER PylinkDir
    Full path to the EyeLink ...\Python\64\<ver> folder (the one containing 'pylink').
    Auto-detected (matched to the target interpreter's Python version) if omitted.

.PARAMETER MinicondaPath
    Where to install/find a per-user Miniconda (conda mode). Default: %USERPROFILE%\miniconda3

.PARAMETER StandaloneDir
    Existing PsychoPy install folder (standalone mode). Auto-detected if omitted.

.PARAMETER UseExistingConda
    Use a conda already on PATH instead of installing a per-user Miniconda.

.PARAMETER SkipPsychtoolbox
    Conda mode: skip installing psychtoolbox.

.PARAMETER Force
    Conda mode: recreate the env if it exists. Standalone mode: re-download/reinstall
    even if an install is already found.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-PsychoPy.ps1

.EXAMPLE
    .\Install-PsychoPy.ps1 -Mode standalone

.EXAMPLE
    .\Install-PsychoPy.ps1 -Mode uninstall-conda          # delete the psychopy env (prompts)
    .\Install-PsychoPy.ps1 -Mode uninstall-standalone -Force   # skip the confirmation

.EXAMPLE
    .\Install-PsychoPy.ps1 -Mode conda -VpixxTarball "C:\Tools\pypixxlib-1.11.3.tar.gz" -Force

.NOTES
    Windows / PowerShell only. No admin needed for conda mode. Standalone mode needs a
    user-writable install location for the API wiring to succeed (see INSTRUCTIONS.md).
#>

[CmdletBinding()]
param(
    [ValidateSet('conda','standalone','uninstall-conda','uninstall-standalone','ask')]
    [string]$Mode           = 'ask',
    [ValidateSet('mri','meg','eeg','eyetracking','tms','testing','ask')]
    [string]$Facility       = 'ask',
    [string]$PsychopyVersion = 'ask',
    [string]$EnvName        = 'psychopy',
    [string]$PyVersion      = '3.10',
    [string]$VpixxTarball   = '',
    [string]$PylinkDir      = '',
    [string]$MinicondaPath  = (Join-Path $env:USERPROFILE 'miniconda3'),
    [string]$StandaloneDir  = '',
    [switch]$UseExistingConda,
    [switch]$SkipPsychtoolbox,
    [switch]$Force
)

# Native commands (conda/pip) write progress to stderr; don't let that be treated as a
# terminating error. We check $LASTEXITCODE explicitly.
$ErrorActionPreference = 'Continue'

function Info ($m) { Write-Host "[*]  $m"  -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "[OK] $m"  -ForegroundColor Green }
function Warn ($m) { Write-Host "[!]  $m"  -ForegroundColor Yellow }
function Die  ($m) { Write-Host "[X]  $m"  -ForegroundColor Red; exit 1 }

function Get-PersistentExecPolicy {
    # The policy a NEW, normally-launched PowerShell resolves to. Ignores the
    # -ExecutionPolicy Bypass we were started with (that only affects THIS process).
    foreach ($scope in 'MachinePolicy', 'UserPolicy', 'CurrentUser', 'LocalMachine') {
        $p = Get-ExecutionPolicy -Scope $scope
        if ($p -ne 'Undefined') { return $p }
    }
    return 'Restricted'
}

Write-Host "=== PsychoPy / VPixx / EyeLink installer ===" -ForegroundColor Magenta

# =========================================================================
#  Shared helpers
# =========================================================================

function Get-CondaExe {
    param([string]$Prefix)
    $exe = Join-Path $Prefix 'Scripts\conda.exe'
    if (Test-Path $exe) { return $exe }
    return $null
}

# Resolve a conda.exe to use: per-user Miniconda at -MinicondaPath, else one on PATH.
function Resolve-AnyConda {
    $c = Get-CondaExe -Prefix $MinicondaPath
    if (-not $c) {
        $cmd = Get-Command conda -ErrorAction SilentlyContinue
        if ($cmd) { $c = $cmd.Source }
    }
    return $c
}

# Returns the GitHub release object for a given PsychoPy version ('latest' or a tag like
# 2024.2.4). For 'latest' it falls back to scanning recent releases if the 'latest'
# endpoint has no Windows installer asset.
function Get-PsychopyRelease {
    param([string]$Version, [hashtable]$Hdr)
    $api = 'https://api.github.com/repos/psychopy/psychopy/releases'
    if ($Version -ne 'latest') {
        return Invoke-RestMethod -Uri "$api/tags/$Version" -Headers $Hdr
    }
    try {
        $r = Invoke-RestMethod -Uri "$api/latest" -Headers $Hdr
        if (@($r.assets | Where-Object { $_.name -match 'win64.*\.exe$' })) { return $r }
    } catch { }
    foreach ($r in (Invoke-RestMethod -Uri "$api`?per_page=20" -Headers $Hdr)) {
        if (@($r.assets | Where-Object { $_.name -match 'win64.*\.exe$' })) { return $r }
    }
    return $null
}

function Find-StandalonePython {
    param([string]$Hint)
    $roots = @()
    if ($Hint) { $roots += $Hint }
    $roots += @(
        (Join-Path $env:LOCALAPPDATA 'Programs\PsychoPy'),
        (Join-Path $env:LOCALAPPDATA 'PsychoPy'),
        'C:\Program Files\PsychoPy',
        (Join-Path ${env:ProgramFiles(x86)} 'PsychoPy')
    )
    foreach ($r in ($roots | Where-Object { $_ -and (Test-Path $_) })) {
        $direct = Join-Path $r 'python.exe'
        if (Test-Path $direct) { return $direct }
        $cands = Get-ChildItem -Path $r -Recurse -Filter 'python.exe' -ErrorAction SilentlyContinue
        foreach ($c in $cands) {
            & $c.FullName -c "import psychopy" 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { return $c.FullName }
        }
        if ($cands) { return $cands[0].FullName }
    }
    return $null
}

function Ensure-Pip {
    # conda-forge's python ships without pip; bootstrap it from the stdlib if missing.
    param([string]$Python)
    & $Python -m pip --version 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Info "Bootstrapping pip (ensurepip)..."
        & $Python -m ensurepip --upgrade | Out-Null
        if ($LASTEXITCODE -ne 0) { Die "Could not bootstrap pip for $Python." }
    }
}

function PipInto {
    param([string]$Python, [Parameter(ValueFromRemainingArguments = $true)][string[]]$A)
    & $Python -m pip @A
    if ($LASTEXITCODE -ne 0) { Die "pip $($A -join ' ') failed (target location may be read-only - see notes)." }
}

function Find-VpixxTarball {
    $roots = @(
        'C:\Program Files\VPixx Technologies',
        'C:\Program Files (x86)\VPixx Technologies',
        (Join-Path $env:USERPROFILE 'Documents')
    ) | Where-Object { Test-Path $_ }
    $cand = @()
    foreach ($r in $roots) {
        $cand += Get-ChildItem -Path $r -Recurse -Filter 'pypixxlib-*.tar.gz' -ErrorAction SilentlyContinue
    }
    $cand = $cand | Sort-Object Name
    if (-not $cand) { return $null }
    if ($cand.Count -gt 1) { Warn "Multiple VPixx tarballs found; using newest by name: $($cand[-1].Name)" }
    return $cand[-1].FullName
}

function Find-PylinkDir {
    param([string]$PyVer)
    $cands = @(
        "C:\Program Files (x86)\SR Research\EyeLink\SampleExperiments\Python\64\$PyVer",
        "C:\Program Files\SR Research\EyeLink\SampleExperiments\Python\64\$PyVer"
    )
    foreach ($c in $cands) {
        if ((Test-Path $c) -and (Test-Path (Join-Path $c 'pylink'))) { return $c }
    }
    $srRoots = @('C:\Program Files (x86)\SR Research', 'C:\Program Files\SR Research') |
               Where-Object { Test-Path $_ }
    foreach ($r in $srRoots) {
        $hit = Get-ChildItem -Path $r -Recurse -Directory -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -eq $PyVer -and (Test-Path (Join-Path $_.FullName 'pylink')) } |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

# Installs VPixx and/or pylink (+ optional psychtoolbox) into a given Python interpreter,
# then verifies imports. Returns $true if everything verified.
function Install-Apis {
    param(
        [string]$Python,
        [bool]$InstallVpixx,
        [bool]$InstallPylink,
        [bool]$InstallPsychtoolbox,
        [bool]$VerifyPsychtoolbox
    )

    # Make sure this interpreter has pip.
    Ensure-Pip $Python

    $effPy = (& $Python -c "import sys; print('%d.%d' % sys.version_info[:2])").Trim()
    Info "Target interpreter: $Python  (Python $effPy)"

    # --- VPixx pypixxlib ---
    if ($InstallVpixx) {
        $vp = if ($VpixxTarball) { $VpixxTarball } else { Find-VpixxTarball }
        if ($vp) {
            if (-not (Test-Path $vp)) { Die "VPixx tarball not found: $vp" }
            Info "Installing pypixxlib from: $vp"
            PipInto $Python install $vp
            Ok "pypixxlib installed"
        } else {
            Warn "VPixx tarball not found; pass -VpixxTarball '<path>'. Skipping VPixx."
            $InstallVpixx = $false
        }
    } else {
        Info "VPixx not needed for this facility - skipping pypixxlib."
    }

    # --- EyeLink pylink (.pth pointing at the SR Research folder for this Python) ---
    if ($InstallPylink) {
        $pl = if ($PylinkDir) { $PylinkDir } else { Find-PylinkDir -PyVer $effPy }
        if ($pl -and (Test-Path (Join-Path $pl 'pylink'))) {
            $site = (& $Python -c "import sysconfig; print(sysconfig.get_paths()['purelib'])").Trim()
            $pth  = Join-Path $site 'pylink.pth'
            $line = ($pl -replace '\\', '/')   # forward slashes are valid in sys.path on Windows
            try {
                # No BOM - Python's site.py mis-parses a UTF-8 BOM on the first .pth line.
                [System.IO.File]::WriteAllText($pth, $line + "`r`n", [System.Text.UTF8Encoding]::new($false))
                Ok "Wrote $pth"
                Info "  -> $line"
            } catch {
                Die "Could not write $pth ($($_.Exception.Message)). If PsychoPy is under 'Program Files', reinstall it to a user-writable folder (no admin needed)."
            }
        } else {
            Warn "EyeLink pylink folder for Python $effPy not found; pass -PylinkDir '<...\Python\64\$effPy>'. Skipping pylink."
            $InstallPylink = $false
        }
    } else {
        Info "EyeLink not needed for this facility - skipping pylink."
    }

    # --- psychtoolbox (conda mode only; Standalone bundles it) ---
    if ($InstallPsychtoolbox) {
        Info "Installing psychtoolbox (low-latency audio)..."
        PipInto $Python install psychtoolbox
        Ok "psychtoolbox installed"
    }

    # --- Verify (only what we actually installed) ---
    Info "Verifying imports..."
    $checks = @(
        @{ Name = 'PsychoPy'; Code = 'import psychopy; print(psychopy.__version__)' }
    )
    if ($InstallPylink)       { $checks += @{ Name = 'pylink';       Code = 'import pylink; print(pylink.__file__)' } }
    if ($InstallVpixx)        { $checks += @{ Name = 'pypixxlib';    Code = 'from pypixxlib import _libdpx' } }
    if ($VerifyPsychtoolbox)  { $checks += @{ Name = 'psychtoolbox'; Code = 'import psychtoolbox' } }

    $allOk = $true
    foreach ($c in $checks) {
        $out = (& $Python -c $c.Code 2>&1) | Out-String
        $out = $out.Trim()
        if ($LASTEXITCODE -eq 0) {
            if ([string]::IsNullOrWhiteSpace($out)) { $out = 'ok' }
            Ok "$($c.Name): $out"
        } else {
            Warn "$($c.Name) FAILED:`n$out"
            $allOk = $false
        }
    }
    return $allOk
}

# =========================================================================
#  Facility selection (first step) - decides which APIs get installed
# =========================================================================
#   pylink: MRI, MEG, EEG, Eye Tracking      VPixx: MEG only      neither: TMS, Testing
$facilityLabel = [ordered]@{
    mri = 'MRI Facility'; meg = 'MEG Lab'; eeg = 'EEG Lab'
    eyetracking = 'Eye Tracking Lab'; tms = 'TMS Lab'; testing = 'Testing Room'
}
# Only relevant for installs; an explicit uninstall mode skips this prompt.
$needsFacility = $Mode -in @('ask', 'conda', 'standalone')

if ($needsFacility -and $Facility -eq 'ask') {
    Write-Host ""
    Write-Host "Which Scully facility are you installing PsychoPy at?" -ForegroundColor Magenta
    Write-Host "  [1] MRI Facility"
    Write-Host "  [2] MEG Lab"
    Write-Host "  [3] EEG Lab"
    Write-Host "  [4] Eye Tracking Lab"
    Write-Host "  [5] TMS Lab"
    Write-Host "  [6] Testing Room"
    do { $fsel = Read-Host "Enter 1-6" } while ($fsel -notin '1', '2', '3', '4', '5', '6')
    $Facility = switch ($fsel) {
        '1' { 'mri' }
        '2' { 'meg' }
        '3' { 'eeg' }
        '4' { 'eyetracking' }
        '5' { 'tms' }
        '6' { 'testing' }
    }
}

# pylink at MRI/MEG/EEG/Eye Tracking; VPixx only at MEG; neither at TMS/Testing Room.
$InstallPylink = $Facility -in @('mri', 'meg', 'eeg', 'eyetracking')
$InstallVpixx  = $Facility -eq 'meg'
if ($needsFacility) {
    Info "Facility: $($facilityLabel[$Facility])  (pylink: $(if ($InstallPylink) {'yes'} else {'no'}), VPixx: $(if ($InstallVpixx) {'yes'} else {'no'}))"
}

# Desired PsychoPy version (blank/'latest' = newest available).
if ($needsFacility -and $PsychopyVersion -eq 'ask') {
    Write-Host ""
    $v = Read-Host "PsychoPy version to install (e.g. 2024.2.4) - leave blank for the latest"
    $PsychopyVersion = if ([string]::IsNullOrWhiteSpace($v)) { 'latest' } else { $v.Trim() }
}
if ($needsFacility) { Info "PsychoPy version: $PsychopyVersion" }

# =========================================================================
#  Action selection
# =========================================================================
if ($Mode -eq 'ask') {
    Write-Host ""
    Write-Host "What would you like to do?" -ForegroundColor Magenta
    Write-Host "  [1] Install - Conda environment   (no admin needed)"
    Write-Host "  [2] Install - Standalone app      (downloads the latest StandalonePsychoPy from GitHub)"
    Write-Host "  [3] Uninstall - delete the '$EnvName' conda environment"
    Write-Host "  [4] Uninstall - remove the Standalone PsychoPy app"
    do { $sel = Read-Host "Enter 1, 2, 3 or 4" } while ($sel -notin '1', '2', '3', '4')
    $Mode = switch ($sel) {
        '1' { 'conda' }
        '2' { 'standalone' }
        '3' { 'uninstall-conda' }
        '4' { 'uninstall-standalone' }
    }
}
Info "Mode: $Mode"

# =========================================================================
#  CONDA MODE
# =========================================================================
if ($Mode -eq 'conda') {

    $Conda = Get-CondaExe -Prefix $MinicondaPath
    if (-not $Conda -and $UseExistingConda) {
        $cmd = Get-Command conda -ErrorAction SilentlyContinue
        if ($cmd) { $Conda = $cmd.Source; Info "Using existing conda on PATH: $Conda" }
    }

    if (-not $Conda) {
        Info "No conda found. Installing per-user Miniconda to: $MinicondaPath"
        if (Test-Path $MinicondaPath) {
            Die "Target '$MinicondaPath' exists but has no conda.exe. Remove it or pass a different -MinicondaPath."
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $url       = 'https://repo.anaconda.com/miniconda/Miniconda3-latest-Windows-x86_64.exe'
        $installer = Join-Path $env:TEMP 'Miniconda3-latest-Windows-x86_64.exe'
        Info "Downloading Miniconda installer..."
        $ProgressPreference = 'SilentlyContinue'   # IWR is far faster without the progress bar
        try { Invoke-WebRequest -Uri $url -OutFile $installer }
        catch { Die "Download failed: $($_.Exception.Message)" }

        # NSIS: /D (install dir) MUST be last and unquoted; spaces are fine. JustMe = no admin.
        Info "Running silent install (takes a minute)..."
        $argLine = "/S /InstallationType=JustMe /RegisterPython=0 /AddToPath=0 /D=$MinicondaPath"
        $proc = Start-Process -FilePath $installer -ArgumentList $argLine -Wait -PassThru
        if ($proc.ExitCode -ne 0) { Die "Miniconda installer exited with code $($proc.ExitCode)." }
        Remove-Item $installer -ErrorAction SilentlyContinue
        $Conda = Get-CondaExe -Prefix $MinicondaPath
        if (-not $Conda) { Die "Install finished but conda.exe not found under $MinicondaPath." }
        Ok "Miniconda installed."
    }

    Info "conda: $Conda"
    $condaBase = (& $Conda info --base).Trim()

    # Create / reuse env
    $envList   = & $Conda env list
    $envExists = ($envList -match "^\s*$([regex]::Escape($EnvName))\s")
    if ($envExists -and $Force) {
        Warn "Env '$EnvName' exists - removing it (-Force)."
        & $Conda env remove -n $EnvName -y | Out-Null
        $envExists = $false
    }
    if ($envExists) {
        Warn "Env '$EnvName' already exists; reusing it. Pass -Force to recreate."
    } else {
        Info "Creating conda env '$EnvName' (python=$PyVersion)..."
        # Build from conda-forge with --override-channels: avoids the Anaconda default-channel
        # Terms-of-Service gate (CondaToSNonInteractiveError) and Anaconda's commercial-use
        # licensing on repo.anaconda.com/pkgs/*. PsychoPy etc. come from pip regardless.
        & $Conda create -n $EnvName -c conda-forge --override-channels "python=$PyVersion" pip -y
        if ($LASTEXITCODE -ne 0) {
            Die "conda create failed. If this is an Anaconda Terms-of-Service error, either re-run (this build uses conda-forge and should avoid it), or accept the ToS:`n  & `"$Conda`" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main"
        }
    }

    # Resolve env python (may live under <base>\envs or %USERPROFILE%\.conda\envs)
    $envPython = $null
    foreach ($t in @(
        (Join-Path $condaBase "envs\$EnvName\python.exe"),
        (Join-Path $env:USERPROFILE ".conda\envs\$EnvName\python.exe")
    )) { if (Test-Path $t) { $envPython = $t; break } }
    if (-not $envPython) {
        foreach ($line in (& $Conda env list)) {
            if ($line -match '^\s*#') { continue }
            $cols = $line -split '\s+' | Where-Object { $_ -ne '' -and $_ -ne '*' }
            if ($cols.Count -ge 2) {
                $p = $cols[-1]
                if ((Split-Path $p -Leaf) -ieq $EnvName) {
                    $cand = Join-Path $p 'python.exe'
                    if (Test-Path $cand) { $envPython = $cand; break }
                }
            }
        }
    }
    if (-not $envPython) { Die "Could not locate python.exe for env '$EnvName'." }
    Info "Env python: $envPython"

    # PsychoPy itself
    Info "Upgrading pip and installing PsychoPy (a few minutes)..."
    Ensure-Pip $envPython
    PipInto $envPython install --upgrade pip
    if ($PsychopyVersion -eq 'latest') {
        PipInto $envPython install --upgrade psychopy
    } else {
        PipInto $envPython install "psychopy==$PsychopyVersion"
    }

    # APIs
    $pt = -not $SkipPsychtoolbox
    $ok = Install-Apis -Python $envPython -InstallVpixx $InstallVpixx -InstallPylink $InstallPylink -InstallPsychtoolbox $pt -VerifyPsychtoolbox $pt

    Write-Host ""
    if (-not $ok) { Warn "Finished with one or more failures (see above)."; exit 2 }
    Ok "All packages verified."
    Info "Registering conda for this user (conda init powershell)..."
    & $Conda init powershell | Out-Null

    # conda init writes a hook into your PowerShell profile, but a Restricted execution
    # policy prevents the profile from running - so `conda` isn't found in new shells.
    # We were launched with -ExecutionPolicy Bypass, which only affects THIS process, so
    # we must check/set the persistent CurrentUser scope explicitly (no admin needed).
    $cuPolicy = Get-ExecutionPolicy -Scope CurrentUser
    if ($cuPolicy -notin @('RemoteSigned', 'Unrestricted', 'Bypass')) {
        try {
            Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force
            Ok "Set PowerShell execution policy (CurrentUser) to RemoteSigned."
        } catch {
            Warn "Could not set execution policy: $($_.Exception.Message)"
        }
    }
    # Will a fresh, normal PowerShell run the profile? Group Policy (Machine/User scope)
    # can override CurrentUser and can't be changed without admin.
    $activationWorks = (Get-PersistentExecPolicy) -notin @('Restricted', 'AllSigned')

    # Locate the GUI launcher pip created (usually psychopy.exe in the env's Scripts dir).
    $scriptsDir = Join-Path (Split-Path $envPython) 'Scripts'
    $appExe = Join-Path $scriptsDir 'psychopy.exe'
    if (-not (Test-Path $appExe)) {
        $hit = Get-ChildItem -Path $scriptsDir -Filter 'psychopy*.exe' -ErrorAction SilentlyContinue |
               Sort-Object Name | Select-Object -First 1
        if ($hit) { $appExe = $hit.FullName }
    }

    # Create a one-click Desktop shortcut - no shell, no activation, immune to exec policy.
    $shortcut = $null
    if (Test-Path $appExe) {
        try {
            $desktop = [Environment]::GetFolderPath('Desktop')
            $shortcut = Join-Path $desktop 'PsychoPy (psychopy env).lnk'
            $wsh = New-Object -ComObject WScript.Shell
            $lnk = $wsh.CreateShortcut($shortcut)
            $lnk.TargetPath       = $appExe
            $lnk.WorkingDirectory = $scriptsDir
            $lnk.IconLocation     = $appExe
            $lnk.Description       = "PsychoPy ($EnvName conda env)"
            $lnk.Save()
            Ok "Created Desktop shortcut: $shortcut"
        } catch {
            Warn "Could not create Desktop shortcut: $($_.Exception.Message)"
            $shortcut = $null
        }
    }

    Write-Host ""
    Ok "Done."
    if ($shortcut) {
        Write-Host "  Easiest: double-click the 'PsychoPy' icon on the Desktop." -ForegroundColor Green
    }
    if ($activationWorks) {
        Write-Host "  Or from a NEW PowerShell window:" -ForegroundColor Green
        Write-Host "    conda activate $EnvName" -ForegroundColor Green
        Write-Host "    psychopy                       # Coder/Builder GUI" -ForegroundColor Green
    } else {
        Warn "'conda activate' won't work in a plain PowerShell here (execution policy is"
        Warn "enforced by IT/Group Policy). Use the Desktop icon, the Anaconda PowerShell"
        Warn "Prompt, or launch directly:"
        Write-Host "    & `"$appExe`"" -ForegroundColor Green
    }
    Write-Host "  Run a script directly (always works):" -ForegroundColor DarkGray
    Write-Host "    & `"$envPython`" your_experiment.py" -ForegroundColor DarkGray
    exit 0
}

# =========================================================================
#  STANDALONE MODE
# =========================================================================
if ($Mode -eq 'standalone') {

    $targetPython = $null
    if (-not $Force) {
        $targetPython = Find-StandalonePython -Hint $StandaloneDir
        if ($targetPython) {
            Info "Found existing Standalone PsychoPy: $targetPython"
            if ($PsychopyVersion -ne 'latest') {
                Warn "Reusing this install - it may not be version $PsychopyVersion. Use -Force to download and reinstall that version."
            }
        }
    }

    if (-not $targetPython) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $hdr = @{ 'User-Agent' = 'psychopy-installer' }
        $verLabel = if ($PsychopyVersion -eq 'latest') { 'the latest release' } else { "release $PsychopyVersion" }
        Info "Querying PsychoPy GitHub for $verLabel..."
        try { $rel = Get-PsychopyRelease -Version $PsychopyVersion -Hdr $hdr }
        catch { Die "Could not find PsychoPy '$PsychopyVersion' on GitHub: $($_.Exception.Message)" }
        if (-not $rel) { Die "No PsychoPy release with a Windows installer found for '$PsychopyVersion'." }

        $exes = @($rel.assets | Where-Object { $_.name -match 'win64.*\.exe$' })
        if (-not $exes) { Die "No win64 .exe in release $($rel.tag_name)." }
        # Asset names look like StandalonePsychoPy-2025.2.3-win64-3.10.exe (or -py3.8).
        $asset = $exes | Where-Object { $_.name -match ('(py)?' + [regex]::Escape($PyVersion)) } | Select-Object -First 1
        if (-not $asset) {
            $asset = $exes | Select-Object -First 1
            Warn "No win64 build matching Python $PyVersion; using $($asset.name)."
        }
        $sizeMB = [math]::Round($asset.size / 1MB)
        Info "Selected: $($asset.name)  ($sizeMB MB, release $($rel.tag_name))"

        $installer = Join-Path $env:TEMP $asset.name
        Info "Downloading..."
        $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $installer }
        catch { Die "Download failed: $($_.Exception.Message)" }

        Write-Host ""
        Warn "The PsychoPy installer window will open now."
        Warn "WITHOUT admin rights, install to a user-writable location (e.g. under your"
        Warn "user folder) - NOT 'Program Files' - or the API wiring step can't write to it."
        Write-Host ""
        Info "Launching installer. Finish it, then return to this window..."
        Start-Process -FilePath $installer -Wait
        Remove-Item $installer -ErrorAction SilentlyContinue

        $targetPython = Find-StandalonePython -Hint $StandaloneDir
        if (-not $targetPython) {
            $manual = Read-Host "Could not auto-locate the install. Enter the PsychoPy install folder (blank to abort)"
            if ($manual) { $targetPython = Find-StandalonePython -Hint $manual }
        }
        if (-not $targetPython) { Die "Standalone python.exe not found. Re-run with -StandaloneDir '<folder>'." }
        Ok "Standalone PsychoPy located: $targetPython"
    }

    # Standalone bundles psychtoolbox, so don't reinstall it - just verify it's importable.
    $ok = Install-Apis -Python $targetPython -InstallVpixx $InstallVpixx -InstallPylink $InstallPylink -InstallPsychtoolbox $false -VerifyPsychtoolbox $true

    Write-Host ""
    if (-not $ok) { Warn "Finished with one or more failures (see above)."; exit 2 }
    Ok "All packages verified."
    Write-Host ""
    Ok "Done. PsychoPy Standalone now has pylink + pypixxlib wired in."
    Write-Host "  - Launch PsychoPy from the Start Menu to use Builder/Coder." -ForegroundColor Green
    Write-Host "  - Run a script with its bundled Python:" -ForegroundColor DarkGray
    Write-Host "      & `"$targetPython`" your_experiment.py" -ForegroundColor DarkGray
    exit 0
}

# =========================================================================
#  UNINSTALL - CONDA ENV
# =========================================================================
if ($Mode -eq 'uninstall-conda') {

    if (-not $Force) {
        $c = Read-Host "Delete the conda environment '$EnvName'? This cannot be undone. [y/N]"
        if ($c -notmatch '^(y|yes)$') { Info "Cancelled."; exit 0 }
    }

    $Conda = Resolve-AnyConda
    if ($Conda) {
        Info "Removing conda env '$EnvName' via $Conda ..."
        & $Conda env remove -n $EnvName -y
    } else {
        Warn "conda not found; will try to delete the env folder(s) directly."
    }

    # Delete any leftover env folder (covers both common locations).
    foreach ($p in @(
        (Join-Path $MinicondaPath "envs\$EnvName"),
        (Join-Path $env:USERPROFILE ".conda\envs\$EnvName")
    )) {
        if (Test-Path $p) {
            Info "Deleting leftover folder: $p"
            Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Remove the Desktop shortcut this script may have created.
    $sc = Join-Path ([Environment]::GetFolderPath('Desktop')) 'PsychoPy (psychopy env).lnk'
    if (Test-Path $sc) {
        Remove-Item -LiteralPath $sc -Force -ErrorAction SilentlyContinue
        Ok "Removed Desktop shortcut."
    }

    Write-Host ""
    Ok "Done. The conda environment '$EnvName' has been removed."
    Info "Miniconda itself ($MinicondaPath) was left in place."
    exit 0
}

# =========================================================================
#  UNINSTALL - STANDALONE APP
# =========================================================================
if ($Mode -eq 'uninstall-standalone') {

    # Find PsychoPy entries in the Windows uninstall registry (per-user + machine).
    $keys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $entries = @()
    foreach ($k in $keys) {
        if (Test-Path $k) {
            $entries += Get-ChildItem $k -ErrorAction SilentlyContinue |
                        ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
                        Where-Object { $_.DisplayName -like '*PsychoPy*' }
        }
    }

    if ($entries) {
        $names = ($entries | ForEach-Object { $_.DisplayName }) -join ', '
        if (-not $Force) {
            $c = Read-Host "Uninstall the following? [$names]  [y/N]"
            if ($c -notmatch '^(y|yes)$') { Info "Cancelled."; exit 0 }
        }
        foreach ($e in $entries) {
            $u = $e.UninstallString
            if (-not $u) { Warn "No uninstall string for $($e.DisplayName); skipping."; continue }
            # UninstallString is usually a quoted path to the uninstaller (e.g. unins000.exe).
            if ($u -match '^\s*"([^"]+)"\s*(.*)$') {
                $exe = $Matches[1]; $rest = $Matches[2]
            } else {
                $i = $u.IndexOf(' ')
                if ($i -gt 0) { $exe = $u.Substring(0, $i); $rest = $u.Substring($i + 1) }
                else          { $exe = $u; $rest = '' }
            }
            if (-not (Test-Path $exe)) { Warn "Uninstaller not found at: $exe"; continue }
            Info "Running uninstaller for $($e.DisplayName)..."
            if ($rest.Trim()) { Start-Process -FilePath $exe -ArgumentList $rest -Wait }
            else              { Start-Process -FilePath $exe -Wait }
            Ok "Uninstaller finished for $($e.DisplayName)."
        }
        Write-Host ""
        Ok "Done."
        exit 0
    }

    # No registry entry - fall back to locating the install folder and deleting it.
    Warn "No 'PsychoPy' entry found in the uninstall registry."
    $py = Find-StandalonePython -Hint $StandaloneDir
    if ($py) {
        $root = Split-Path $py
        $parent = Split-Path $root
        if ((Split-Path $parent -Leaf) -ieq 'PsychoPy') { $root = $parent }
    } else {
        $manual = Read-Host "Enter the PsychoPy install folder to delete (blank to abort)"
        if (-not $manual) { Info "Nothing to do."; exit 0 }
        $root = $manual
    }
    if (-not (Test-Path $root)) { Die "Folder not found: $root" }
    Warn "This will delete the folder: $root"
    Warn "(Folder delete only - any Start Menu shortcuts / registry entries may remain.)"
    if (-not $Force) {
        $c = Read-Host "Proceed? [y/N]"
        if ($c -notmatch '^(y|yes)$') { Info "Cancelled."; exit 0 }
    }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path $root) { Die "Could not fully delete $root (files may be in use, or need admin)." }
    Ok "Deleted $root."
    exit 0
}
