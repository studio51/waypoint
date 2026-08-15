# Waypoint — architecture

## The problem it exists to solve

The pipeline fans out. A sync discovers 900 achievements, enqueues a job each,
and returns. The items land later, in other processes. So the code that *found*
the work can never see what became of it, and the only record you get is:

```
[Xbox] achievements sync complete
```

Which is true, and says nothing. Three items went missing. Nobody was told,
nothing was retried, and the member's profile is quietly wrong.

Waypoint makes that arithmetic visible:

```
achievements · xbox · partial
  found 900   tasks 900   done 897   failed 3

  Credentials expired    ×1   The member needs to reconnect the account
  Rate limited           ×2   Retryable — the provider asked us to slow down
```

`found > synced + failed` on a settled run is the number that matters: work that
was accepted and then *silently vanished*. Runs whose items never report back are
settled as `stalled` rather than left `running` forever.


## Whose problem is it?

The point of the fault taxonomy is to answer one question without reading a stack
trace: **who has to act?** An expired token, a provider outage and a bug of yours
look identical in a log. They are three completely different jobs of work, and
only one of them is yours.

| Party | Faults |
| --- | --- |
| The account holder | `credentials_expired`, `privacy_blocked`, `account_unreachable` |
| The provider | `network_unavailable`, `network_rate_limited`, `network_rejected`, `network_empty` |
| You | `our_bug`, `our_data_missing`, `our_permissions`, `our_credentials_rejected` |

Anything unrecognised is `our_bug`. That default is deliberate: an unclassified
failure is a gap in *your* understanding, and calling it the provider's problem
would quietly hide it.

---

## Structure

```
lib/waypoint.rb              the public API: .record, .current, .attributing, .configure
lib/waypoint/absorbing.rb    the job-runner half of the contract, as a mixin
lib/waypoint/configuration.rb everything a host gets to decide
lib/waypoint/engine.rb       mounts the dashboard, contributes the migration path

app/models/waypoint/run.rb        one run of one sync step, and how it went
app/models/waypoint/fault.rb      one thing that went wrong, and whose problem it is
app/models/waypoint/classifier.rb failure -> fault, in order of confidence
app/models/waypoint/audit.rb      the windowed aggregates the dashboard reads
app/models/waypoint/maintenance.rb reaping stalled runs, pruning past retention

app/controllers/waypoint/runs_controller.rb
app/views/waypoint/                the dashboard, with its own layout and partials
```

## Key decisions

**`Waypoint` is a module, `Waypoint::Run` is the model.** An engine needs a
module namespace, and the domain language was already "runs". The table is still
`waypoints` and the faults foreign key is still `waypoint_id` — a Ruby-side name
is not worth a migration of somebody's data.

**No job runner ships.** Yours already exists. The only thing it needs to learn
is `Waypoint::Absorbing#absorb_into`, which threads a run id through a job and
reports the outcome back. Waypoint records; it does not schedule.

**The classifier's first table is the host's.** `config.message_codes` maps an
application's own failure vocabulary onto faults, and is empty by default. That
is not a failure state: an application without such a vocabulary classifies on
exception class and HTTP status alone. Everything else ships with defaults.

**A failure is re-raised, always.** Waypoint observes; it never swallows. The
run's `failed` count is what *this attempt* looked like, and a later retry that
succeeds increments `synced` — the honest record of a flaky sync.

**No adapter-specific SQL.** The suite runs on SQLite precisely so a MySQL-only
expression fails it. `EXPECTED_SQL` was `IF(enqueued > 0, …)` when this lived
in-tree; it is a portable `CASE` now.

**Pagination is hand-rolled.** An engine that drags a pagination library into
every host has made the host's dependency decision for it, to render "Previous
3 / 12 Next".
