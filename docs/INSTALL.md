# Install & setup

## Requirements

Rails 7.1–8.x and Ruby 3.2+. Waypoint ships no job runner, no HTTP client and no
error vocabulary, because your application already has all three — they are
reached through configuration rather than a dependency.

## Quick start

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


## Development

The suite runs against a dummy Rails application under `test/dummy`, on SQLite —
which is also why the engine carries no adapter-specific SQL.

```sh
bundle install
bundle exec rake
bundle exec rubocop
```
