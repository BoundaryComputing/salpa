# Salpa

**A visual workflow platform for computational molecular science.** Build a pipeline by
connecting nodes on a canvas — no code — and keep the whole thing reproducible.

**Salpa runs on your own machine.** Your data, your workflow and your results stay there. When a
step needs more than your workstation, two routes out are built into the same canvas:

- **Your HPC cluster** — submit jobs to SLURM and collect the results back in the workflow.
- **[Salpa Compute](https://www.bocores.com/salpa-compute)** — run frontier open models for
  structure prediction, docking and genomics on managed GPUs. No cloud account, no setup, and free
  during the Technical Preview.

→ **[salpa.app](https://salpa.app)** · [Documentation](https://salpa.app/docs) · [Getting started](https://salpa.app/docs/getting-started)

**This repository is where Salpa is distributed** — downloads, release notes, and the issue
tracker. The application source is not kept here. Two related projects are developed in the open:

| | What | Where |
|---|---|---|
| **Salpa Hub** | First-party scientific node packages. Free. | [BoundaryComputing/salpa-hub](https://github.com/BoundaryComputing/salpa-hub) |
| **salpa-cli** | The node-authoring CLI — scaffold, validate and test your own nodes | [`pip install salpa-cli`](https://pypi.org/project/salpa-cli/) |

---

## Download

Get the latest build from **[Releases](https://github.com/BoundaryComputing/salpa/releases/latest)**.

| Platform | File |
|---|---|
| macOS — Apple Silicon (M1–M4) | `Salpa-<version>-arm64.dmg` |
| macOS — Intel | `Salpa-<version>-x64.dmg` |
| Linux — x64 | `Salpa-<version>.AppImage` |
| Windows — x64 | `Salpa-Setup-<version>.exe` |

No prerequisites. Salpa bundles its own Python environment and background services — you do not
need Python, pip, or conda installed.

## Install

Salpa is not yet code-signed on any platform, so each OS will warn you the first time. This is
expected for a Technical Preview; here is how to get past it.

**macOS** — open the DMG and drag Salpa to Applications. On first launch you may see
"unidentified developer". Either right-click the app and choose **Open**, or clear the quarantine
attribute:

```bash
xattr -cr /Applications/Salpa.app
```

**Linux** — make the AppImage executable and run it. FUSE is required:

```bash
chmod +x Salpa-*.AppImage
./Salpa-*.AppImage
# Ubuntu, if FUSE is missing:
sudo apt install libfuse2
```

**Windows** — run the installer. SmartScreen may warn about an unrecognized publisher; click
**More info** → **Run anyway**.

## First launch takes a few minutes

On first start Salpa builds its Python environment. This is a one-off; later launches are fast.
Roughly what to expect:

| Platform | First launch |
|---|---|
| macOS | 1–2 minutes |
| Windows | 5–15 minutes |
| Linux (AppImage) | 3–8 minutes — including a stretch with no visible progress while the AppImage mounts |

If it looks stuck, it is usually still working — give it the time above before assuming it has
failed.

On Windows, scientific packages such as GROMACS and pdb2pqr run through WSL2. If WSL is not set
up, open PowerShell as administrator, run `wsl --install -d Ubuntu-24.04`, and reboot before
launching Salpa.

## Something went wrong?

**[Open an issue](https://github.com/BoundaryComputing/salpa/issues/new/choose).** Installation and
first-launch problems are the ones we most want to hear about — they are the hardest for us to
reproduce and the easiest to fix once we can see them. Include your OS and version, and anything the
app managed to show you before it stopped.

You can also reach us at [hello@salpa.app](mailto:hello@salpa.app).

## Status

Salpa is a **Technical Preview**. It is usable and being used for real work, but expect rough
edges — unsigned binaries, long first launches, and features still landing. Please tell us what
breaks.

---

© Boundary Computing. Salpa is a product of [Boundary Computing](https://bocores.com).
