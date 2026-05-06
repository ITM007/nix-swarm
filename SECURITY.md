# Security policy

## Supported versions

Nix-Swarm is currently in the `0.2.x` alpha series. Security fixes are only guaranteed for the latest `v0.2.x` tag on `main`.

Older tags should be treated as unsupported once a newer `v0.2.x` release is published.

## Reporting a vulnerability

Please do **not** open a public issue for suspected vulnerabilities.

Use GitHub's private vulnerability reporting / security advisory workflow for this repository when available. If that is unavailable, contact the maintainer privately through GitHub before any public disclosure.

Include:

- the affected version or commit
- a short description of the impact
- reproduction steps or a proof of concept
- any suggested mitigation

## Technical security model

See [`docs/SECURITY.md`](docs/SECURITY.md) for the distributed Erlang threat model, cookie handling, firewall guidance, and deploy/apply SSH trust assumptions.
