# S-CORE workspace

Local workspace for Eclipse S-CORE with the diagnostics stack, cross-built for Raspberry Pi (aarch64) and runnable under QEMU.

## Layout

| Path | What it is |
|---|---|
| `inc_diagnostics/` | Diagnostics stack: UDS/DTC middleware (`score/mw/diag`), OpenSOVD gateway, classic diagnostic adapter, SOVD client. Bazel module `score_diagnostics`. |
| `reference_integration/` | Full S-CORE Bazel integration (baselibs, communication, persistency, ...). Has `linux-aarch64`, QNX and AutoSD configs. Not built yet. |
| `score/` | Docs and process repo. Nothing to build. |
| `dev.sh`, `Dockerfile` | Build environment wrapper (see below). |

The three repos are shallow clones (`--depth 1`). `inc_diagnostics` has local, uncommitted changes: an aarch64 GCC toolchain in `MODULE.bazel` and a `score_diag_aarch64_linux` config in `.bazelrc`.

## Build environment

The hermetic toolchains (GCC 12.2, Ferrocene Rust) only run on x86_64 Linux. `dev.sh` runs the official S-CORE devcontainer as `linux/amd64` in Docker, so it is emulated and slow on Apple Silicon. The Bazel cache lives in the Docker volume `score-bazel-cache`.

Requirements: Docker Desktop with at least 8 GB RAM.

## Commands

```sh
./dev.sh pi                                         # cross-build for Raspberry Pi (first run ~15 min)
./dev.sh qemu score/mw/diag/future_test             # run one aarch64 binary under qemu-user
./dev.sh qemu score/opensovd-core/opensovd-gateway  # gateway listens on 127.0.0.1:7690
./dev.sh qemu-test                                  # run all aarch64 C++ unit tests under qemu-user
./dev.sh                                            # shell in inc_diagnostics/ inside the container
./dev.sh reference_integration <cmd>                # run any command in another repo
```

Paths after `qemu` are relative to `inc_diagnostics/bazel-bin/`.

## Deploying to a Raspberry Pi

Copy `opensovd-gateway`, `opensovd-cda` and `sovd-client` from `inc_diagnostics/bazel-bin/` to a Pi running 64-bit Raspberry Pi OS (glibc 2.31 or newer).

## Notes

- QEMU here means user-mode emulation against the build's own sysroot, not a full VM. `qemu-system-aarch64` is in the image if you want to boot one.
- The Rust tests and integration tests have not been run.
- Diagnostics is not yet listed in `reference_integration/known_good.json`.
