# Web/TUI parity matrix

This matrix is the Release 1 acceptance gate. It is semantic parity, not visual
parity. The existing TUI remains supported and is not retired by this release.
Every row needs automated web evidence plus a one-node VM smoke and manual
browser tunnel verification before the TUI retirement decision is revisited.

| Capability | Required web evidence | Release 1 evidence |
|---|---|---|
| Status | Dashboard shows configured/live/placement nodes, placements, services, issues, current metrics, stale and partial state | `ClusterSnapshot` fixture tests and Dashboard LiveView tests |
| Network map | Deterministic accessible SVG/table shows node liveness, addresses, and ownership edges, including unplaced slots | Network component tests |
| Nodes | Inventory and detail views show host/name, liveness, availability, versions, digests, networking, resources, uptime, and owned units | Node LiveView tests |
| Services/ownership | Service and detail views show desired replicas, every slot/unit/owner/status, stateful restore metadata, and metrics | Service LiveView tests |
| Logs + search | Cluster/node/service scopes, 1–1000 line bound, warning/error filter, literal search navigation, stale/partial errors, refresh behavior | `LogSearch` and Logs LiveView tests |
| Drift | Config digests, mixed versions, desired/observed differences, placement diagnostics, and unknown vs healthy | Drift LiveView tests |
| Exports | Snapshot JSON, nodes CSV, services CSV, and selected bounded logs text with deterministic ordering and safe CSV fields | Export unit/controller tests |
| Read-only boundary | No deploy/edit/restart/heal routes, no source writes, no auth/account surface, and no BEAM cookie | Router/policy tests and Nix module assertions |

## Evidence rules

1. Tests must use the same normalized projection that the LiveViews render; a
   fixture-only formatter test is not sufficient for a view row.
2. Partial RPC failures, missing fields, and stale snapshots must remain visible
   and must not be normalized into healthy values.
3. All browser downloads are generated in memory from the broker cache. The web
   service does not create export files on the host.
4. The query broker is the only production caller of the web query client. Each
   browser tab subscribes to the broker rather than opening its own socket.
5. The web unit is loopback-only and read-only. The Nix VM test must verify no
   non-loopback listener, no firewall change, and operator-group access to the
   query socket.
6. Manual acceptance must exercise LiveView reconnect, stale indication after
   stopping the agent, bounded log search, and all four download types through
   an SSH tunnel.

## Non-goals

The matrix does not authorize write mode, TUI deletion, streaming journald,
metric sparklines, notifications, OAuth, accounts, per-user access, or Forgejo
integration. Those require separate scope and release gates.
