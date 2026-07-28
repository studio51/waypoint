class CreateWaypoints < ActiveRecord::Migration[8.1]
  # Sync observability: what ran, what it found, what landed, and what didn't —
  # with the reason and whose fault it was.
  #
  # Two tables on purpose. A `waypoint` is one *run* of one sync step ("synced
  # Vlad's Xbox achievements: found 900, synced 897, failed 3"); a
  # `waypoint_fault` is one thing that went wrong inside it, with the item it
  # happened to. Successes are counted, not recorded, so the volume stays
  # proportional to the trouble rather than to the traffic.
  #
  # Indexes are declared inside `create_table` rather than as separate `add_index`
  # calls so this reverses cleanly: reversing a trailing `add_index` runs after the
  # table is already gone and raises.
  #
  def change
    create_table :waypoints do |t|
      # What ran. `network` is the platform ("xbox"), `operation` the step
      # ("achievements"), `service` the class that did it — kept as a plain string
      # so a renamed service doesn't orphan history.
      #
      t.string :network
      t.string :operation, null: false
      t.string :service

      # Who or what it ran for: an identity, a user, a title. Polymorphic because
      # every network has its own, and some runs are catalogue-wide (nil).
      #
      t.references :subject, polymorphic: true, null: true, index: false

      # running / ok / partial / failed / stalled. `stalled` is set by the reaper
      # for a run whose items never all reported back — the case that used to be
      # invisible.
      #
      t.integer :status, null: false, default: 0

      # The counters behind the narrative. `found` is what upstream offered,
      # `enqueued` the units of work accepted (a fan-out can be more than one per
      # thing found), and the last two what came back.
      #
      t.integer :found,    null: false, default: 0
      t.integer :enqueued, null: false, default: 0
      t.integer :synced,   null: false, default: 0
      t.integer :failed,   null: false, default: 0

      t.datetime :started_at, null: false
      t.datetime :finished_at

      # bigint, not integer: a run the reaper settles after sitting open for
      # months (a cron that was off, a queue that was never drained) produces a
      # duration well past the ~24 days a 4-byte integer holds in milliseconds.
      # Truncating that, or raising on it, would both be worse than four bytes.
      #
      t.bigint :duration_ms

      # The Sidekiq job that opened the run, for correlating against the queue.
      #
      t.string :jid

      t.json :metadata

      t.timestamps

      # The dashboard's main axis: newest runs, filtered by network and operation.
      #
      t.index [ :network, :operation, :started_at ], name: "idx_waypoints_network_operation_started"

      # "What is still open?" — drives the reaper and the live view.
      #
      t.index [ :status, :started_at ], name: "idx_waypoints_status_started"

      # "How did this member's syncs go?" — the per-subject history.
      #
      t.index [ :subject_type, :subject_id, :started_at ], name: "idx_waypoints_subject_started"

      # Pruning reads this.
      #
      t.index :started_at, name: "idx_waypoints_started"
    end

    create_table :waypoint_faults do |t|
      t.references :waypoint, null: false, foreign_key: true, index: false

      # Which fault, from Waypoint::Fault::FAULTS. Grouped into who has to act —
      # the member, the network, or us — which is the question worth answering.
      #
      t.integer :fault, null: false, default: 0

      # The specific thing that failed, when we have a record for it, plus a label
      # for when we don't (an unmatched API payload has no row yet).
      #
      t.references :faultable, polymorphic: true, null: true, index: false
      t.string :label

      t.text    :message
      t.integer :code
      t.boolean :retryable, null: false, default: false

      t.json :context

      t.timestamps

      t.index [ :waypoint_id, :fault ], name: "idx_waypoint_faults_waypoint_fault"
      t.index [ :fault, :created_at ], name: "idx_waypoint_faults_fault_created"
      t.index [ :faultable_type, :faultable_id ], name: "idx_waypoint_faults_faultable"
    end
  end
end
