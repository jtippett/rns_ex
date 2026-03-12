defmodule RNS.Channel.TestOutlet do
  @moduledoc false
  # A mock outlet for testing Channel independently of Link/Transport.
  # Uses an Agent to track mutable state (sent packets, callbacks, etc.)

  defstruct [:agent, mdu_val: 500, rtt_val: 0.1, usable: true]

  def new(opts \\ []) do
    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          packets: [],
          delivered_callbacks: %{},
          timeout_callbacks: %{},
          packet_states: %{},
          next_id: 0,
          timed_out: false
        }
      end)

    %__MODULE__{
      agent: agent,
      mdu_val: Keyword.get(opts, :mdu, 500),
      rtt_val: Keyword.get(opts, :rtt, 0.1),
      usable: Keyword.get(opts, :usable, true)
    }
  end

  def get_packets(outlet) do
    Agent.get(outlet.agent, fn state -> state.packets end)
  end

  def deliver_packet(outlet, packet_id) do
    Agent.update(outlet.agent, fn state ->
      %{
        state
        | packet_states:
            Map.put(state.packet_states, packet_id, RNS.Channel.msgstate_delivered())
      }
    end)
  end

  def set_rtt(outlet, rtt) do
    Agent.update(outlet.agent, fn state -> Map.put(state, :rtt_override, rtt) end)
  end

  def was_timed_out?(outlet) do
    Agent.get(outlet.agent, fn state -> state.timed_out end)
  end

  def get_resend_count(outlet, packet_id) do
    Agent.get(outlet.agent, fn state -> Map.get(state, {:resend, packet_id}, 0) end)
  end

  def stop(outlet) do
    Agent.stop(outlet.agent)
  end
end

defimpl RNS.Channel.Outlet, for: RNS.Channel.TestOutlet do
  def send_raw(%{agent: agent}, raw) do
    Agent.get_and_update(agent, fn state ->
      id = state.next_id
      packet = %{id: id, raw: raw}

      state = %{
        state
        | packets: state.packets ++ [packet],
          next_id: id + 1,
          packet_states: Map.put(state.packet_states, id, RNS.Channel.msgstate_sent())
      }

      {packet, state}
    end)
  end

  def resend(%{agent: agent}, packet) do
    if packet != nil do
      Agent.update(agent, fn state ->
        key = {:resend, packet.id}
        count = Map.get(state, key, 0)
        Map.put(state, key, count + 1)
      end)
    end

    packet
  end

  def mdu(%{mdu_val: mdu}), do: mdu

  def rtt(%{agent: agent, rtt_val: default_rtt}) do
    Agent.get(agent, fn state -> Map.get(state, :rtt_override, default_rtt) end)
  end

  def is_usable(%{usable: usable}), do: usable

  def get_packet_state(%{agent: agent}, packet) do
    if packet == nil do
      RNS.Channel.msgstate_failed()
    else
      Agent.get(agent, fn state ->
        Map.get(state.packet_states, packet.id, RNS.Channel.msgstate_sent())
      end)
    end
  end

  def timed_out(%{agent: agent}) do
    Agent.update(agent, fn state -> %{state | timed_out: true} end)
    :ok
  end

  def set_packet_timeout_callback(%{agent: agent}, packet, callback, timeout) do
    if packet != nil do
      Agent.update(agent, fn state ->
        %{
          state
          | timeout_callbacks: Map.put(state.timeout_callbacks, packet.id, {callback, timeout})
        }
      end)
    end

    :ok
  end

  def set_packet_delivered_callback(%{agent: agent}, packet, callback) do
    if packet != nil do
      Agent.update(agent, fn state ->
        %{state | delivered_callbacks: Map.put(state.delivered_callbacks, packet.id, callback)}
      end)
    end

    :ok
  end

  def get_packet_id(_outlet, packet) do
    if packet != nil and is_map(packet), do: packet.id, else: nil
  end
end
