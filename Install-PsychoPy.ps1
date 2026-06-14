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
    'conda', 'standalone', or 'ask' (default - prompts interactively).

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
    .\Install-PsychoPy.ps1 -Mode conda -VpixxTarball "C:\Tools\pypixxlib-1.11.3.tar.gz" -Force

.NOTES
    Windows / PowerShell only. No admin needed for conda mode. Standalone mode needs a
    user-writable install location for the API wiring to succeed (see INSTRUCTIONS.md).
#>

[CmdletBinding()]
param(
    [ValidateSet('conda','standalone','ask')]
    [string]$Mode           = 'ask',
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

Write-Host "=== PsychoPy / VPixx / EyeLink installer ===" -ForegroundColor Magenta

# =========================================================================
#  Shared helpers
# =========================================================================

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

# Installs VPixx + pylink (+ optional psychtoolbox) into a given Python interpreter,
# then verifies imports. Returns $true if everything verified.
function Install-Apis {
    param(
        [string]$Python,
        [bool]$InstallPsychtoolbox,
        [bool]$VerifyPsychtoolbox
    )

    # Make sure this interpreter has pip.
    & $Python -m pip --version 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Info "Bootstrapping pip (ensurepip)..."
        & $Python -m ensurepip --upgrade | Out-Null
    }

    $effPy = (& $Python -c "import sys; print('%d.%d' % sys.version_info[:2])").Trim()
    Info "Target interpreter: $Python  (Python $effPy)"

    # --- VPixx pypixxlib ---
    $vp = if ($VpixxTarball) { $VpixxTarball } else { Find-VpixxTarball }
    if ($vp) {
        if (-not (Test-Path $vp)) { Die "VPixx tarball not found: $vp" }
        Info "Installing pypixxlib from: $vp"
        PipInto $Python install $vp
        Ok "pypixxlib installed"
    } else {
        Warn "VPixx tarball not found; pass -VpixxTarball '<path>'. Skipping VPixx."
    }

    # --- EyeLink pylink (.pth pointing at the SR Research folder for this Python) ---
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
    }

    # --- psychtoolbox (conda mode only; Standalone bundles it) ---
    if ($InstallPsychtoolbox) {
        Info "Installing psychtoolbox (low-latency audio)..."
        PipInto $Python install psychtoolbox
        Ok "psychtoolbox installed"
    }

    # --- Verify ---
    Info "Verifying imports..."
    $checks = @(
        @{ Name = 'PsychoPy';   Code = 'import psychopy; print(psychopy.__version__)' },
        @{ Name = 'pylink';     Code = 'import pylink; print(pylink.__file__)' },
        @{ Name = 'pypixxlib';  Code = 'from pypixxlib import _libdpx' }
    )
    if ($VerifyPsychtoolbox) { $checks += @{ Name = 'psychtoolbox'; Code = 'import psychtoolbox' } }

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
#  Mode selection
# =========================================================================
if ($Mode -eq 'ask') {
    Write-Host ""
    Write-Host "How would you like to install PsychoPy?" -ForegroundColor Magenta
    Write-Host "  [1] Conda environment   - no admin needed (recommended on this PC)"
    Write-Host "  [2] Standalone app      - downloads the latest StandalonePsychoPy from GitHub"
    do { $sel = Read-Host "Enter 1 or 2" } while ($sel -notin '1', '2')
    $Mode = if ($sel -eq '1') { 'conda' } else { 'standalone' }
}
Info "Mode: $Mode"

# =========================================================================
#  CONDA MODE
# =========================================================================
if ($Mode -eq 'conda') {

    function Get-CondaExe {
        param([string]$Prefix)
        $exe = Join-Path $Prefix 'Scripts\conda.exe'
        if (Test-Path $exe) { return $exe }
        return $null
    }

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
        & $Conda create -n $EnvName "python=$PyVersion" -y
        if ($LASTEXITCODE -ne 0) { Die "conda create failed." }
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
    PipInto $envPython install --upgrade pip
    PipInto $envPython install --upgrade psychopy

    # APIs
    $pt = -not $SkipPsychtoolbox
    $ok = Install-Apis -Python $envPython -InstallPsychtoolbox $pt -VerifyPsychtoolbox $pt

    Write-Host ""
    if (-not $ok) { Warn "Finished with one or more failures (see above)."; exit 2 }
    Ok "All packages verified."
    Info "Registering conda for this user (conda init powershell)..."
    & $Conda init powershell | Out-Null
    Write-Host ""
    Ok "Done. To use it:"
    Write-Host "    1. Open a NEW PowerShell window."          -ForegroundColor Green
    Write-Host "    2. conda activate $EnvName"                 -ForegroundColor Green
    Write-Host "    3. psychopy            # Coder/Builder GUI" -ForegroundColor Green
    Write-Host "  Run a script directly:" -ForegroundColor DarkGray
    Write-Host "    & `"$envPython`" your_experiment.py" -ForegroundColor DarkGray
    exit 0
}

# =========================================================================
#  STANDALONE MODE
# =========================================================================
if ($Mode -eq 'standalone') {

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

    $targetPython = $null
    if (-not $Force) {
        $targetPython = Find-StandalonePython -Hint $StandaloneDir
        if ($targetPython) { Info "Found existing Standalone PsychoPy: $targetPython" }
    }

    if (-not $targetPython) {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $hdr = @{ 'User-Agent' = 'psychopy-installer' }
        Info "Querying PsychoPy GitHub for the latest release..."
        try { $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/psychopy/psychopy/releases/latest' -Headers $hdr }
        catch { Die "Could not query GitHub releases: $($_.Exception.Message)" }

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
    $ok = Install-Apis -Python $targetPython -InstallPsychtoolbox $false -VerifyPsychtoolbox $true

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
