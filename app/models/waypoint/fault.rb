# frozen_string_literal: true

module Waypoint

  # One thing that went wrong inside a sync run, and whose problem it is.
  #
  # The point of the taxonomy is to answer a single question without reading a
  # stack trace: **who has to act?** A member whose PlayStation token expired, a
  # network that is down, and a bug of ours all look identical in a log — they are
  # three completely different jobs of work, and only one of them is ours.
  #
  # The names are not invented: they map onto the `message_code` vocabulary
  # {ApplicationService::ERROR_MESSAGES} already uses, which is what every network
  # service already reports through. See {Waypoint::Classifier}.
  #
  class Fault < ActiveRecord::Base

    self.table_name = "waypoint_faults"

    # --- The taxonomy ---

    # Ordered by party so the enum's integer values group naturally: 0-9 the
    # member's, 10-19 the network's, 20-29 ours. Leaves room to add to a group
    # without renumbering the others.
    #
    FAULTS = {
      # The member has to do something. Nothing we retry will help.
      #
      credentials_expired: 0, # token/npsso no longer valid — needs reconnecting
      privacy_blocked:     1, # profile, games or trophies set to private
      account_unreachable: 2, # renamed, deleted, or never existed upstream

      # The network's problem. Worth retrying, mostly.
      #
      network_unavailable:  10, # 5xx, timeout, connection refused
      network_rate_limited: 11, # 429 — back off and come back
      network_rejected:     12, # a 4xx that isn't auth or privacy
      network_empty:        13, # 200, but no data where data was expected

      # Ours. These are the ones to fix.
      #
      our_bug:          20, # an exception escaped our code
      our_data_missing: 21, # a local record or link we needed wasn't there
      our_permissions:  22, # our bot pool can't see this member (Xbox code 18)

      # A 401 is *our* app credentials being rejected, not the member's — filed
      # here rather than under the network, because a store refusing our token is
      # an integration of ours to repair. Naming it `network_unauthorised` invited
      # exactly the wrong reading.
      #
      our_credentials_rejected: 23,
    }.freeze

    enum :fault, FAULTS

    # Which faults belong to whom. The dashboard's primary grouping, and the
    # honest answer to "was it us?".
    #
    PARTIES = {
      member:  %i[credentials_expired privacy_blocked account_unreachable],
      network: %i[network_unavailable network_rate_limited network_rejected network_empty],
      us:      %i[our_bug our_data_missing our_permissions our_credentials_rejected],
    }.freeze

    # Associations
    #
    belongs_to :run, class_name: "Waypoint::Run", foreign_key: :waypoint_id, inverse_of: :faults, counter_cache: false
    belongs_to :faultable, polymorphic: true, optional: true

    # Scopes
    #
    PARTIES.each_key do |party|
      # Faults belonging to one party, e.g. `Waypoint::Fault.us`.
      #
      scope party, -> { where(fault: PARTIES[party]) }
    end

    scope :retryable, -> { where(retryable: true) }
    scope :recent,    -> { order(created_at: :desc) }

    # Who has to act on this fault.
    #
    # @return [Symbol] :member, :network, or :us.
    #
    def party
      PARTIES.find { |_, faults| faults.include?(fault.to_sym) }&.first || :us
    end

    # @return [Boolean] whether this is something we should be fixing.
    #
    def ours? = party == :us

    # The fault as a short human phrase, for the dashboard.
    #
    # Deliberately not called `label`: that is a *column* on this table, holding
    # the name of the item that failed ("Warthog Jump"). Defining a `label` method
    # shadowed it, so the one piece of information identifying which thing broke
    # was unreadable — it could still be written, which is why nothing caught it
    # until the dashboard tried to display it.
    #
    # @return [String]
    #
    def description = I18n.t("waypoint.faults.#{ fault }")

    # What the member (or we) would have to do about it.
    #
    # @return [String]
    #
    def remedy = I18n.t("waypoint.remedies.#{ fault }")
  end
end
