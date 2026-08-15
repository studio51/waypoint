# frozen_string_literal: true

module Waypoint

  # Turns a failure into one of {Waypoint::Fault::FAULTS}.
  #
  # This is the piece that makes the dashboard worth looking at: one upstream
  # error class can mean "the member needs to reconnect their account", "the
  # provider is down", or "we never created the record it wanted" — three
  # completely different jobs of work that a log line cannot tell apart.
  #
  # Classification is deliberately anchored on vocabulary that already exists
  # rather than invented alongside it, in this order of confidence:
  #
  #   1. The application's own `message_code` — the strongest signal, because the
  #      service that raised it knew exactly what happened. Map yours with
  #      {Waypoint::Configuration#message_codes}; it is the one table that cannot
  #      ship with the gem.
  #   2. The exception class — a timeout is a timeout regardless of who raised it.
  #   3. The HTTP status, for an error that carries one.
  #
  # Anything unrecognised is `our_bug`. That default is on purpose: an unclassified
  # failure is a gap in *our* understanding, and calling it the provider's problem
  # would quietly hide it.
  #
  module Classifier
    extend self

    # Exception class name → fault. Matched on the name so a class that isn't
    # loaded (an optional HTTP stack) doesn't have to be referenced here.
    #
    EXCEPTIONS = {
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
    STATUSES = {
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
    def retryable?(fault) = Waypoint.config.retryable_faults.map(&:to_sym).include?(fault.to_sym)

    # The application's failure vocabulary. Empty unless the host configured one.
    #
    # @return [Hash{Symbol => Symbol}]
    #
    def message_codes
      Waypoint.config.message_codes.symbolize_keys
    end

    # {EXCEPTIONS} with the host's additions layered over it, so an application
    # can classify an exception the gem has never heard of — or reclassify one it
    # disagrees with.
    #
    # @return [Hash{String => Symbol}]
    #
    def exceptions
      EXCEPTIONS.merge(Waypoint.config.exceptions.transform_keys(&:to_s))
    end

    # {STATUSES} with the host's additions layered over it.
    #
    # @return [Hash{Integer => Symbol}]
    #
    def statuses
      STATUSES.merge(Waypoint.config.statuses.transform_keys(&:to_i))
    end

    # The fault for a `record_error` call, which knows more than an exception does.
    #
    # @param status [Integer, nil] the HTTP-ish status.
    # @param message_code [Symbol, nil] the application's own code for the failure.
    #
    # @return [Symbol]
    #
    def for_record_error(status, message_code)
      message_codes[message_code&.to_sym] || for_status(status) || :our_bug
    end

    # The fault an HTTP-ish status implies.
    #
    # Shared by {#classify} and {#for_record_error} — they had their own copies of
    # this, and only one of them knew that any 5xx is the store being broken. So a
    # 503 reported through `record_error` (which is how the network services report
    # *everything*) was classified `our_bug` and the dashboard blamed us for the
    # store being down. Exactly the mis-attribution the taxonomy exists to prevent.
    #
    # @param status [Integer, String, nil]
    #
    # @return [Symbol, nil] the fault, or nil when the status says nothing useful.
    #
    def for_status(status)
      code = status.to_i

      # Any 5xx is the store being broken, whatever the specific code. Listing
      # them individually would just be a list of ways to say "not our fault".
      #
      return :network_unavailable if code >= 500

      statuses[code]
    end

  private

    def by_message_code(error)
      code = error.is_a?(Symbol) ? error : error.try(:message_code)

      message_codes[code&.to_sym]
    end

    def by_exception(error)
      return unless error.is_a?(Exception)

      # Walk the ancestry so a subclass of a known error still classifies.
      #
      error.class.ancestors.each do |ancestor|
        next unless ancestor.is_a?(Class)

        fault = exceptions[ancestor.name]

        return fault if fault
      end

      nil
    end

    def by_status(error) = for_status(error.try(:code))
  end
end
