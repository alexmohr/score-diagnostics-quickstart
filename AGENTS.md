# AGENTS.md

Guidance for coding agents working in this workspace. See `README.md` for the overview.

## Layout

- The workspace root is **not** a git repo. `inc_diagnostics/`, `reference_integration/` and `score/` are separate shallow clones, each with its own `.git`. Run git commands inside the repo you are changing.
- `inc_diagnostics/` is the main working repo (Bazel module `score_diagnostics`, Bazel 8.8.2).
- `reference_integration/` is the full S-CORE integration. Read it for reference configs (`.bazelrc`, `bazel_common/*.MODULE.bazel`). It has not been built here.
- `score/` is docs only.
- Local, uncommitted changes in `inc_diagnostics/`: the aarch64 toolchain in `MODULE.bazel` and the `score_diag_aarch64_linux` config in `.bazelrc`. Do not revert them.

## Building and running

- **Never run Bazel on the macOS host.** The hermetic toolchains are x86_64 Linux only. Use `./dev.sh`, which runs the devcontainer as `linux/amd64` (emulated, slow).
- `./dev.sh <repo> <cmd...>` runs any command in a repo inside the container. `./dev.sh pi` cross-builds for Raspberry Pi. `./dev.sh qemu <path under bazel-bin> [args]` runs one aarch64 binary. `./dev.sh qemu-test` runs all aarch64 C++ unit tests.
- Build config: `--config=score_diag_aarch64_linux` (Pi) or `--config=score_diag_x86_64_linux`.
- The Bazel cache is in the Docker volume `score-bazel-cache`. The first full build takes about 15 minutes and later builds are incremental. Run long builds in the background and redirect output to a log file.
- Bazel prints very long progress output. Read only the tail (`tail -40`).

## Gotchas

- `bazel-out/k8-fastbuild` is the output directory name even for aarch64 builds, so it does not show the target architecture. Check an ELF header instead: `od -An -tx1 -j18 -N2 <bin>` gives `b7 00` for aarch64 and `3e 00` for x86_64. The image also has `file`.
- `bazel query` must be run without `--config`. Do not add `2>/dev/null` to hide errors while debugging.
- QEMU here is user-mode (`qemu-aarch64 -L <sysroot>`), using the sysroot of the Bazel GCC aarch64 toolchain. It is not a full VM.
- `opensovd-gateway` has no `--help`. It starts a server on `127.0.0.1:7690`, so wrap it in `timeout`.
- Rust crates for QNX targets are disabled in the shared crate index. Do not re-add them.
- Some Rust build scripts (for example `aws-lc-sys`) produce huge stderr that Bazel skips. This is not an error.

## Conventions

- C++17 with strict warnings. Warnings are errors for this repo's own sources, not for external code.
- Source files carry the Eclipse copyright header, and `//:copyright` checks it.
- Use `buildifier` formatting for Bazel files.
- Dependencies come from the S-CORE registry: `https://raw.githubusercontent.com/eclipse-score/bazel_registry/main/`.

## Git

- Prefix every git command with `GIT_MASTER=1` and load the `git-master` skill first.
- Run the `commit-pr-checks` agent before treating a commit as final.
- Do not commit or push without being asked.

## Useful skills

`uds`, `sovd`, `doip` and `odx` hold the diagnostics standards references (ISO 14229, 17978, 13400, 22901).
