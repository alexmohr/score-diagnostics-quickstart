# AGENTS.md

Guidance for coding agents working in this workspace. See `README.md` for the overview.

## Layout

- The workspace root is a git repo. `reference_integration/`, `inc_diagnostics/` and `score/` are git submodules of the upstream `eclipse-score` repos. Run git commands inside the repo you are changing.
- `reference_integration/` is pinned to branch `feat/add-diagnostics` (draft PR eclipse-score/reference_integration#482). It deploys the OpenSOVD gateway and CDA from `inc_diagnostics` through `//deploy/diagnostics`, and adds them to `//deploy:platform_tar` only (QNX consumes `platform_bundle`).
- `inc_diagnostics/` is pinned to branch `consumable_by_reference_integration` (draft PR eclipse-score/inc_diagnostics#70). It is a Bazel module `score_diagnostics`; the source of truth for the diagnostics code.
- `reference_integration/` cannot be checked out completely on macOS (case collision between `BUILD` and `build/`). The host checkout is therefore incomplete. Build and edit it from the clone in the Docker volume `score-ref-int`, not from this directory.
- `score/` is docs only.

## Building and running

- **Never run Bazel on the macOS host.** The hermetic toolchains are x86_64 Linux only. `./dev.sh` runs the builds in the devcontainer as `linux/amd64` (emulated, slow).
- `./dev.sh build-pi`, `./dev.sh build-qemu` and `./dev.sh run-qemu` are the only commands. They build the clone in the volume at the commit the `reference_integration` submodule points to. A change to that repo only takes effect after it is pushed and the submodule pin is updated.
- Run long builds in the background with output redirected to a log file. `build-qemu` takes about 30 minutes the first time. Bazel prints very long progress output, so read only the tail.
- `./ecu-sim.sh up|test|down` runs the CDA ECU simulator in Docker and tests the CDA from `out/` against it. It clones the CDA at the commit `inc_diagnostics` pins into `out/cda-src`.
- `run-qemu` publishes the ports on `127.0.0.1` only, because the image allows passwordless root SSH. Do not publish them on all interfaces.
- The Bazel cache is in the Docker volume `score-bazel-cache`.

## Gotchas

- `bazel-out/k8-fastbuild` is the output directory name even for aarch64 builds. Check the ELF header instead: `od -An -tx1 -j18 -N2 <bin>` gives `b7 00` for aarch64 and `3e 00` for x86_64.
- The Pi build needs `gcc-aarch64-linux-gnu` and `libc6-dev-arm64-cross` (iceoryx2 bindgen reads the aarch64 glibc headers from the host). `dev.sh` adds them on top of the devcontainer.
- Bazel only honours `git_override` and patches in the root module, so `reference_integration` repeats the overrides and patches for `opensovd_core`, `classic-diagnostic-adapter` and `mbedtls-rs` (see `patches/diagnostics`). Those can go once eclipse-opensovd/opensovd-core#247 is done.
- `opensovd-gateway` has no `--help`. It starts a server on `127.0.0.1:7690`, so wrap it in `timeout`.
- QEMU runs without KVM or HVF here, so the VM is slow. The `[ELOSD]` errors in the boot log come from the base image.
- Some Rust build scripts (for example `aws-lc-sys`) produce huge stderr that Bazel skips. This is not an error.

## Git

- Prefix every git command with `GIT_MASTER=1` and load the `git-master` skill first.
- Run the `commit-pr-checks` agent before treating a commit as final. Commits need a sign-off.
- Pull requests to `eclipse-*` repositories use the Eclipse template and the contributor block that `commit-pr-checks` describes, with no AI attribution.
- Do not commit or push without being asked.

## Useful skills

`uds`, `sovd`, `doip` and `odx` hold the diagnostics standards references (ISO 14229, 17978, 13400, 22901).
