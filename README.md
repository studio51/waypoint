# Waypoint

> Did the sync actually finish?

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)
[![CI](https://github.com/studio51/waypoint/actions/workflows/ci.yml/badge.svg)](https://github.com/studio51/waypoint/actions/workflows/ci.yml)

A sync is usually called "done" when its jobs were *enqueued*, not when the data
arrived. Nothing records what upstream offered, what actually landed, or why the
difference — so "is this account fully synced?" has no answer, and one missing 3
items out of 900 looks identical to one missing none.

Waypoint is a self-contained Rails engine. `rails` and `slim` are its only
dependencies: it ships no job runner, no HTTP client and no error vocabulary,
because your application already has all three.

```
achievements · xbox · partial
  found 900   tasks 900   done 897   failed 3

  Credentials expired    ×1   The member needs to reconnect the account
  Rate limited           ×2   Retryable — the provider asked us to slow down
```

`found > synced + failed` on a settled run is the number that matters: work that
was accepted and then *silently vanished*. Runs whose items never report back are
settled as `stalled` rather than left `running` forever.

## Navigation

This repository adheres to the [Studio51 Solutions Common Standard v1](https://github.com/studio51/standards/blob/main/standards/common/v1/STANDARD.md), with each section documented properly in its own file.

- [Architecture](docs/ARCHITECTURE.md) — the problem, and the fault taxonomy that answers "whose problem is it?"
- [Install & setup](docs/INSTALL.md)
- [Usage](docs/USAGE.md) — recording a run, reporting back, and housekeeping
- [Changelog](CHANGELOG.md)
- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)

## License

[Apache-2.0](LICENSE), © 2026 Studio51 Solutions. See [NOTICE](NOTICE).
