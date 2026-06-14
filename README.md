# PsychoPy + VPixx + EyeLink — automated setup for Scully MEG Lab

Installs **PsychoPy** plus the **VPixx `pypixxlib`** and **SR Research EyeLink `pylink`**
Python APIs, then verifies every import. You pick one of two modes when you run it:

- **Conda environment** — no admin needed; installs a per-user Miniconda if required.
  Recommended on a shared PC / non-admin account. Also installs `psychtoolbox`.
- **Standalone app** — downloads the latest StandalonePsychoPy installer from PsychoPy's
  GitHub releases, runs it, then wires the VPixx and EyeLink APIs into the app's bundled
  Python. (Standalone already ships psychtoolbox.)

## Quick start

From PowerShell, in the folder containing the script:

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-PsychoPy.ps1
```

It will ask which mode you want (1 = conda, 2 = standalone). To skip the prompt:

```powershell
.\Install-PsychoPy.ps1 -Mode conda
.\Install-PsychoPy.ps1 -Mode standalone
```

In both modes the VPixx tarball and the EyeLink folder are auto-detected.

## Prerequisites (Windows)

1. **VPixx Software Tools** installed — provides `pypixxlib-<ver>.tar.gz` under
   `C:\Program Files\VPixx Technologies\...`.
2. **EyeLink Developers Kit** installed — provides the pylink package under
   `C:\Program Files (x86)\SR Research\EyeLink\SampleExperiments\Python\64\<pyver>\`.
3. **Internet access** — for the Miniconda / Standalone download and the pip installs.

No admin rights are required for conda mode. The vendor packages live in `Program Files`
(shared across accounts); the script only wires their Python bindings into the target
interpreter.

## Mode 1 — Conda environment

What it does:

0. If conda isn't present, silently installs a per-user **Miniconda** ("Just Me") to
   `%USERPROFILE%\miniconda3` — no admin prompt, no PATH/registry changes for other users.
1. `conda create -n psychopy python=3.10` (reuses an existing env unless `-Force`).
2. `pip install --upgrade psychopy`.
3. Installs `pypixxlib-<ver>.tar.gz`.
4. Writes a **BOM-free** `pylink.pth` into the env's `site-packages` pointing at the
   EyeLink folder that matches the env's Python version.
5. Installs `psychtoolbox` (skip with `-SkipPsychtoolbox`).
6. Verifies `psychopy`, `pylink`, `pypixxlib`, `psychtoolbox`, then runs
   `conda init powershell` so activation works.

When it finishes, **open a new PowerShell window**:

```powershell
conda activate psychopy
psychopy            # Coder/Builder GUI
```

(The new window is needed because `conda init` only affects shells started afterward.)

## Mode 2 — Standalone app

What it does:

1. Queries PsychoPy's GitHub releases for the latest `StandalonePsychoPy-…-win64-<pyver>.exe`
   and downloads it.
2. Launches the installer **interactively** so you choose the install location.
3. Locates the app's bundled Python, installs `pypixxlib`, writes the `pylink.pth`, and
   verifies imports (psychtoolbox is already bundled).

After it finishes, launch PsychoPy from the Start Menu — pylink and pypixxlib are
available inside Builder/Coder.

> **No admin? Install to a user-writable folder.** The standalone installer defaults to
> `Program Files`, which needs admin — and wiring the APIs in means *writing into the app's
> `site-packages`*, which also needs write access there. Without admin, pick a location
> under your user folder during the installer step. If PsychoPy ends up somewhere the
> script can't write, it will tell you, and you can reinstall to a user-writable path.
> On a non-admin account, **conda mode is the smoother choice.**

If auto-detection misses the install, re-run with `-StandaloneDir "<folder>"`.

## Same PC, different user account

The new account runs the **same script with no changes** — VPixx and EyeLink live under
`C:\Program Files (x86)\...`, identical for every user.

- **Conda mode, no admin:** the script installs a per-user Miniconda and builds this
  account's own `psychopy` env (envs are per-user, not shared). Pass `-UseExistingConda`
  to reuse a conda already on PATH.
- **Standalone mode, no admin:** install PsychoPy to a user-writable folder (see the note
  above) so the API wiring can write into its `site-packages`.

## Options

| Flag | Purpose |
|------|---------|
| `-Mode <conda\|standalone>` | Skip the interactive prompt. |
| `-EnvName <name>` | Conda env name (default `psychopy`). |
| `-PyVersion <x.y>` | Python version for the env / the Standalone build to pick (default `3.10`). |
| `-MinicondaPath <path>` | Where to install/find the per-user Miniconda (default `%USERPROFILE%\miniconda3`). |
| `-StandaloneDir <path>` | Existing PsychoPy install folder (standalone mode). |
| `-UseExistingConda` | Use a conda already on PATH instead of installing Miniconda. |
| `-VpixxTarball <path>` | Explicit path to `pypixxlib-*.tar.gz` if auto-detect misses. |
| `-PylinkDir <path>` | Explicit path to `...\Python\64\<ver>` (the folder containing `pylink`). |
| `-SkipPsychtoolbox` | Conda mode: don't install psychtoolbox. |
| `-Force` | Conda: recreate the env. Standalone: re-download/reinstall even if one is found. |

Example with explicit paths (conda mode):

```powershell
.\Install-PsychoPy.ps1 -Mode conda `
  -VpixxTarball "C:\Program Files\VPixx Technologies\Software Tools\pypixxlib\pypixxlib-1.11.3.tar.gz" `
  -PylinkDir "C:\Program Files (x86)\SR Research\EyeLink\SampleExperiments\Python\64\3.10" `
  -Force
```

## Two gotchas from the manual version (handled here)

- **Smart quotes.** The manual `pip install "…tarball…"` line is easy to paste with curly
  quotes (`“ ”`), which the shell won't accept. The script avoids this entirely.
- **The `.pth` file.** Writing it with `echo … > pylink.pth` can leave a trailing space
  and/or a UTF-8 BOM on the first line, which Python's `site.py` mis-parses so `pylink`
  silently won't import. The script writes it as UTF-8 **without a BOM**, forward-slashed.

## Troubleshooting

- **Download fails** — the PC needs internet access (`repo.anaconda.com` for Miniconda,
  `github.com` for Standalone). Behind a proxy/firewall: for conda, install Miniconda
  manually and use `-UseExistingConda`; for standalone, install PsychoPy yourself and
  re-run with `-StandaloneDir`.
- **`pip … failed (target location may be read-only)`** (standalone) — PsychoPy is in a
  folder you can't write to (usually `Program Files`). Reinstall it to a user-writable
  location and re-run.
- **VPixx/pylink "skipped"** — the vendor software isn't where expected, or it's a
  different Python version. Pass `-VpixxTarball` / `-PylinkDir`. The pylink folder must
  match the target interpreter's Python version (e.g. a 3.10 env → the `...\64\3.10` folder).
- **`pylink` still won't import** — confirm `pylink.pth` exists in the target's
  `site-packages` and that the path inside points to the folder that *contains* `pylink\`
  (not to `pylink\` itself).
- **PsychoPy wxPython errors on install** (conda) — rare on 3.10/Windows; if it happens,
  `conda install -n psychopy -c conda-forge wxpython` then re-run.
