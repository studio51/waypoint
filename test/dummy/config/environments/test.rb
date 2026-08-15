# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load       = false

  config.consider_all_requests_local       = true
  config.action_controller.perform_caching = false
  config.action_dispatch.show_exceptions   = :none

  config.active_support.deprecation = :stderr

  config.cache_store = :memory_store
end

# The dummy application stands in for a host that has its own failure
# vocabulary — which is the one table Waypoint cannot ship with, so the suite
# has to prove it is actually consulted.
#
Waypoint.configure do |config|
  config.message_codes = {
    authenticator_expired_or_invalid: :credentials_expired,
    access_denied:                    :privacy_blocked,
    internal_missing_data:            :our_data_missing,
    bot_lacks_permissions:            :our_permissions,
  }
end
