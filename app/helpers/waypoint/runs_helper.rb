# frozen_string_literal: true

# Presentation for the sync audit.
#
module Waypoint
  module RunsHelper

    # Friendly label for the network a run belongs to.
    #
    # The key is whatever the host passed to {Waypoint.record} — Waypoint has no
    # list of networks and should not have one. Titleised by default, so an
    # un-translated network reads sensibly rather than showing a missing
    # translation; add `waypoint.networks.<key>` to override.
    #
    # @param network [String, Symbol] the network key, e.g. "play_station".
    #
    # @return [String]
    #
    def network_label(network)
      key = network.to_s.split("::").first.to_s

      t("waypoint.networks.#{ key.underscore }", default: key.titleize)
    end

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
end
