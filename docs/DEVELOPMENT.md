# Development and verification

Nix-Swarm requires Elixir 1.20 so every module is checked by Elixir's gradual,
set-theoretic type system. Signature inference is explicitly enabled for normal
compilation and for test modules. Test inference matters because Mix disables it
for tests by default.

Elixir 1.20 infers function signatures and reports contradictions as compiler
warnings. It does not yet provide source syntax for set-theoretic type
signatures. Existing `@type`, `@callback`, and `@spec` declarations remain useful
for documentation, behaviours, and Dialyzer, but they are not a replacement for
the compiler's inference pass.

## Local quality gate

Run the same checks used in CI:

```bash
mix format --check-formatted
mix clean
mix compile --warnings-as-errors
mix hex.audit
mix test --warnings-as-errors --cover
nix flake check --print-build-logs
```

The coverage gate currently requires 65% overall line coverage. The current
suite is above that baseline, and the threshold should only move upward. New
control-plane, placement, deployment, security, or reconciliation code should
normally have at least 80% module coverage even while presentation and OS-probe
code keep the aggregate lower.

## Test layers

1. Unit and contract tests cover parsers, placement, configuration, command
   construction, adapters, RPC normalization, secrets, and rollout decisions.
2. Distributed integration tests start three real Erlang peer nodes and verify
   membership, placement convergence, failover, logs, service control, and
   durable intent.
3. Restricted-query tests cover protocol bounds and the operator allowlist;
   distributed tests use injected local transport and never depend on an
   operator cookie.
4. Flake checks build both releases and evaluate the complete NixOS module on
   x86_64 and aarch64.
5. The NixOS VM test boots an unprivileged agent under the hardened systemd unit, waits for
   `Type=notify` readiness, verifies its DETS state, and observes a managed unit
   being reconciled to running.

Tests that modify application environment, OS environment, the running OTP
application, or executable search paths must use `async: false` and restore the
previous state in `on_exit/1`. Tests must pass under randomized seeds; do not
rely on the application state left by another test module.
