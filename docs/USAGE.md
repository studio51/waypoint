# Usage

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

