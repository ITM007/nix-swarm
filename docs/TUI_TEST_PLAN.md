# TUI test plan

How to run the read-only operator TUI test suite, what it covers, and the
safety invariants it enforces. The TUI is a read-only projection for
operators; per the product decision it is **deprecated and will retire
once the web UI reaches parity** (status, logs + search, drift, exports).
Until then it ships, and these tests are its contract.

## Running the suite

The TUI tests live in `test/nix_swarm_tui_test.exs` (29 tests) and run as
part of the normal suite inside the Nix development environment:

```bash
nix develop --command mix test test/nix_swarm_tui_test.exs --seed 0
nix develop --command mix test --warnings-as-errors --seed 0   # full gate
```

Notes:

- Tests run headless — no terminal is required; scenes render through an
  ASCII surface and are asserted as text/spans. The one environment check
  (`ex_ratatui` native directory present) fails with an actionable message
  instead of a cryptic NIF error.
- Kill stray BEAM nodes before running locally:
  `pkill -f 'test-controller@127.0.0.1'` (leftover distributed test nodes
  make membership-dependent assertions flaky).
- Terminal logging is suppressed during interactive-session tests and
  restored afterwards, so a TUI run never pollutes the suite log.

## What the tests cover

Rendering and interaction, per scene:

- **Dashboard** — ascii scene renders; stale-data indicator shows and empty
  metric widgets are avoided; map ascii is encoded as ratatui spans; full
  port lists render without ellipsis; stopped services are hidden and
  machine errors shown; service tables carry hostname owners.
- **Machines** — machine table columns, version-drift display (selected
  node differs from the control node), build digests stripped from shown
  versions.
- **Services / issues / logs** — issue strip and log-context header;
  aggregated cluster logs; footer errors render multiline without crashing;
  benign epmd noise filtered from machine logs; benign restart/partition
  warnings excluded from issue counts; filter bar switches all/errors/
  machine/service views; log search, tail toggle, sorting, and export
  actions update state.
- **Interaction** — key events against a loaded remote snapshot; stale auto
  refresh results are skipped after user input; auto refresh defers while a
  prompt is open; shift-tab and log focus cycling; vim `hjkl` motions;
  mouse clicks/wheel target views, rows, and logs; help overlay lists
  current-view shortcuts; pane titles show selection, summary, and log key
  hints.

## Safety invariants (asserted)

1. **Read-only boundary is visible**: the dashboard footer advertises the
   read-only boundary and the services footer omits mutation hints — there
   are no mutate affordances to hint at.
2. **No mutation paths exist**: mutation-era key flows were deleted in the
   read-only refactor; unknown keys fall through to the catch-all handler
   and are logged as unhandled events, never acted upon. There are no
   skipped tests — zero `@tag :skip` remain in the file.
3. **User-initiated log exports are the only writes**: exporting logs writes
   to the XDG state home (`nix-swarm/exports`, 0700 directories / 0600
   files, exclusive writes) and clipboard copy shells out to
   wl-copy/xclip/xsel/pbcopy. Nothing else in the TUI touches the
   filesystem or the cluster — every other action is a read against the
   operator query surface.

## When to touch this file

- A rendering or key-handling change to `lib/nix_swarm/tui.ex` must keep
  every test above green with no new skips.
- The decision-10 retirement plan removes the TUI (and this file) only
  after web-UI parity, via the removed-command message pattern. Until then,
  new TUI scope is out of policy: fix regressions, do not add features.
