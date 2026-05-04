# Contributing

## Development setup

From the repository root:

```bash
mix format
mix test
nix flake check --no-build --no-write-lock-file
```

If you are working on release packaging or the escript entrypoint, also run:

```bash
mix escript.build
```

## Project layout

- `lib/` contains the CLI, TUI, runtime, deploy, and remote-control logic
- `nix/` contains the Nix package and NixOS module
- `examples/config/` contains the public starter cluster, machine, and service configs
- `docs/` contains user-facing technical documentation

## Contribution guidelines

- Keep examples and docs public-safe: use `example-*`, `.example`, `.example.internal`, or reserved documentation IP ranges instead of real infrastructure details.
- Do not commit local secrets, cookies, or generated build artifacts.
- Prefer updating tests alongside behavior changes.
- Keep changes focused; avoid bundling unrelated refactors with functional fixes.

## Before opening a pull request

1. Run the validation commands above.
2. Update docs when user-facing behavior changes.
3. Add or update tests for behavior changes.
4. Ensure no local files under `cluster/`, `machines/`, or `secrets/` were accidentally staged.
