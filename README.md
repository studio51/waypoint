# Waypoint

> Did the sync actually finish?

A sync is usually called "done" when its jobs were *enqueued*, not when the data
arrived. Nothing records what upstream offered, what actually landed, or why the
difference — so "is this account fully synced?" has no answer, and one missing 3
items out of 900 looks identical to one missing none.

Waypoint is a self-contained Rails engine. `rails` and `slim` are its only
dependencies: it ships no job runner, no HTTP client and no error vocabulary,
because your application already has all three.

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

## Installation

```ruby
gem "waypoint"
```

```ruby
# config/routes.rb
mount(Waypoint::Engine, at: "/waypoint", as: :waypoint)
```

Waypoint ships no authentication of its own — the audit shows what every sync did
for every subject, so mount it behind whatever gate your operator tooling already
uses:

```ruby
# config/initializers/waypoint.rb
Waypoint.configure do |config|
  config.parent_controller = "Admin::ApplicationController"

  # The one table that cannot ship with the gem: your application's own
  # vocabulary for why something failed. Everything else has a sane default.
  #
  config.message_codes = {
    authenticator_expired_or_invalid: :credentials_expired,
    access_denied:                    :privacy_blocked,
    internal_missing_data:            :our_data_missing,
  }
end
```

## Recording a run

```ruby
Waypoint.record(network: :xbox, operation: :achievements, subject: identity) do |run|
  achievements = client.achievements

  run.found(achievements.size)
  run.enqueued!(achievements.size)

  achievements.each { |achievement| ItemJob.perform_async(achievement.id, run.id) }
end
```

A run that fans work out stays `running` for its items to report into. One that
does all its own work settles immediately.

## Reporting back

Thread the run's id through the job, and wrap the call:

```ruby
class ItemJob
  include Waypoint::Absorbing

  def perform(payload, run_id = nil)
    absorb_into(run_id) { DoTheWork.call(payload) }
  end
end
```

The item is the unit of success. A failure is attributed and **re-raised**, so
your queue still retries it — the run's `failed` count is what this attempt
looked like, and a later retry that succeeds increments `synced`. That is the
honest record of a flaky sync.

While the block runs, the run is published as `Waypoint.current`, so a service
deep in the call stack can attribute its own failure with the code it knows:

```ruby
Waypoint.current&.failed!(error, fault: Waypoint::Classifier.for_record_error(error.code, error.message_code))
Waypoint.attributed!
```

When it does, the generic attribution stands down rather than counting the same
failure twice with the vaguer reason.

## Housekeeping

```ruby
Waypoint::Maintenance.call   # settle stalled runs, drop history past retention
```

Runs open longer than `config.stall_after` (6 hours) are settled as `stalled`.
Successful runs are dropped after `config.keep_settled` (30 days), failures after
`config.keep_failed` (90 days). Run it from whatever scheduler you already have.

## Development

The suite runs against a dummy Rails application under `test/dummy`, on SQLite —
which is also why the engine carries no adapter-specific SQL.

```sh
bundle install
bundle exec rake
bundle exec rubocop
```

## Licence

Apache-2.0 © Studio51 Solutions. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
