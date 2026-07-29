require "test_helper"

# Turning a failure into "whose problem is this?".
#
# The value of the whole audit rests here: the same Network::Error can mean the
# member must reconnect, the store is down, or we have a bug. Getting this wrong
# means the dashboard confidently points at the wrong person.
#
class Waypoint::ClassifierTest < ActiveSupport::TestCase
  Classifier = Waypoint::Classifier

  # --- message_code, the strongest signal ---

  test "an expired authenticator is the member's to fix" do
    assert_equal :credentials_expired, Classifier.for_record_error(401, :authenticator_expired_or_invalid)
  end

  test "a private profile is the member's setting, not a failure of ours" do
    assert_equal :privacy_blocked, Classifier.for_record_error(403, :achievements_not_permitted_by_access_control)
  end

  test "missing local data is ours" do
    assert_equal :our_data_missing, Classifier.for_record_error(404, :internal_missing_data)
  end

  # The distinction the Xbox client is explicit about: code 18 means every bot we
  # tried was denied, which is a gap in our pool — not proof the gamer is private.
  # Recording it as the member's privacy setting would blame them for our problem
  # and, worse, justify skipping them forever.
  #
  test "a bot permission failure is ours, not the member's privacy" do
    fault = Classifier.for_record_error(404, :bot_lacks_permissions)

    assert_equal :our_permissions, fault
    assert_equal :us, Waypoint::Fault.new(fault:).party
  end

  # Every ERROR_MESSAGES code must classify, or a real failure silently becomes
  # "our_bug" and hides in the noise.
  #
  test "every message code the app can report is classified" do
    unmapped = ApplicationService::ERROR_MESSAGES.keys - Classifier::BY_MESSAGE_CODE.keys

    assert_empty unmapped, "unclassified message codes would all land in our_bug: #{ unmapped.inspect }"
  end

  # --- Exceptions ---

  test "timeouts and dropped connections are the network" do
    [ Timeout::Error, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError ].each do |klass|
      assert_equal :network_unavailable, Classifier.classify(klass.new("down")), klass.name
    end
  end

  # The retry list in ApplicationService is the app's own statement of what is
  # transient; the classifier must agree with it.
  #
  test "agrees with the service layer about what is transient" do
    ApplicationService::TRANSIENT_API_ERRORS.each do |klass|
      fault = Classifier.classify(klass.new("down"))

      assert Classifier.retryable?(fault), "#{ klass.name } is retried by the service but #{ fault } is not retryable"
    end
  end

  test "a missing record is our data problem" do
    assert_equal :our_data_missing, Classifier.classify(ActiveRecord::RecordNotFound.new("gone"))
  end

  test "classifies a subclass of a known error" do
    subclass = Class.new(Timeout::Error)

    assert_equal :network_unavailable, Classifier.classify(subclass.new("down"))
  end

  # --- HTTP status ---

  test "any 5xx is the store being broken" do
    [ 500, 502, 503, 504 ].each do |status|
      assert_equal :network_unavailable, Classifier.classify(Network::Error.new(status, "bad")), status.to_s
    end
  end

  test "429 is rate limiting, and worth retrying" do
    fault = Classifier.classify(Network::Error.new(429, "slow down"))

    assert_equal :network_rate_limited, fault
    assert Classifier.retryable?(fault)
  end

  # A 401 is the store rejecting *our* token, which is an integration of ours to
  # repair — not something the member did. Filing it under the network would send
  # us looking in the wrong place.
  #
  test "401 is our credentials, not the member's" do
    fault = Classifier.classify(Network::Error.new(401, "nope"))

    assert_equal :our_credentials_rejected, fault
    assert_equal :us, Waypoint::Fault.new(fault:).party
  end

  test "404 means the account is gone upstream" do
    assert_equal :account_unreachable, Classifier.classify(Network::Error.new(404, "no such gamer"))
  end

  # --- The default ---

  # Unrecognised failures default to ours on purpose. Calling them the network's
  # problem would let a genuine bug of ours hide behind "the store was flaky".
  #
  test "an unrecognised failure is assumed to be ours" do
    assert_equal :our_bug, Classifier.classify(RuntimeError.new("???"))
    assert_equal :our_bug, Classifier.classify("a bare string")
  end

  test "the member's own faults are never retried" do
    Waypoint::Fault::PARTIES[:member].each do |fault|
      assert_not Classifier.retryable?(fault), "#{ fault } cannot be fixed by retrying"
    end
  end

  # --- Parties ---

  test "every fault belongs to exactly one party" do
    grouped = Waypoint::Fault::PARTIES.values.flatten

    assert_equal Waypoint::Fault::FAULTS.keys.sort, grouped.sort
    assert_equal grouped.uniq, grouped
  end

  test "every fault has copy for its description and its remedy" do
    Waypoint::Fault::FAULTS.each_key do |fault|
      record = Waypoint::Fault.new(fault:)

      assert_not_empty record.description, "#{ fault } has no description"
      assert_not_empty record.remedy,      "#{ fault } has no remedy"
    end
  end

  # `label` is a column — the name of the item that failed ("Warthog Jump") — and
  # was shadowed by a method of the same name returning the fault's copy. That made
  # the one field identifying the broken thing unreadable, while still being
  # writable, which is why it went unnoticed until the dashboard tried to show it.
  #
  test "label still holds the item that failed" do
    record = Waypoint::Fault.new(fault: :our_bug, label: "Warthog Jump")

    assert_equal "Warthog Jump", record.label
    assert_equal I18n.t("waypoints.faults.our_bug"), record.description
  end
end
