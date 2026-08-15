# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Extracted from games.directory, where it was built across `app/models`,
  `app/services`, `app/controllers`, `app/helpers` and `app/views`. History is
  preserved.
- Apache-2.0 licence.
- `Waypoint::Configuration`, reached through `Waypoint.configure`. The one table
  that cannot ship with the gem is `message_codes` — an application's own
  vocabulary for why something failed. Retention windows, the retryable set, the
  exception and status tables, the dashboard's parent controller and its back
  link are all configurable, all with working defaults.
- `Waypoint::Absorbing`, the job-runner half of the contract, as a documented
  mixin. This was ~40 lines every host would otherwise have had to reverse
  engineer from the original `GeneralPurposeJob`.
- A mountable dashboard of the engine's own, with its own layout, pagination and
  heading partials — replacing the host's admin layout and ViewComponents.
- A dummy Rails application under `test/dummy` on SQLite, and an integration test
  that renders every dashboard page. Rendering is where an extracted engine's
  remaining coupling actually surfaces.

### Changed

- The model is `Waypoint::Run`; `Waypoint` is now the module carrying the public
  API (`.record`, `.current`, `.attributing`, `.configure`). An engine needs a
  module namespace, and the domain language was already "runs". The table is
  still `waypoints` and the faults foreign key is still `waypoint_id` — this is
  a Ruby-side rename, not a migration.
- `Waypoints::Audit` and `Waypoints::Maintenance` are `Waypoint::Audit` and
  `Waypoint::Maintenance`. `Maintenance.call` is the entry point.

### Removed

- The outstanding-attachments panel, which read `AttachmentIntent` — a
  games.directory model. It shares the fault vocabulary but is not part of "did
  the sync finish?", and belongs to the application that owns those records.
- The two tests asserting games.directory's `ERROR_MESSAGES` and
  `TRANSIENT_API_ERRORS` are fully mapped. Those assert a property of a host's
  configuration, not of this gem, and stay behind.

### Fixed

Found by booting the code against a Rails application that was not
games.directory:

- `EXPECTED_SQL` used MySQL's `IF()`, which exists on no other adapter — every
  `incomplete` query and the run counters raised on PostgreSQL and SQLite. Now a
  portable `CASE`.
- The dashboard depended on the host for pagination (`pagy`), three
  ViewComponents (`Ui::Page::HeadingComponent`, `InlineNoticeComponent`,
  `PaginationComponent`), a `network_label` helper and `Admin::ApplicationController`.
  All now the engine's own; pagination is deliberately hand-rolled rather than
  making every host adopt a pagination gem.
- `slim` was used by every template and declared nowhere.
- The i18n scope was `waypoints.*` with the view scope under `admin.waypoints.*`,
  which only resolved because of where the controller happened to live.
