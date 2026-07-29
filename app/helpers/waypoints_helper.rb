# frozen_string_literal: true

# Presentation for the sync audit.
#
module WaypointsHelper

  # Tailwind colour stem per run status.
  #
  # `stalled` is red rather than grey on purpose: a run whose work was accepted
  # and never came back is a worse outcome than one that failed outright and said
  # so, because nothing was retried and nobody was told.
  #
  STATUS_COLORS = {
    "running" => "blue",
    "ok"      => "green",
    "partial" => "orange",
    "failed"  => "red",
    "stalled" => "red",
  }.freeze

  # Tailwind colour stem per fault party.
  #
  # Ours is red — it is the pile to act on. The member's is blue (information, not
  # a defect: they have to do something, we don't) and the network's orange
  # (transient, usually clears).
  #
  PARTY_COLORS = {
    member:  "blue",
    network: "orange",
    us:      "red",
  }.freeze

  # @param status [String, Symbol] a Waypoint status.
  #
  # @return [String] the Tailwind colour stem, e.g. "green".
  #
  def waypoint_status_color(status) = STATUS_COLORS.fetch(status.to_s, "gray")

  # @param party [String, Symbol] a Waypoint::Fault party.
  #
  # @return [String] the Tailwind colour stem.
  #
  def waypoint_party_color(party) = PARTY_COLORS.fetch(party.to_sym, "gray")

  # The tile tone for a run status.
  #
  # @param status [String, Symbol] a Waypoint status.
  #
  # @return [Symbol] one of the `_tile` partial's tones.
  #
  def waypoint_status_tone(status)
    case status.to_s
    when "ok"                then :good
    when "partial"           then :warn
    when "failed", "stalled" then :bad
    when "running"           then :neutral
    else :muted
    end
  end
end
