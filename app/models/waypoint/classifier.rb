# frozen_string_literal: true

class Waypoint

  # Turns a failure into one of {Waypoint::Fault::FAULTS}.
  #
  # This is the piece that makes the dashboard worth looking at: the same
  # `Network::Error` can mean "the member needs to reconnect PlayStation", "PSN is
  # down", or "we forgot to create a Title" — three different jobs of work that a
  # log line cannot tell apart.
  #
  # Classification is deliberately anchored on vocabulary that already exists
  # rather than invented alongside it, in this order of confidence:
  #
  #   1. The `message_code` a service passed to `record_error` — the strongest
  #      signal, because the service knew exactly what happened. Every entry in
  #      {ApplicationService::ERROR_MESSAGES} is mapped below.
  #   2. The exception class — a timeout is a timeout regardless of who raised it.
  #   3. The HTTP status carried on a {Network::Error}.
  #
  # Anything unrecognised is `our_bug`. That default is on purpose: an unclassified
  # failure is a gap in *our* understanding, and calling it the network's problem
  # would quietly hide it.
  #
  module Classifier
    extend self

    # `message_code` → fault. Keys mirror {ApplicationService::ERROR_MESSAGES}
    # exactly; a new code there should gain an entry here.
    #
    BY_MESSAGE_CODE = {
      authenticator_expired_or_invalid: :credentials_expired,
      invalid_session_or_missing_data:  :credentials_expired,

      access_denied:                                :privacy_blocked,
      entitlements_not_permitted_by_access_control: :privacy_blocked,
      achievements_not_permitted_by_access_control: :privacy_blocked,
      friends_not_permitted_by_access_control:      :privacy_blocked,
      games_not_permitted_by_access_control:        :privacy_blocked,
      presence_not_permitted_by_access_control:     :privacy_blocked,
      profile_not_permitted_by_access_control:      :privacy_blocked,
      titles_not_permitted_by_access_control:       :privacy_blocked,
      collection_not_permitted_by_access_control:   :privacy_blocked,
      session_not_permitted_by_access_control:      :privacy_blocked,
      activity_not_permitted_by_access_control:     :privacy_blocked,
      trophy_not_permitted_by_access_control:       :privacy_blocked,

      internal_missing_data: :our_data_missing,
      too_many_titles:       :our_data_missing,

      # Not the member's privacy setting: every candidate bot was denied, which
      # is a gap in our bot pool's access. Latching this as "private" is the
      # mistake the Xbox client explicitly avoids.
      #
      bot_lacks_permissions: :our_permissions,
    }.freeze

    # Exception class name → fault. Matched on the name so a class that isn't
    # loaded (an optional HTTP stack) doesn't have to be referenced here.
    #
    BY_EXCEPTION = {
      "Timeout::Error"           => :network_unavailable,
      "Net::OpenTimeout"         => :network_unavailable,
      "Net::ReadTimeout"         => :network_unavailable,
      "Errno::ETIMEDOUT"         => :network_unavailable,
      "Errno::ECONNRESET"        => :network_unavailable,
      "Errno::ECONNREFUSED"      => :network_unavailable,
      "Errno::EHOSTUNREACH"      => :network_unavailable,
      "SocketError"              => :network_unavailable,
      "HTTPClient::TimeoutError" => :network_unavailable,

      "ActiveRecord::RecordNotFound" => :our_data_missing,
      "ActiveRecord::RecordInvalid"  => :our_bug,
    }.freeze

    # HTTP status → fault, for a {Network::Error} with nothing better to go on.
    #
    BY_STATUS = {
      400 => :network_rejected,
      401 => :our_credentials_rejected,
      403 => :privacy_blocked,
      404 => :account_unreachable,
      408 => :network_unavailable,
      409 => :network_rejected,
      410 => :account_unreachable,
      422 => :network_rejected,
      429 => :network_rate_limited,
    }.freeze

    # Faults worth trying again. The member's and our own are not — retrying an
    # expired token or a bug just burns worker time.
    #
    RETRYABLE = %i[network_unavailable network_rate_limited network_empty].freeze

    # The fault a failure represents.
    #
    # @param error [Exception, String, Symbol] the failure. A Symbol is taken as a
    #   `message_code`.
    #
    # @return [Symbol] a key of {Waypoint::Fault::FAULTS}.
    #
    def classify(error)
      by_message_code(error) ||
        by_exception(error) ||
        by_status(error) ||
        :our_bug
    end

    # @param fault [Symbol] a key of {Waypoint::Fault::FAULTS}.
    #
    # @return [Boolean] whether it is worth retrying.
    #
    def retryable?(fault) = RETRYABLE.include?(fault.to_sym)

    # The fault for a `record_error` call, which knows more than an exception does.
    #
    # @param status [Integer, nil] the HTTP-ish status.
    # @param message_code [Symbol, nil] the ERROR_MESSAGES key.
    #
    # @return [Symbol]
    #
    def for_record_error(status, message_code)
      BY_MESSAGE_CODE[message_code&.to_sym] || BY_STATUS[status.to_i] || :our_bug
    end

  private

    def by_message_code(error)
      code = error.is_a?(Symbol) ? error : error.try(:message_code)

      BY_MESSAGE_CODE[code&.to_sym]
    end

    def by_exception(error)
      return unless error.is_a?(Exception)

      # Walk the ancestry so a subclass of a known error still classifies.
      #
      error.class.ancestors.each do |ancestor|
        next unless ancestor.is_a?(Class)

        fault = BY_EXCEPTION[ancestor.name]

        return fault if fault
      end

      nil
    end

    def by_status(error)
      status = error.try(:code).to_i

      # Any 5xx is the store being broken, whatever the specific code. Listing
      # them individually would just be a list of ways to say "not our fault".
      #
      return :network_unavailable if status >= 500

      BY_STATUS[status]
    end
  end
end
