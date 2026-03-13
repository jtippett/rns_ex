defmodule RNS.Interfaces.InterfaceTest do
  use ExUnit.Case, async: true

  alias RNS.Interfaces.Interface
  alias RNS.Interfaces.Interface.AnnounceQueueEntry
  alias RNS.Interfaces.Interface.HDLC
  alias RNS.Interfaces.Interface.KISS
  import Bitwise

  # ── Helper: build a minimal interface struct-like map ───────────────

  defp new_interface(overrides \\ %{}) do
    defaults = Interface.default_fields() |> Map.new()

    defaults
    |> Map.put(:created, System.system_time(:second))
    |> Map.merge(overrides)
  end

  # ── Constants ──────────────────────────────────────────────────────

  describe "mode constants" do
    test "MODE_FULL" do
      assert Interface.mode_full() == 0x01
    end

    test "MODE_POINT_TO_POINT" do
      assert Interface.mode_point_to_point() == 0x02
    end

    test "MODE_ACCESS_POINT" do
      assert Interface.mode_access_point() == 0x03
    end

    test "MODE_ROAMING" do
      assert Interface.mode_roaming() == 0x04
    end

    test "MODE_BOUNDARY" do
      assert Interface.mode_boundary() == 0x05
    end

    test "MODE_GATEWAY" do
      assert Interface.mode_gateway() == 0x06
    end

    test "DISCOVER_PATHS_FOR contains AP, gateway, roaming" do
      dpf = Interface.discover_paths_for()
      assert Interface.mode_access_point() in dpf
      assert Interface.mode_gateway() in dpf
      assert Interface.mode_roaming() in dpf
      refute Interface.mode_full() in dpf
    end
  end

  describe "ingress control constants" do
    test "IA_FREQ_SAMPLES" do
      assert Interface.ia_freq_samples() == 6
    end

    test "OA_FREQ_SAMPLES" do
      assert Interface.oa_freq_samples() == 6
    end

    test "MAX_HELD_ANNOUNCES" do
      assert Interface.max_held_announces() == 256
    end

    test "IC_NEW_TIME is 2 hours" do
      assert Interface.ic_new_time() == 2 * 60 * 60
    end

    test "IC_BURST_FREQ_NEW" do
      assert Interface.ic_burst_freq_new() == 3.5
    end

    test "IC_BURST_FREQ" do
      assert Interface.ic_burst_freq() == 12
    end

    test "IC_BURST_HOLD is 1 minute" do
      assert Interface.ic_burst_hold() == 60
    end

    test "IC_BURST_PENALTY is 5 minutes" do
      assert Interface.ic_burst_penalty() == 300
    end

    test "IC_HELD_RELEASE_INTERVAL is 30 seconds" do
      assert Interface.ic_held_release_interval() == 30
    end
  end

  # ── Default fields ─────────────────────────────────────────────────

  describe "default_fields/0" do
    test "returns keyword list with all expected fields" do
      fields = Interface.default_fields()
      assert is_list(fields)
      keys = Keyword.keys(fields)
      assert :name in keys
      assert :rxb in keys
      assert :txb in keys
      assert :online in keys
      assert :bitrate in keys
      assert :ingress_control in keys
      assert :held_announces in keys
      assert :ia_freq_deque in keys
      assert :oa_freq_deque in keys
      assert :announce_queue in keys
      assert :ifac_identity in keys
      assert :ifac_size in keys
    end

    test "default bitrate is 62500" do
      fields = Interface.default_fields() |> Map.new()
      assert fields.bitrate == 62_500
    end

    test "default stats are zero" do
      fields = Interface.default_fields() |> Map.new()
      assert fields.rxb == 0
      assert fields.txb == 0
    end

    test "default direction flags are false" do
      fields = Interface.default_fields() |> Map.new()
      assert fields.in == false
      assert fields.out == false
      assert fields.fwd == false
      assert fields.rpt == false
    end

    test "ingress control is enabled by default" do
      fields = Interface.default_fields() |> Map.new()
      assert fields.ingress_control == true
    end
  end

  # ── hash/1 ─────────────────────────────────────────────────────

  describe "hash/1" do
    test "returns 32-byte SHA-256 hash for named interface" do
      iface = new_interface(%{name: "TestInterface[test]"})
      hash = Interface.hash(iface)
      assert byte_size(hash) == 32
    end

    test "different names produce different hashes" do
      h1 = Interface.hash(new_interface(%{name: "InterfaceA"}))
      h2 = Interface.hash(new_interface(%{name: "InterfaceB"}))
      assert h1 != h2
    end

    test "same name produces same hash" do
      h1 = Interface.hash(new_interface(%{name: "TestInterface"}))
      h2 = Interface.hash(new_interface(%{name: "TestInterface"}))
      assert h1 == h2
    end

    test "nil name hashes empty string" do
      hash = Interface.hash(new_interface(%{name: nil}))
      assert byte_size(hash) == 32
    end
  end

  # ── age/1 ──────────────────────────────────────────────────────────

  describe "age/1" do
    test "returns time since creation" do
      iface = new_interface(%{created: System.system_time(:second) - 100})
      age = Interface.age(iface)
      assert age >= 99
      assert age <= 102
    end

    test "newly created interface has age near zero" do
      iface = new_interface()
      age = Interface.age(iface)
      assert age >= 0
      assert age <= 2
    end

    test "returns 0 for nil created" do
      iface = new_interface(%{created: nil})
      assert Interface.age(iface) == 0.0
    end
  end

  # ── optimise_mtu/1 ────────────────────────────────────────────────

  describe "optimise_mtu/1" do
    test "does nothing when autoconfigure_mtu is false" do
      iface = new_interface(%{autoconfigure_mtu: false, bitrate: 1_000_000_000, hw_mtu: nil})
      result = Interface.optimise_mtu(iface)
      assert result.hw_mtu == nil
    end

    test "sets 524288 for >= 1 Gbps" do
      iface = new_interface(%{autoconfigure_mtu: true, bitrate: 1_000_000_000})
      assert Interface.optimise_mtu(iface).hw_mtu == 524_288
    end

    test "sets 262144 for > 750 Mbps" do
      iface = new_interface(%{autoconfigure_mtu: true, bitrate: 800_000_000})
      assert Interface.optimise_mtu(iface).hw_mtu == 262_144
    end

    test "sets 131072 for > 400 Mbps" do
      iface = new_interface(%{autoconfigure_mtu: true, bitrate: 500_000_000})
      assert Interface.optimise_mtu(iface).hw_mtu == 131_072
    end

    test "sets 65536 for > 200 Mbps" do
      iface = new_interface(%{autoconfigure_mtu: true, bitrate: 250_000_000})
      assert Interface.optimise_mtu(iface).hw_mtu == 65_536
    end

    test "sets 32768 for > 100 Mbps" do
      iface = new_interface(%{autoconfigure_mtu: true, bitrate: 150_000_000})
      assert Interface.optimise_mtu(iface).hw_mtu == 32_768
    end

    test "sets 16384 for > 10 Mbps" do
      iface = new_interface(%{autoconfigure_mtu: true, bitrate: 50_000_000})
      assert Interface.optimise_mtu(iface).hw_mtu == 16_384
    end

    test "sets 8192 for > 5 Mbps" do
      iface = new_interface(%{autoconfigure_mtu: true, bitrate: 6_000_000})
      assert Interface.optimise_mtu(iface).hw_mtu == 8_192
    end

    test "sets 4096 for > 2 Mbps" do
      iface = new_interface(%{autoconfigure_mtu: true, bitrate: 3_000_000})
      assert Interface.optimise_mtu(iface).hw_mtu == 4_096
    end

    test "sets 2048 for > 1 Mbps" do
      iface = new_interface(%{autoconfigure_mtu: true, bitrate: 1_500_000})
      assert Interface.optimise_mtu(iface).hw_mtu == 2_048
    end

    test "sets 1024 for > 62500 bps" do
      iface = new_interface(%{autoconfigure_mtu: true, bitrate: 100_000})
      assert Interface.optimise_mtu(iface).hw_mtu == 1_024
    end

    test "sets nil for <= 62500 bps" do
      iface = new_interface(%{autoconfigure_mtu: true, bitrate: 62_500})
      assert Interface.optimise_mtu(iface).hw_mtu == nil
    end
  end

  # ── Announce frequency tracking ────────────────────────────────────

  describe "received_announce/1" do
    test "adds timestamp to ia_freq_deque" do
      iface = new_interface()
      assert iface.ia_freq_deque == []
      iface = Interface.received_announce(iface)
      assert length(iface.ia_freq_deque) == 1
    end

    test "caps deque at IA_FREQ_SAMPLES" do
      iface = new_interface()

      iface =
        Enum.reduce(1..10, iface, fn _, acc ->
          Interface.received_announce(acc)
        end)

      assert length(iface.ia_freq_deque) == Interface.ia_freq_samples()
    end
  end

  describe "sent_announce/1" do
    test "adds timestamp to oa_freq_deque" do
      iface = new_interface()
      assert iface.oa_freq_deque == []
      iface = Interface.sent_announce(iface)
      assert length(iface.oa_freq_deque) == 1
    end

    test "caps deque at OA_FREQ_SAMPLES" do
      iface = new_interface()

      iface =
        Enum.reduce(1..10, iface, fn _, acc ->
          Interface.sent_announce(acc)
        end)

      assert length(iface.oa_freq_deque) == Interface.oa_freq_samples()
    end
  end

  describe "incoming_announce_frequency/1" do
    test "returns 0 with fewer than 2 samples" do
      iface = new_interface()
      assert Interface.incoming_announce_frequency(iface) == 0.0
      iface = Interface.received_announce(iface)
      assert Interface.incoming_announce_frequency(iface) == 0.0
    end

    test "returns positive value with multiple samples" do
      now = System.system_time(:second)
      iface = new_interface(%{ia_freq_deque: [now - 2, now - 1, now]})
      freq = Interface.incoming_announce_frequency(iface)
      assert freq > 0.0
    end

    test "higher rate of announces produces higher frequency" do
      now = System.system_time(:second)
      # Fast: 1 second apart
      fast = new_interface(%{ia_freq_deque: [now - 2, now - 1, now]})
      # Slow: 10 seconds apart
      slow = new_interface(%{ia_freq_deque: [now - 20, now - 10, now]})

      assert Interface.incoming_announce_frequency(fast) >
               Interface.incoming_announce_frequency(slow)
    end
  end

  describe "outgoing_announce_frequency/1" do
    test "returns 0 with fewer than 2 samples" do
      iface = new_interface()
      assert Interface.outgoing_announce_frequency(iface) == 0.0
    end

    test "returns positive value with multiple samples" do
      now = System.system_time(:second)
      iface = new_interface(%{oa_freq_deque: [now - 2, now - 1, now]})
      freq = Interface.outgoing_announce_frequency(iface)
      assert freq > 0.0
    end
  end

  # ── should_ingress_limit/1 ─────────────────────────────────────────

  describe "should_ingress_limit/1" do
    test "returns false when ingress_control is disabled" do
      iface = new_interface(%{ingress_control: false})
      {result, _updated} = Interface.should_ingress_limit(iface)
      assert result == false
    end

    test "returns false when frequency is below threshold" do
      iface = new_interface(%{ia_freq_deque: []})
      {result, _updated} = Interface.should_ingress_limit(iface)
      assert result == false
    end

    test "activates burst when frequency exceeds threshold" do
      now = System.system_time(:second)
      # Simulate very rapid announces (high frequency)
      rapid_deque = Enum.map(0..5, fn i -> now - (5 - i) * 0.05 end)

      iface =
        new_interface(%{
          ia_freq_deque: rapid_deque,
          ic_burst_freq: 1.0,
          ic_burst_active: false
        })

      {result, updated} = Interface.should_ingress_limit(iface)
      assert result == true
      assert updated.ic_burst_active == true
    end

    test "deactivates burst after hold period when frequency drops" do
      now = System.system_time(:second)

      iface =
        new_interface(%{
          ic_burst_active: true,
          ic_burst_activated: now - 120,
          ic_burst_hold: 60,
          ic_burst_penalty: 300,
          ia_freq_deque: [now - 100, now - 50],
          ic_burst_freq: 100.0,
          ic_burst_freq_new: 100.0
        })

      {result, updated} = Interface.should_ingress_limit(iface)
      assert result == true
      assert updated.ic_burst_active == false
      assert updated.ic_held_release > now
    end

    test "stays in burst when hold period not elapsed" do
      now = System.system_time(:second)

      iface =
        new_interface(%{
          ic_burst_active: true,
          ic_burst_activated: now - 10,
          ic_burst_hold: 60,
          ia_freq_deque: [now - 2, now - 1]
        })

      {result, updated} = Interface.should_ingress_limit(iface)
      assert result == true
      assert updated.ic_burst_active == true
    end
  end

  # ── hold_announce/2 ────────────────────────────────────────────────

  describe "hold_announce/2" do
    test "adds announce to held list" do
      iface = new_interface()
      packet = %{destination_hash: <<1, 2, 3>>, hops: 1}
      updated = Interface.hold_announce(iface, packet)
      assert map_size(updated.held_announces) == 1
      assert updated.held_announces[<<1, 2, 3>>] == packet
    end

    test "updates existing entry for same destination" do
      iface = new_interface()
      packet1 = %{destination_hash: <<1, 2, 3>>, hops: 3}
      packet2 = %{destination_hash: <<1, 2, 3>>, hops: 1}
      updated = iface |> Interface.hold_announce(packet1) |> Interface.hold_announce(packet2)
      assert map_size(updated.held_announces) == 1
      assert updated.held_announces[<<1, 2, 3>>].hops == 1
    end

    test "respects max held announces limit" do
      iface = new_interface(%{ic_max_held_announces: 2})
      p1 = %{destination_hash: <<1>>, hops: 1}
      p2 = %{destination_hash: <<2>>, hops: 2}
      p3 = %{destination_hash: <<3>>, hops: 3}

      updated =
        iface
        |> Interface.hold_announce(p1)
        |> Interface.hold_announce(p2)
        |> Interface.hold_announce(p3)

      assert map_size(updated.held_announces) == 2
      # Third packet should not have been added
      refute Map.has_key?(updated.held_announces, <<3>>)
    end

    test "allows updating existing even when at limit" do
      iface = new_interface(%{ic_max_held_announces: 2})
      p1 = %{destination_hash: <<1>>, hops: 1}
      p2 = %{destination_hash: <<2>>, hops: 2}
      p2_updated = %{destination_hash: <<2>>, hops: 0}

      updated =
        iface
        |> Interface.hold_announce(p1)
        |> Interface.hold_announce(p2)
        |> Interface.hold_announce(p2_updated)

      assert map_size(updated.held_announces) == 2
      assert updated.held_announces[<<2>>].hops == 0
    end
  end

  # ── process_held_announces/1 ───────────────────────────────────────

  describe "process_held_announces/1" do
    test "returns nil when no held announces" do
      iface = new_interface()
      {packet, _updated} = Interface.process_held_announces(iface)
      assert packet == nil
    end

    test "returns nil when ingress limiting is active" do
      now = System.system_time(:second)
      rapid_deque = Enum.map(0..5, fn i -> now - (5 - i) * 0.05 end)

      iface =
        new_interface(%{
          held_announces: %{<<1>> => %{destination_hash: <<1>>, hops: 1}},
          ia_freq_deque: rapid_deque,
          ic_burst_freq: 0.1,
          ic_burst_active: true,
          ic_burst_activated: now
        })

      {packet, _updated} = Interface.process_held_announces(iface)
      assert packet == nil
    end

    test "releases lowest-hop announce when conditions are met" do
      now = System.system_time(:second)
      p1 = %{destination_hash: <<1>>, hops: 5}
      p2 = %{destination_hash: <<2>>, hops: 2}
      p3 = %{destination_hash: <<3>>, hops: 8}

      iface =
        new_interface(%{
          held_announces: %{<<1>> => p1, <<2>> => p2, <<3>> => p3},
          ic_held_release: now - 1,
          ic_burst_active: false,
          ia_freq_deque: []
        })

      {packet, updated} = Interface.process_held_announces(iface)
      assert packet != nil
      assert packet.hops == 2
      assert map_size(updated.held_announces) == 2
      refute Map.has_key?(updated.held_announces, <<2>>)
    end

    test "updates ic_held_release after releasing" do
      now = System.system_time(:second)

      iface =
        new_interface(%{
          held_announces: %{<<1>> => %{destination_hash: <<1>>, hops: 1}},
          ic_held_release: now - 1,
          ic_burst_active: false,
          ia_freq_deque: []
        })

      {_packet, updated} = Interface.process_held_announces(iface)
      assert updated.ic_held_release > now
    end
  end

  # ── process_announce_queue/1 ───────────────────────────────────────

  describe "process_announce_queue/1" do
    test "returns nil when queue is empty" do
      iface = new_interface(%{announce_queue: []})
      {selected, _wait, _updated} = Interface.process_announce_queue(iface)
      assert selected == nil
    end

    test "selects lowest hop entry" do
      now = System.system_time(:second)

      q = [
        %AnnounceQueueEntry{raw: <<1, 2, 3>>, hops: 5, time: now},
        %AnnounceQueueEntry{raw: <<4, 5, 6>>, hops: 2, time: now},
        %AnnounceQueueEntry{raw: <<7, 8, 9>>, hops: 8, time: now}
      ]

      iface = new_interface(%{announce_queue: q})
      {selected, _wait, updated} = Interface.process_announce_queue(iface)
      assert selected.hops == 2
      assert selected.raw == <<4, 5, 6>>
      assert length(updated.announce_queue) == 2
    end

    test "among equal hops, selects earliest time" do
      now = System.system_time(:second)

      q = [
        %AnnounceQueueEntry{raw: <<1>>, hops: 3, time: now - 10},
        %AnnounceQueueEntry{raw: <<2>>, hops: 3, time: now - 20},
        %AnnounceQueueEntry{raw: <<3>>, hops: 3, time: now}
      ]

      iface = new_interface(%{announce_queue: q})
      {selected, _wait, _updated} = Interface.process_announce_queue(iface)
      assert selected.raw == <<2>>
    end

    test "removes stale entries" do
      now = System.system_time(:second)

      q = [
        %AnnounceQueueEntry{raw: <<1>>, hops: 1, time: now - 7200},
        %AnnounceQueueEntry{raw: <<2>>, hops: 2, time: now}
      ]

      iface = new_interface(%{announce_queue: q})
      {selected, _wait, updated} = Interface.process_announce_queue(iface)
      assert selected.hops == 2
      assert updated.announce_queue == []
    end

    test "returns positive wait time" do
      now = System.system_time(:second)
      raw = :crypto.strong_rand_bytes(100)

      q = [%AnnounceQueueEntry{raw: raw, hops: 1, time: now}]
      iface = new_interface(%{announce_queue: q})
      {_selected, wait_ms, _updated} = Interface.process_announce_queue(iface)
      assert wait_ms >= 0
    end

    test "updates announce_allowed_at" do
      now = System.system_time(:second)
      q = [%AnnounceQueueEntry{raw: <<1, 2, 3>>, hops: 1, time: now}]
      iface = new_interface(%{announce_queue: q})
      {_selected, _wait, updated} = Interface.process_announce_queue(iface)
      assert updated.announce_allowed_at > 0
    end
  end

  # ── HDLC framing ──────────────────────────────────────────────────

  describe "HDLC constants" do
    test "FLAG is 0x7E" do
      assert HDLC.flag() == 0x7E
    end

    test "ESC is 0x7D" do
      assert HDLC.esc() == 0x7D
    end

    test "ESC_MASK is 0x20" do
      assert HDLC.esc_mask() == 0x20
    end
  end

  describe "HDLC.escape/1" do
    test "escapes FLAG byte" do
      data = <<0x7E>>
      escaped = HDLC.escape(data)
      assert escaped == <<0x7D, bxor(0x7E, 0x20)>>
      assert escaped == <<0x7D, 0x5E>>
    end

    test "escapes ESC byte" do
      data = <<0x7D>>
      escaped = HDLC.escape(data)
      assert escaped == <<0x7D, bxor(0x7D, 0x20)>>
      assert escaped == <<0x7D, 0x5D>>
    end

    test "leaves normal bytes unchanged" do
      data = <<0x01, 0x02, 0x03, 0xFF>>
      assert HDLC.escape(data) == data
    end

    test "escapes multiple special bytes" do
      data = <<0x7E, 0x41, 0x7D, 0x42, 0x7E>>
      escaped = HDLC.escape(data)
      assert escaped == <<0x7D, 0x5E, 0x41, 0x7D, 0x5D, 0x42, 0x7D, 0x5E>>
    end

    test "handles empty binary" do
      assert HDLC.escape(<<>>) == <<>>
    end
  end

  describe "HDLC.unescape/1" do
    test "unescapes FLAG escape sequence" do
      data = <<0x7D, 0x5E>>
      assert HDLC.unescape(data) == <<0x7E>>
    end

    test "unescapes ESC escape sequence" do
      data = <<0x7D, 0x5D>>
      assert HDLC.unescape(data) == <<0x7D>>
    end

    test "leaves normal bytes unchanged" do
      data = <<0x01, 0x02, 0x03>>
      assert HDLC.unescape(data) == data
    end

    test "handles empty binary" do
      assert HDLC.unescape(<<>>) == <<>>
    end
  end

  describe "HDLC escape/unescape roundtrip" do
    test "roundtrips arbitrary data" do
      data = <<0x7E, 0x7D, 0x00, 0xFF, 0x7E, 0x7D, 0x42>>
      assert HDLC.unescape(HDLC.escape(data)) == data
    end

    test "roundtrips random data" do
      data = :crypto.strong_rand_bytes(256)
      assert HDLC.unescape(HDLC.escape(data)) == data
    end

    test "roundtrips data with all byte values" do
      data = Enum.into(0..255, <<>>, fn b -> <<b>> end)
      assert HDLC.unescape(HDLC.escape(data)) == data
    end
  end

  describe "HDLC.frame/1" do
    test "frames data with FLAG delimiters" do
      data = <<0x01, 0x02, 0x03>>
      framed = HDLC.frame(data)
      assert :binary.first(framed) == 0x7E
      assert :binary.last(framed) == 0x7E
    end

    test "escapes content within frame" do
      data = <<0x7E, 0x7D>>
      framed = HDLC.frame(data)
      assert framed == <<0x7E, 0x7D, 0x5E, 0x7D, 0x5D, 0x7E>>
    end
  end

  describe "HDLC.deframe/1" do
    test "extracts single frame" do
      payload = <<0x01, 0x02, 0x03>>
      buffer = HDLC.frame(payload)
      {frames, remaining} = HDLC.deframe(buffer)
      assert frames == [payload]
      assert remaining == <<>>
    end

    test "extracts multiple frames" do
      p1 = <<0x01, 0x02>>
      p2 = <<0x03, 0x04>>
      buffer = HDLC.frame(p1) <> HDLC.frame(p2)
      {frames, _remaining} = HDLC.deframe(buffer)
      assert length(frames) == 2
      assert p1 in frames
      assert p2 in frames
    end

    test "handles incomplete frame" do
      buffer = <<0x7E, 0x01, 0x02>>
      {frames, remaining} = HDLC.deframe(buffer)
      assert frames == []
      assert remaining == buffer
    end

    test "handles data with escaped special bytes" do
      payload = <<0x7E, 0x7D, 0x42>>
      buffer = HDLC.frame(payload)
      {frames, _remaining} = HDLC.deframe(buffer)
      assert frames == [payload]
    end

    test "handles empty buffer" do
      {frames, remaining} = HDLC.deframe(<<>>)
      assert frames == []
      assert remaining == <<>>
    end

    test "roundtrips random payloads" do
      payloads = Enum.map(1..5, fn _ -> :crypto.strong_rand_bytes(64) end)
      buffer = Enum.reduce(payloads, <<>>, fn p, acc -> acc <> HDLC.frame(p) end)
      {frames, _remaining} = HDLC.deframe(buffer)
      assert Enum.sort(frames) == Enum.sort(payloads)
    end
  end

  # ── KISS framing ───────────────────────────────────────────────────

  describe "KISS constants" do
    test "FEND is 0xC0" do
      assert KISS.fend() == 0xC0
    end

    test "FESC is 0xDB" do
      assert KISS.fesc() == 0xDB
    end

    test "TFEND is 0xDC" do
      assert KISS.tfend() == 0xDC
    end

    test "TFESC is 0xDD" do
      assert KISS.tfesc() == 0xDD
    end

    test "CMD_DATA is 0x00" do
      assert KISS.cmd_data() == 0x00
    end
  end

  describe "KISS.escape/1" do
    test "escapes FEND byte" do
      data = <<0xC0>>
      escaped = KISS.escape(data)
      assert escaped == <<0xDB, 0xDC>>
    end

    test "escapes FESC byte" do
      data = <<0xDB>>
      escaped = KISS.escape(data)
      assert escaped == <<0xDB, 0xDD>>
    end

    test "leaves normal bytes unchanged" do
      data = <<0x01, 0x02, 0xFF>>
      assert KISS.escape(data) == data
    end

    test "handles empty binary" do
      assert KISS.escape(<<>>) == <<>>
    end

    test "escapes multiple special bytes" do
      data = <<0xC0, 0x41, 0xDB, 0xC0>>
      escaped = KISS.escape(data)
      assert escaped == <<0xDB, 0xDC, 0x41, 0xDB, 0xDD, 0xDB, 0xDC>>
    end
  end

  describe "KISS.unescape/1" do
    test "unescapes FEND sequence" do
      data = <<0xDB, 0xDC>>
      assert KISS.unescape(data) == <<0xC0>>
    end

    test "unescapes FESC sequence" do
      data = <<0xDB, 0xDD>>
      assert KISS.unescape(data) == <<0xDB>>
    end

    test "leaves normal bytes unchanged" do
      data = <<0x01, 0x02, 0x03>>
      assert KISS.unescape(data) == data
    end

    test "handles empty binary" do
      assert KISS.unescape(<<>>) == <<>>
    end
  end

  describe "KISS escape/unescape roundtrip" do
    test "roundtrips data with all byte values" do
      data = Enum.into(0..255, <<>>, fn b -> <<b>> end)
      assert KISS.unescape(KISS.escape(data)) == data
    end

    test "roundtrips random data" do
      data = :crypto.strong_rand_bytes(256)
      assert KISS.unescape(KISS.escape(data)) == data
    end
  end

  describe "KISS.frame/1" do
    test "frames data with FEND delimiters and CMD_DATA" do
      data = <<0x01, 0x02, 0x03>>
      framed = KISS.frame(data)
      assert :binary.first(framed) == 0xC0
      assert :binary.at(framed, 1) == 0x00
      assert :binary.last(framed) == 0xC0
    end

    test "escapes content within frame" do
      data = <<0xC0, 0xDB>>
      framed = KISS.frame(data)
      assert framed == <<0xC0, 0x00, 0xDB, 0xDC, 0xDB, 0xDD, 0xC0>>
    end
  end

  describe "KISS.deframe/1" do
    test "extracts single frame" do
      payload = <<0x01, 0x02, 0x03>>
      buffer = KISS.frame(payload)
      {frames, _remaining} = KISS.deframe(buffer)
      assert length(frames) == 1
      [{cmd, data}] = frames
      assert cmd == 0x00
      assert data == payload
    end

    test "extracts multiple frames" do
      p1 = <<0x01, 0x02>>
      p2 = <<0x03, 0x04>>
      buffer = KISS.frame(p1) <> KISS.frame(p2)
      {frames, _remaining} = KISS.deframe(buffer)
      assert length(frames) == 2
    end

    test "handles data with escaped bytes" do
      payload = <<0xC0, 0xDB, 0x42>>
      buffer = KISS.frame(payload)
      {frames, _remaining} = KISS.deframe(buffer)
      [{_cmd, data}] = frames
      assert data == payload
    end

    test "handles empty buffer" do
      {frames, remaining} = KISS.deframe(<<>>)
      assert frames == []
      assert remaining == <<>>
    end
  end

  # ── AnnounceQueueEntry struct ──────────────────────────────────────

  describe "AnnounceQueueEntry" do
    test "creates struct with all fields" do
      entry = %AnnounceQueueEntry{raw: <<1, 2, 3>>, hops: 3, time: 12_345}
      assert entry.raw == <<1, 2, 3>>
      assert entry.hops == 3
      assert entry.time == 12_345
    end

    test "defaults to nil fields" do
      entry = %AnnounceQueueEntry{}
      assert entry.raw == nil
      assert entry.hops == nil
      assert entry.time == nil
    end
  end
end
