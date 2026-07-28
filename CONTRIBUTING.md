# Contributing

## Development setup

From the repository root:

```bash
nix develop -c mix format --check-formatted
nix develop -c mix clean
nix develop -c mix compile --warnings-as-errors
nix develop -c mix hex.audit
nix develop -c mix test --warnings-as-errors --cover
nix flake check --print-build-logs
```

## Project layout

- `lib/` contains the CLI, TUI, runtime, deploy, and remote-control logic
- `nix/` contains the Nix package and NixOS module
- `examples/starter/` is the packaged one-node starter
- `examples/config/` is a larger two-node example
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
