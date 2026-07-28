# Hermes project context

`AGENT.md` is the canonical Nix-Swarm handbook. Read it before making changes
and follow its architecture, scope boundaries, and operational rules.

## Development defaults

- This is an Elixir/OTP and Nix project. Prefer Elixir, Erlang, and Nix; use
  Python only as a last resort when the project or a required tool truly needs
  it.
- Follow locality of behavior: keep policy beside the behavior it governs,
  avoid hidden global coupling, and prefer small coherent changes.
- Run `mix format`, `mix test`, and `nix flake check --no-build
  --no-write-lock-file` when the relevant tools are available.
- Update tests with behavior changes and keep generated artifacts out of Git.
- Never commit credentials, cookies, private infrastructure details, or files
  under `secrets/`.
- Before pushing, report the tests and checks that passed or failed.
