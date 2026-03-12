# Repository Guidelines

## Project Structure & Module Organization

Kuasar is a Rust workspace. Core runtime code lives in `vmm/`:
- `vmm/task`: guest-side task service and container IO handling
- `vmm/sandbox`: sandboxer and hypervisor integration
- `vmm/common`: shared APIs, tracing helpers, and utilities

Other runtimes live in `runc/`, `quark/`, `wasm/`, and `shim/`. End-to-end and benchmark assets are under `tests/`. Helper scripts and local tooling live in `scripts/` and `hack/`.

## Build, Test, and Development Commands

- `make vmm`: build the VMM sandboxer and guest artifacts
- `cargo build -p vmm-task`: build a single crate
- `cargo test -p vmm-task`: run task crate unit tests
- `make test-e2e-framework`: run the e2e framework without full service startup

For Linux-only crates, prefer a persistent Docker container instead of local macOS builds:

```bash
docker run -d --name kuasar-rust-1-85 \
  -v /Users/novahe/nova/kuasar/kuasar:/work -w /work \
  kuasar-build-test:1.85 tail -f /dev/null

docker exec kuasar-rust-1-85 /bin/sh -lc \
  'cd /work && /usr/local/cargo/bin/cargo check -p vmm-common -p vmm-task -p vmm-sandboxer'
```

This avoids repeated toolchain setup and gives a reusable Linux environment for compile and test debugging.

## Coding Style & Naming Conventions

Use Rust 2021 style and keep code `rustfmt`-compatible. Prefer `snake_case` for functions and modules, `CamelCase` for types, and short, explicit error messages. Keep runtime-path changes narrow and avoid unrelated refactors. Use `rg` for code search.

## Testing Guidelines

Add unit tests close to the modified crate. Prefer table-driven tests when behavior branches on input variants. For startup and lifecycle work, cover init process behavior explicitly. Start with the smallest relevant target before broader crate or workspace checks.

## Commit & Pull Request Guidelines

Use concise subject lines in the form:

```text
subsystem: what changed
```

When a fix addresses runtime behavior or latency, include the reason in the commit body and wrap long body lines to normal commit width. PRs should describe the user-visible effect, the root cause, and the validation method. Note any Linux-only or environment-specific test constraints clearly.
