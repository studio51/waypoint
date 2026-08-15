# frozen_string_literal: true

# A stand-in for whatever error type a host application raises when an upstream
# call fails.
#
# Waypoint deliberately knows nothing about it — it duck-types on `code` and
# `message_code`, so an application's existing error class works as it is. The
# tests need *an* error of that shape, so here is one.
#
class ProviderError < StandardError
  attr_reader :code, :message_code

  def initialize(code, message = "upstream failed", message_code: nil)
    @code         = code
    @message_code = message_code

    super(message)
  end
end
