defmodule RNS.Interfaces.WeaveInterface do
  @moduledoc """
  Weave interface for RNS.

  Provides connectivity to Weave-compatible mesh networking devices via
  serial communication using the Weave Device Command Language (WDCL)
  protocol. Supports peer discovery, endpoint routing, statistics
  monitoring, and remote display functionality.

  The WeaveInterface manages a WDCL connection to a Weave device and
  spawns `WeaveInterfacePeer` sub-interfaces for each discovered
  remote endpoint. Multi-interface deduplication prevents processing
  the same packet from different peers.
  """

  use GenServer
  use RNS.Interfaces.Interface

  require Logger

  alias RNS.Interfaces.WeaveInterface.{WDCL, WeaveInterfacePeer}

  # ── Interface constants ────────────────────────────────────────────

  @hw_mtu 1024
  @fixed_mtu true
  @default_ifac_size 16
  @peering_timeout 20.0
  @bitrate_guess 250_000

  @multi_if_deque_len 48
  @multi_if_deque_ttl 0.75

  # ── Struct ─────────────────────────────────────────────────────────

  defstruct default_fields() ++
              [
                port: nil,
                switch_identity: nil,
                switch_id: nil,
                switch_pub_bytes: nil,
                device: nil,
                connection: nil,
                peers: %{},
                timed_out_interfaces: %{},
                mif_deque: :queue.new(),
                mif_deque_times: :queue.new(),
                peer_job_interval: round(@peering_timeout * 1.1 * 1000),
                peering_timeout: @peering_timeout,
                receives: true,
                hw_errors: [],
                _online: false,
                final_init_done: false,
                owner: nil,
                server_name: nil,
                skip_wdcl: false,
                ifac_netname: nil,
                ifac_netkey: nil,
                announce_rate_grace: nil,
                announce_rate_penalty: nil
              ]

  @doc "Returns all public constants."
  def constants do
    %{
      hw_mtu: @hw_mtu,
      fixed_mtu: @fixed_mtu,
      default_ifac_size: @default_ifac_size,
      peering_timeout: @peering_timeout,
      bitrate_guess: @bitrate_guess,
      multi_if_deque_len: @multi_if_deque_len,
      multi_if_deque_ttl: @multi_if_deque_ttl
    }
  end

  # ── Public API ─────────────────────────────────────────────────────

  def start_link(opts) do
    name = Keyword.get(opts, :name, "WeaveInterface")
    server_name = Keyword.get(opts, :server_name)
    gen_opts = if server_name, do: [name: server_name], else: []
    GenServer.start_link(__MODULE__, [{:interface_name, name} | opts], gen_opts)
  end

  @impl true
  def init(opts) do
    interface_name = Keyword.get(opts, :interface_name, "WeaveInterface")
    port = Keyword.get(opts, :port)
    owner = Keyword.get(opts, :owner)
    configured_bitrate = Keyword.get(opts, :configured_bitrate)
    skip_wdcl = Keyword.get(opts, :skip_wdcl, false)

    bitrate = configured_bitrate || @bitrate_guess
    hash = RNS.Interfaces.Interface.hash(%{name: interface_name})

    state = %__MODULE__{
      name: interface_name,
      hash: hash,
      port: port,
      owner: owner,
      bitrate: bitrate,
      skip_wdcl: skip_wdcl,
      ifac_size: @default_ifac_size,
      hw_mtu: @hw_mtu,
      fixed_mtu: @fixed_mtu,
      _online: false,
      in: true,
      out: false,
      created: System.system_time(:second)
    }

    if not skip_wdcl do
      # Schedule peer job
      Process.send_after(self(), :peer_jobs, state.peer_job_interval)
    end

    {:ok, state}
  end

  # ── Peer management ────────────────────────────────────────────────

  @doc "Get the number of spawned peer interfaces."
  @spec peer_count(map()) :: non_neg_integer()
  def peer_count(state), do: map_size(state.spawned_interfaces)

  @doc "Add a new peer or refresh an existing one."
  @spec add_peer(map(), binary()) :: map()
  def add_peer(state, endpoint_addr) do
    if Map.has_key?(state.peers, endpoint_addr) do
      refresh_peer(state, endpoint_addr)
    else
      peer =
        WeaveInterfacePeer.new(
          owner: state,
          endpoint_addr: endpoint_addr,
          hw_mtu: @hw_mtu,
          fixed_mtu: @fixed_mtu,
          bitrate: state.bitrate,
          ifac_size: state.ifac_size,
          ifac_netname: state.ifac_netname,
          ifac_netkey: state.ifac_netkey,
          announce_rate_target: state.announce_rate_target,
          mode: state.mode
        )

      # Remove existing spawned interface for same addr if exists
      state =
        if Map.has_key?(state.spawned_interfaces, endpoint_addr) do
          old_peer = state.spawned_interfaces[endpoint_addr]
          old_peer = WeaveInterfacePeer.detach(old_peer)
          _old_peer = WeaveInterfacePeer.teardown(old_peer)
          %{state | spawned_interfaces: Map.delete(state.spawned_interfaces, endpoint_addr)}
        else
          state
        end

      peer = %{peer | _online: true}

      peers =
        Map.put(state.peers, endpoint_addr, %{
          addr: endpoint_addr,
          last_heard: System.system_time(:millisecond) / 1000,
          interface: peer
        })

      spawned_interfaces = Map.put(state.spawned_interfaces, endpoint_addr, peer)

      %{state | peers: peers, spawned_interfaces: spawned_interfaces}
    end
  end

  @doc "Refresh a peer's last_heard timestamp."
  @spec refresh_peer(map(), binary()) :: map()
  def refresh_peer(state, endpoint_addr) do
    case Map.get(state.peers, endpoint_addr) do
      nil ->
        state

      peer_entry ->
        peers =
          Map.put(state.peers, endpoint_addr, %{
            peer_entry
            | last_heard: System.system_time(:millisecond) / 1000
          })

        %{state | peers: peers}
    end
  end

  @doc "Update endpoint routing via switch."
  @spec endpoint_via(map(), binary(), binary()) :: map()
  def endpoint_via(state, endpoint_addr, via_switch_id) do
    case Map.get(state.spawned_interfaces, endpoint_addr) do
      nil ->
        state

      peer ->
        peer = %{peer | via_switch_id: via_switch_id}
        %{state | spawned_interfaces: Map.put(state.spawned_interfaces, endpoint_addr, peer)}
    end
  end

  @impl true
  @doc "Process incoming data from a specific endpoint."
  @spec process_incoming(map(), binary(), binary() | nil) :: {:ok, map()} | {:error, term()}
  def process_incoming(state, data, endpoint_addr \\ nil) do
    if state._online and endpoint_addr != nil and
         Map.has_key?(state.spawned_interfaces, endpoint_addr) do
      peer = state.spawned_interfaces[endpoint_addr]
      {peer, state} = WeaveInterfacePeer.process_incoming(peer, data, state)
      {:ok, %{state | spawned_interfaces: Map.put(state.spawned_interfaces, endpoint_addr, peer)}}
    else
      {:ok, state}
    end
  end

  @impl true
  @doc "Process outgoing data (no-op on parent)."
  @spec process_outgoing(map(), binary()) :: {:ok, map()} | {:error, term()}
  def process_outgoing(state, _data), do: {:ok, state}

  @impl true
  @doc "Detach the interface."
  @spec detach(map()) :: :ok | map()
  def detach(state) do
    %{state | _online: false}
  end

  @doc "Check if the interface is online."
  @spec online?(map()) :: boolean()
  def online?(%{_online: false}), do: false
  def online?(%{connection: nil}), do: false
  def online?(%{connection: conn}), do: conn.online
  def online?(%{skip_wdcl: true, _online: true}), do: true
  def online?(_), do: false

  @doc "Should ingress limit always returns false."
  @spec should_ingress_limit(map()) :: {boolean(), map()}
  def should_ingress_limit(state), do: {false, state}

  @doc "Multi-interface deque check for deduplication."
  @spec mif_deque_check(map(), binary()) :: {boolean(), map()}
  def mif_deque_check(state, data) do
    data_hash = RNS.Identity.full_hash(data)
    now = System.system_time(:millisecond) / 1000

    # Check if hash exists in deque with valid TTL
    deque_hit = check_deque_hit(state.mif_deque, state.mif_deque_times, data_hash, now)

    if deque_hit do
      {true, state}
    else
      # Add to deques
      mif_deque = bounded_enqueue(state.mif_deque, data_hash, @multi_if_deque_len)

      mif_deque_times =
        bounded_enqueue(state.mif_deque_times, {data_hash, now}, @multi_if_deque_len)

      {false, %{state | mif_deque: mif_deque, mif_deque_times: mif_deque_times}}
    end
  end

  defp check_deque_hit(deque, times_deque, data_hash, now) do
    deque_list = :queue.to_list(deque)

    if data_hash in deque_list do
      times_list = :queue.to_list(times_deque)

      Enum.any?(times_list, fn
        {hash, time} -> hash == data_hash and now < time + @multi_if_deque_ttl
        _ -> false
      end)
    else
      false
    end
  end

  defp bounded_enqueue(queue, item, max_len) do
    queue = :queue.in(item, queue)

    if :queue.len(queue) > max_len do
      {_, queue} = :queue.out(queue)
      queue
    else
      queue
    end
  end

  # ── GenServer callbacks ────────────────────────────────────────────

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}
  def handle_call(:peer_count, _from, state), do: {:reply, peer_count(state), state}

  @impl true
  def handle_cast({:deliver_outgoing, command_data}, state) do
    if state.connection && state.connection.switch_id do
      frame = WDCL.build_send(state.connection.switch_id, WDCL.constants().wdcl_t_cmd, command_data)
      {_framed, conn} = WDCL.process_outgoing(state.connection, frame)
      {:noreply, %{state | connection: conn, txb: state.txb + byte_size(command_data)}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:peer_jobs, state) do
    now = System.system_time(:millisecond) / 1000

    # Find timed-out peers
    timed_out =
      Enum.filter(state.peers, fn {_addr, peer} ->
        now > peer.last_heard + state.peering_timeout
      end)

    # Remove timed-out peers
    state =
      Enum.reduce(timed_out, state, fn {addr, _peer}, acc ->
        acc = %{acc | peers: Map.delete(acc.peers, addr)}

        case Map.get(acc.spawned_interfaces, addr) do
          nil ->
            acc

          spawned ->
            _spawned = WeaveInterfacePeer.detach(spawned)
            %{acc | spawned_interfaces: Map.delete(acc.spawned_interfaces, addr)}
        end
      end)

    # Schedule next peer job
    Process.send_after(self(), :peer_jobs, state.peer_job_interval)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defimpl String.Chars, for: __MODULE__ do
    def to_string(interface) do
      "WeaveInterface[#{interface.name}]"
    end
  end
end

defmodule RNS.Interfaces.WeaveInterface.WDCL do
  @moduledoc """
  Weave Device Command Language (WDCL) protocol.

  Handles serial communication with Weave devices including HDLC framing,
  packet types (DISCOVER, CONNECT, CMD, LOG, DISP, ENDPOINT_PKT, ENCAP_PROTO),
  and the WDCL handshake protocol.
  """

  alias RNS.Interfaces.Interface.HDLC
  alias RNS.Interfaces.WeaveInterface.WeaveDevice

  # WDCL packet types
  @wdcl_t_discover 0x00
  @wdcl_t_connect 0x01
  @wdcl_t_cmd 0x02
  @wdcl_t_log 0x03
  @wdcl_t_disp 0x04
  @wdcl_t_endpoint_pkt 0x05
  @wdcl_t_encap_proto 0x06

  @wdcl_broadcast <<0xFF, 0xFF, 0xFF, 0xFF>>
  @wdcl_handshake_timeout 2

  @header_minsize 5
  @max_chunk 32_768
  @default_speed 3_000_000

  defstruct [
    :owner,
    :device,
    :port,
    :serial,
    :as_interface,
    speed: @default_speed,
    databits: 8,
    parity: :none,
    stopbits: 1,
    timeout: 100,
    online: false,
    frame_buffer: <<>>,
    next_tx: 0,
    should_run: true,
    wdcl_connected: false,
    reconnecting: false,
    switch_id: nil,
    switch_pub_bytes: nil,
    rxb: 0,
    txb: 0
  ]

  @doc "Returns all public constants."
  def constants do
    %{
      wdcl_t_discover: @wdcl_t_discover,
      wdcl_t_connect: @wdcl_t_connect,
      wdcl_t_cmd: @wdcl_t_cmd,
      wdcl_t_log: @wdcl_t_log,
      wdcl_t_disp: @wdcl_t_disp,
      wdcl_t_endpoint_pkt: @wdcl_t_endpoint_pkt,
      wdcl_t_encap_proto: @wdcl_t_encap_proto,
      wdcl_broadcast: @wdcl_broadcast,
      wdcl_handshake_timeout: @wdcl_handshake_timeout,
      header_minsize: @header_minsize,
      max_chunk: @max_chunk,
      default_speed: @default_speed
    }
  end

  @doc "Create a new WDCL connection."
  @spec new(keyword()) :: %__MODULE__{}
  def new(opts \\ []) do
    owner = Keyword.get(opts, :owner)
    device = Keyword.get(opts, :device)
    port = Keyword.get(opts, :port)
    as_interface = Keyword.get(opts, :as_interface, false)

    switch_id = if owner, do: Map.get(owner, :switch_id), else: nil
    switch_pub_bytes = if owner, do: Map.get(owner, :switch_pub_bytes), else: nil

    %__MODULE__{
      owner: owner,
      device: device,
      port: port,
      as_interface: as_interface,
      switch_id: switch_id,
      switch_pub_bytes: switch_pub_bytes
    }
  end

  @doc "Build an outgoing HDLC-framed data packet."
  @spec process_outgoing(%__MODULE__{}, binary()) :: {binary(), %__MODULE__{}}
  def process_outgoing(conn, data) do
    framed = <<0x7E>> <> HDLC.escape(data) <> <<0x7E>>
    conn = %{conn | txb: conn.txb + byte_size(framed)}
    {framed, conn}
  end

  @doc "Process incoming HDLC frame."
  @spec process_incoming(%__MODULE__{}, binary()) :: %__MODULE__{}
  def process_incoming(conn, data) do
    conn = %{conn | rxb: conn.rxb + byte_size(data)}

    if conn.device do
      WeaveDevice.incoming_frame(conn.device, data)
    end

    conn
  end

  @doc "Build a WDCL discover broadcast packet."
  @spec build_discover(binary()) :: binary()
  def build_discover(switch_id) do
    @wdcl_broadcast <> <<@wdcl_t_discover>> <> switch_id
  end

  @doc "Build a WDCL send packet (to specific switch)."
  @spec build_send(binary(), byte(), binary()) :: binary()
  def build_send(switch_id, packet_type, data) do
    switch_id <> <<packet_type>> <> data
  end

  @doc "Build a WDCL command packet."
  @spec build_command(integer(), binary()) :: binary()
  def build_command(command, data) do
    <<command::unsigned-big-16>> <> data
  end

  @doc "Build a WDCL connect handshake packet."
  @spec build_connect(binary(), binary(), binary()) :: binary()
  def build_connect(switch_id, pub_bytes, signature) do
    data = pub_bytes <> signature
    build_send(switch_id, @wdcl_t_connect, data)
  end

  @doc "Parse a discovery response frame."
  @spec parse_discovery_response(binary()) ::
          {:ok,
           %{signed_id: binary(), pub_key: binary(), switch_id: binary(), signature: binary()}}
          | :error
  def parse_discovery_response(data) do
    switch_id_len = WeaveDevice.switch_id_len()
    pubkey_size = WeaveDevice.pubkey_size()
    signature_len = WeaveDevice.signature_len()

    expected_len = switch_id_len + 1 + pubkey_size + signature_len

    if byte_size(data) == expected_len do
      <<signed_id::binary-size(switch_id_len), _::8, pub_key::binary-size(pubkey_size),
        signature::binary-size(signature_len)>> = data

      sid_skip = pubkey_size - 4
      <<_::binary-size(sid_skip), remote_switch_id::binary-size(4)>> = pub_key

      {:ok,
       %{
         signed_id: signed_id,
         pub_key: pub_key,
         switch_id: remote_switch_id,
         signature: signature
       }}
    else
      :error
    end
  end

  @doc "Extract the packet type from a WDCL frame."
  @spec packet_type(binary()) :: byte() | nil
  def packet_type(data) do
    switch_id_len = WeaveDevice.switch_id_len()

    if byte_size(data) > switch_id_len do
      :binary.at(data, switch_id_len)
    else
      nil
    end
  end
end

defmodule RNS.Interfaces.WeaveInterface.Cmd do
  @moduledoc """
  WDCL command constants.
  """

  @wdcl_cmd_endpoint_pkt 0x0001
  @wdcl_cmd_endpoints_list 0x0100
  @wdcl_cmd_remote_display 0x0A00
  @wdcl_cmd_remote_input 0x0A01

  def endpoint_pkt, do: @wdcl_cmd_endpoint_pkt
  def endpoints_list, do: @wdcl_cmd_endpoints_list
  def remote_display, do: @wdcl_cmd_remote_display
  def remote_input, do: @wdcl_cmd_remote_input

  def constants do
    %{
      wdcl_cmd_endpoint_pkt: @wdcl_cmd_endpoint_pkt,
      wdcl_cmd_endpoints_list: @wdcl_cmd_endpoints_list,
      wdcl_cmd_remote_display: @wdcl_cmd_remote_display,
      wdcl_cmd_remote_input: @wdcl_cmd_remote_input
    }
  end
end

defmodule RNS.Interfaces.WeaveInterface.Evt do
  @moduledoc """
  WDCL event and logging constants.
  """

  # Event types
  @et_msg 0x0000
  @et_system_boot 0x0001
  @et_core_init 0x0002
  @et_drv_uart_init 0x1000
  @et_drv_usb_cdc_init 0x1010
  @et_drv_usb_cdc_host_avail 0x1011
  @et_drv_usb_cdc_host_suspend 0x1012
  @et_drv_usb_cdc_host_resume 0x1013
  @et_drv_usb_cdc_connected 0x1014
  @et_drv_usb_cdc_read_err 0x1015
  @et_drv_usb_cdc_overflow 0x1016
  @et_drv_usb_cdc_dropped 0x1017
  @et_drv_usb_cdc_tx_timeout 0x1018
  @et_drv_i2c_init 0x1020
  @et_drv_nvs_init 0x1030
  # Defined in Python but not currently used: et_drv_nvs_erase = 0x1031
  @et_drv_crypto_init 0x1040
  @et_drv_display_init 0x1050
  @et_drv_display_bus_available 0x1051
  @et_drv_display_io_configured 0x1052
  @et_drv_display_panel_created 0x1053
  @et_drv_display_panel_reset 0x1054
  @et_drv_display_panel_init 0x1055
  @et_drv_display_panel_enable 0x1056
  @et_drv_display_remote_enable 0x1057
  @et_drv_w80211_init 0x1060
  @et_drv_w80211_channel 0x1062
  @et_drv_w80211_power 0x1063
  @et_krn_logger_init 0x2000
  @et_krn_logger_output 0x2001
  @et_krn_ui_init 0x2010
  @et_proto_wdcl_init 0x3000
  @et_proto_wdcl_running 0x3001
  @et_proto_wdcl_connection 0x3002
  @et_proto_wdcl_host_endpoint 0x3003
  @et_proto_weave_init 0x3100
  @et_proto_weave_running 0x3101
  @et_proto_weave_ep_alive 0x3102
  @et_proto_weave_ep_timeout 0x3103
  @et_proto_weave_ep_via 0x3104
  @et_srvctl_remote_display 0xA000
  @et_interface_registered 0xD000
  # Defined in Python but not currently used:
  # et_stat_state = 0xE000, et_stat_uptime = 0xE001,
  # et_stat_timebase = 0xE002, et_stat_storage = 0xE006
  @et_stat_cpu 0xE003
  @et_stat_task_cpu 0xE004
  @et_stat_memory 0xE005
  @et_syserr_mem_exhausted 0xF000

  # Interface types
  @if_type_usb 0x01
  @if_type_uart 0x02
  @if_type_w80211 0x03
  @if_type_ble 0x04
  @if_type_lora 0x05
  @if_type_ethernet 0x06
  @if_type_wifi 0x07
  @if_type_tcp 0x08
  @if_type_udp 0x09
  @if_type_ir 0x0A
  @if_type_afsk 0x0B
  @if_type_gpio 0x0C
  @if_type_spi 0x0D
  @if_type_i2c 0x0E
  @if_type_can 0x0F
  @if_type_dma 0x10

  # Log levels
  @log_force 0
  @log_critical 1
  @log_error 2
  @log_warning 3
  @log_notice 4
  @log_info 5
  @log_verbose 6
  @log_debug 7
  @log_extreme 8
  @log_system 9

  @event_descriptions %{
    @et_system_boot => "System boot",
    @et_core_init => "Core initialization",
    @et_drv_uart_init => "UART driver initialization",
    @et_drv_usb_cdc_init => "USB CDC driver initialization",
    @et_drv_usb_cdc_host_avail => "USB CDC host became available",
    @et_drv_usb_cdc_host_suspend => "USB CDC host suspend",
    @et_drv_usb_cdc_host_resume => "USB CDC host resume",
    @et_drv_usb_cdc_connected => "USB CDC host connection",
    @et_drv_usb_cdc_read_err => "USB CDC read error",
    @et_drv_usb_cdc_overflow => "USB CDC overflow occurred",
    @et_drv_usb_cdc_dropped => "USB CDC dropped bytes",
    @et_drv_usb_cdc_tx_timeout => "USB CDC TX flush timeout",
    @et_drv_i2c_init => "I2C driver initialization",
    @et_drv_nvs_init => "NVS driver initialization",
    @et_drv_crypto_init => "Cryptography driver initialization",
    @et_drv_w80211_init => "W802.11 driver initialization",
    @et_drv_w80211_channel => "W802.11 channel configuration",
    @et_drv_w80211_power => "W802.11 TX power configuration",
    @et_drv_display_init => "Display driver initialization",
    @et_drv_display_bus_available => "Display bus availability",
    @et_drv_display_io_configured => "Display I/O configuration",
    @et_drv_display_panel_created => "Display panel allocation",
    @et_drv_display_panel_reset => "Display panel reset",
    @et_drv_display_panel_init => "Display panel initialization",
    @et_drv_display_panel_enable => "Display panel activation",
    @et_drv_display_remote_enable => "Remote display output activation",
    @et_krn_logger_init => "Logging service initialization",
    @et_krn_logger_output => "Logging service output activation",
    @et_krn_ui_init => "User interface service initialization",
    @et_proto_wdcl_init => "WDCL protocol initialization",
    @et_proto_wdcl_running => "WDCL protocol activation",
    @et_proto_wdcl_connection => "WDCL host connection",
    @et_proto_wdcl_host_endpoint => "Weave host endpoint",
    @et_proto_weave_init => "Weave protocol initialization",
    @et_proto_weave_running => "Weave protocol activation",
    @et_proto_weave_ep_alive => "Weave endpoint alive",
    @et_proto_weave_ep_timeout => "Weave endpoint disappeared",
    @et_srvctl_remote_display => "Remote display service control event",
    @et_interface_registered => "Interface registration",
    @et_syserr_mem_exhausted => "System memory exhausted"
  }

  @interface_types %{
    @if_type_usb => "usb",
    @if_type_uart => "uart",
    @if_type_w80211 => "mw",
    @if_type_ble => "ble",
    @if_type_lora => "lora",
    @if_type_ethernet => "eth",
    @if_type_wifi => "wifi",
    @if_type_tcp => "tcp",
    @if_type_udp => "udp",
    @if_type_ir => "ir",
    @if_type_afsk => "afsk",
    @if_type_gpio => "gpio",
    @if_type_spi => "spi",
    @if_type_i2c => "i2c",
    @if_type_can => "can",
    @if_type_dma => "dma"
  }

  @channel_descriptions %{
    1 => "Channel 1 (2412 MHz)",
    2 => "Channel 2 (2417 MHz)",
    3 => "Channel 3 (2422 MHz)",
    4 => "Channel 4 (2427 MHz)",
    5 => "Channel 5 (2432 MHz)",
    6 => "Channel 6 (2437 MHz)",
    7 => "Channel 7 (2442 MHz)",
    8 => "Channel 8 (2447 MHz)",
    9 => "Channel 9 (2452 MHz)",
    10 => "Channel 10 (2457 MHz)",
    11 => "Channel 11 (2462 MHz)",
    12 => "Channel 12 (2467 MHz)",
    13 => "Channel 13 (2472 MHz)",
    14 => "Channel 14 (2484 MHz)"
  }

  @levels %{
    @log_force => "Forced",
    @log_critical => "Critical",
    @log_error => "Error",
    @log_warning => "Warning",
    @log_notice => "Notice",
    @log_info => "Info",
    @log_verbose => "Verbose",
    @log_debug => "Debug",
    @log_extreme => "Extreme",
    @log_system => "System"
  }

  @task_descriptions %{
    "taskLVGL" => "Driver: UI Renderer",
    "ui_service" => "Service: User Interface",
    "TinyUSB" => "Driver: USB",
    "drv_w80211" => "Driver: W802.11",
    "system_stats" => "System: Stats",
    "core" => "System: Core",
    "protocol_wdcl" => "Protocol: WDCL",
    "protocol_weave" => "Protocol: Weave",
    "tiT" => "Protocol: TCP/IP",
    "ipc0" => "System: CPU 0 IPC",
    "ipc1" => "System: CPU 1 IPC",
    "esp_timer" => "Driver: Timers",
    "Tmr Svc" => "Service: Timers",
    "kernel_logger" => "Service: Logging",
    "remote_display" => "Service: Remote Display",
    "wifi" => "System: WiFi Hardware",
    "sys_evt" => "System: Kernel Events"
  }

  # Public accessors
  def et_msg, do: @et_msg
  def et_system_boot, do: @et_system_boot
  def et_core_init, do: @et_core_init
  def et_proto_wdcl_connection, do: @et_proto_wdcl_connection
  def et_proto_wdcl_host_endpoint, do: @et_proto_wdcl_host_endpoint
  def et_proto_weave_ep_alive, do: @et_proto_weave_ep_alive
  def et_proto_weave_ep_via, do: @et_proto_weave_ep_via
  def et_proto_weave_running, do: @et_proto_weave_running
  def et_stat_cpu, do: @et_stat_cpu
  def et_stat_task_cpu, do: @et_stat_task_cpu
  def et_stat_memory, do: @et_stat_memory
  def et_interface_registered, do: @et_interface_registered
  def et_drv_usb_cdc_connected, do: @et_drv_usb_cdc_connected
  def et_drv_w80211_channel, do: @et_drv_w80211_channel
  def et_drv_w80211_power, do: @et_drv_w80211_power

  def event_descriptions, do: @event_descriptions
  def interface_types, do: @interface_types
  def channel_descriptions, do: @channel_descriptions
  def levels, do: @levels
  def task_descriptions, do: @task_descriptions

  @doc "Get log level name string."
  @spec level(integer()) :: String.t()
  def level(lvl) do
    Map.get(@levels, lvl, "Unknown")
  end

  @doc "Get event description string."
  @spec event_description(integer()) :: String.t() | nil
  def event_description(evt) do
    Map.get(@event_descriptions, evt)
  end

  @doc "Get interface type name."
  @spec interface_type(integer()) :: String.t()
  def interface_type(type_code) do
    Map.get(@interface_types, type_code, "phy")
  end

  @doc "Get channel description."
  @spec channel_description(integer()) :: String.t() | nil
  def channel_description(channel) do
    Map.get(@channel_descriptions, channel)
  end

  @doc "Get task description."
  @spec task_description(String.t()) :: String.t()
  def task_description(task_id) do
    Map.get(@task_descriptions, task_id, task_id)
  end

  def constants do
    %{
      event_descriptions: @event_descriptions,
      interface_types: @interface_types,
      channel_descriptions: @channel_descriptions,
      levels: @levels,
      task_descriptions: @task_descriptions,
      et_msg: @et_msg,
      et_system_boot: @et_system_boot,
      et_proto_wdcl_connection: @et_proto_wdcl_connection,
      et_proto_wdcl_host_endpoint: @et_proto_wdcl_host_endpoint,
      et_proto_weave_ep_alive: @et_proto_weave_ep_alive,
      et_proto_weave_ep_via: @et_proto_weave_ep_via,
      et_stat_cpu: @et_stat_cpu,
      et_stat_memory: @et_stat_memory,
      et_interface_registered: @et_interface_registered
    }
  end
end

defmodule RNS.Interfaces.WeaveInterface.LogFrame do
  @moduledoc """
  Log frame structure from Weave device.
  """

  defstruct [:timestamp, :level, :event, data: <<>>]

  @type t :: %__MODULE__{
          timestamp: non_neg_integer() | nil,
          level: non_neg_integer() | nil,
          event: non_neg_integer() | nil,
          data: binary()
        }

  @doc "Create a new LogFrame."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      timestamp: Keyword.get(opts, :timestamp),
      level: Keyword.get(opts, :level),
      event: Keyword.get(opts, :event),
      data: Keyword.get(opts, :data, <<>>)
    }
  end
end

defmodule RNS.Interfaces.WeaveInterface.WeaveEndpoint do
  @moduledoc """
  Weave endpoint representation.
  """

  @queue_len 1024

  defstruct [
    :endpoint_addr,
    alive: nil,
    via: nil,
    received: :queue.new()
  ]

  def queue_len, do: @queue_len

  @doc "Create a new endpoint."
  @spec new(binary()) :: %__MODULE__{}
  def new(endpoint_addr) do
    %__MODULE__{
      endpoint_addr: endpoint_addr,
      alive: System.system_time(:millisecond) / 1000
    }
  end

  @doc "Record a received packet."
  @spec receive_data(%__MODULE__{}, binary()) :: %__MODULE__{}
  def receive_data(endpoint, data) do
    received = :queue.in(data, endpoint.received)

    received =
      if :queue.len(received) > @queue_len do
        {_, q} = :queue.out(received)
        q
      else
        received
      end

    %{endpoint | received: received}
  end
end

defmodule RNS.Interfaces.WeaveInterface.WeaveDevice do
  @moduledoc """
  Weave device interface managing WDCL protocol communication.

  Handles discovery, handshake, endpoint management, statistics,
  and remote display for Weave-compatible devices.
  """

  require Logger

  alias RNS.Interfaces.WeaveInterface.{Cmd, Evt, LogFrame, WDCL, WeaveEndpoint}

  @statlen_max 120
  @stat_update_throttle 0.5

  @weave_switch_id_len 4
  @weave_endpoint_id_len 8
  @weave_flowseq_len 2
  @weave_hmac_len 8
  @weave_auth_len @weave_endpoint_id_len + @weave_hmac_len

  @weave_pubkey_size 32
  @weave_prvkey_size 64
  @weave_signature_len 64

  defstruct [
    :identity,
    :receiver,
    :switch_id,
    :endpoint_id,
    :owner,
    :rns_interface,
    :connection,
    as_interface: false,
    endpoints: %{},
    active_tasks: %{},
    cpu_load: 0,
    memory_total: 0,
    memory_free: 0,
    memory_used: 0,
    memory_used_pct: 0,
    log_queue: :queue.new(),
    memory_stats: :queue.new(),
    cpu_stats: :queue.new(),
    display_buffer: <<>>,
    update_display: false,
    next_update_memory: 0,
    next_update_cpu: 0
  ]

  @type t :: %__MODULE__{}

  # Public constant accessors
  def switch_id_len, do: @weave_switch_id_len
  def endpoint_id_len, do: @weave_endpoint_id_len
  def pubkey_size, do: @weave_pubkey_size
  def signature_len, do: @weave_signature_len
  def statlen_max, do: @statlen_max

  @doc "Returns all public constants."
  def constants do
    %{
      statlen_max: @statlen_max,
      stat_update_throttle: @stat_update_throttle,
      weave_switch_id_len: @weave_switch_id_len,
      weave_endpoint_id_len: @weave_endpoint_id_len,
      weave_flowseq_len: @weave_flowseq_len,
      weave_hmac_len: @weave_hmac_len,
      weave_auth_len: @weave_auth_len,
      weave_pubkey_size: @weave_pubkey_size,
      weave_prvkey_size: @weave_prvkey_size,
      weave_signature_len: @weave_signature_len
    }
  end

  @doc "Create a new WeaveDevice."
  @spec new(keyword()) :: %__MODULE__{}
  def new(opts \\ []) do
    %__MODULE__{
      as_interface: Keyword.get(opts, :as_interface, false),
      rns_interface: Keyword.get(opts, :rns_interface)
    }
  end

  @doc "Record endpoint as alive."
  @spec endpoint_alive(%__MODULE__{}, binary()) :: %__MODULE__{}
  def endpoint_alive(device, endpoint_id) do
    endpoints =
      if Map.has_key?(device.endpoints, endpoint_id) do
        ep = device.endpoints[endpoint_id]

        Map.put(device.endpoints, endpoint_id, %{
          ep
          | alive: System.system_time(:millisecond) / 1000
        })
      else
        Map.put(device.endpoints, endpoint_id, WeaveEndpoint.new(endpoint_id))
      end

    device = %{device | endpoints: endpoints}

    if device.as_interface and device.rns_interface do
      # Notify RNS interface about peer
      device
    else
      device
    end
  end

  @doc "Update endpoint routing."
  @spec endpoint_via(%__MODULE__{}, binary(), binary()) :: %__MODULE__{}
  def endpoint_via(device, endpoint_id, via_switch_id) do
    endpoints =
      case Map.get(device.endpoints, endpoint_id) do
        nil -> device.endpoints
        ep -> Map.put(device.endpoints, endpoint_id, %{ep | via: via_switch_id})
      end

    %{device | endpoints: endpoints}
  end

  @doc "Build a deliver packet command."
  @spec build_deliver_packet(binary(), binary()) :: binary()
  def build_deliver_packet(endpoint_id, data) do
    packet_data = endpoint_id <> data
    WDCL.build_command(Cmd.endpoint_pkt(), packet_data)
  end

  @doc "Process an incoming WDCL frame."
  @spec incoming_frame(%__MODULE__{}, binary()) :: %__MODULE__{}
  def incoming_frame(device, data) do
    cond do
      # Endpoint packet
      byte_size(data) > @weave_switch_id_len + 2 and
        :binary.at(data, @weave_switch_id_len) == 0x05 and
        device.connection != nil and
          binary_part(data, 0, @weave_switch_id_len) == device.connection.switch_id ->
        <<_switch_id::binary-size(@weave_switch_id_len), _cmd::8, rest::binary>> = data
        payload_len = byte_size(rest) - @weave_endpoint_id_len

        <<payload::binary-size(payload_len), src_endpoint::binary-size(@weave_endpoint_id_len)>> =
          rest

        received_packet(device, src_endpoint, payload)

      # Discovery response
      byte_size(data) > @weave_switch_id_len + 1 and
          :binary.at(data, @weave_switch_id_len) == 0x00 ->
        handle_discovery_response(device, data)

      # Log frame
      byte_size(data) > @weave_switch_id_len + 1 and
          :binary.at(data, @weave_switch_id_len) == 0x03 ->
        handle_log_frame(device, data)

      # Display frame
      byte_size(data) > @weave_switch_id_len + 10 and
          :binary.at(data, @weave_switch_id_len) == 0x04 ->
        handle_display_frame(device, data)

      true ->
        device
    end
  end

  defp received_packet(device, source, _data) do
    device = endpoint_alive(device, source)

    if device.as_interface and device.rns_interface do
      # Forward to RNS interface
      device
    else
      device
    end
  end

  defp handle_discovery_response(device, data) do
    case WDCL.parse_discovery_response(data) do
      {:ok,
       %{
         signed_id: signed_id,
         pub_key: pub_key,
         switch_id: remote_switch_id,
         signature: signature
       }} ->
        # Verify signature
        remote_identity = RNS.Identity.new(create_keys: false)
        remote_identity = RNS.Identity.load_public_key(remote_identity, pub_key <> pub_key)

        case RNS.Identity.validate(remote_identity, signature, signed_id) do
          true ->
            %{device | identity: remote_identity, switch_id: remote_switch_id}

          false ->
            device
        end

      :error ->
        device
    end
  end

  defp handle_log_frame(device, data) do
    skip_log = @weave_switch_id_len + 2
    <<_::binary-size(skip_log), fd::binary>> = data

    if byte_size(fd) >= 9 do
      <<_, ts::unsigned-big-32, lvl, evt::unsigned-big-16, rest::binary>> = fd

      frame =
        LogFrame.new(
          timestamp: ts / 1000.0,
          level: lvl,
          event: evt,
          data: rest
        )

      log_handle(device, frame)
    else
      device
    end
  end

  defp handle_display_frame(device, data) do
    skip_disp = @weave_switch_id_len + 1
    <<_::binary-size(skip_disp), fd::binary>> = data

    if byte_size(fd) >= 10 do
      <<_cf, ofs::unsigned-big-32, dsz::unsigned-big-32, fbf::binary>> = fd

      display_buffer =
        if dsz > byte_size(device.display_buffer) do
          :binary.copy(<<0>>, dsz)
        else
          device.display_buffer
        end

      # Update display buffer at offset
      <<before::binary-size(ofs), rest_buf::binary>> = display_buffer

      after_part =
        if byte_size(fbf) < byte_size(rest_buf) do
          skip_fbf = byte_size(fbf)
          <<_::binary-size(skip_fbf), after_data::binary>> = rest_buf
          after_data
        else
          <<>>
        end

      display_buffer = before <> fbf <> after_part
      %{device | display_buffer: display_buffer}
    else
      device
    end
  end

  @doc "Handle a log event frame."
  @spec log_handle(t(), LogFrame.t()) :: t()
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def log_handle(device, frame) do
    cond do
      frame.event == Evt.et_proto_wdcl_connection() ->
        device

      frame.event == Evt.et_proto_wdcl_host_endpoint() and
          byte_size(frame.data) == @weave_endpoint_id_len ->
        %{device | endpoint_id: frame.data}

      frame.event == Evt.et_proto_weave_ep_alive() and
          byte_size(frame.data) == @weave_endpoint_id_len ->
        endpoint_alive(device, frame.data)

      frame.event == Evt.et_proto_weave_ep_via() and
          byte_size(frame.data) == @weave_endpoint_id_len + @weave_switch_id_len ->
        <<ep_id::binary-size(@weave_endpoint_id_len), via_id::binary-size(@weave_switch_id_len)>> =
          frame.data

        endpoint_via(device, ep_id, via_id)

      frame.event == Evt.et_stat_task_cpu() and byte_size(frame.data) > 1 ->
        cpu_load = :binary.at(frame.data, 0)
        <<_::8, task_id::binary>> = frame.data

        try do
          task_name = :binary.bin_to_list(task_id) |> List.to_string()

          active_tasks =
            Map.put(device.active_tasks, task_name, %{
              cpu_load: cpu_load,
              timestamp: System.system_time(:millisecond) / 1000
            })

          %{device | active_tasks: active_tasks}
        rescue
          e ->
            Logger.debug("Weave task stat parsing failed: #{inspect(e)}")
            device
        end

      frame.event == Evt.et_stat_cpu() and byte_size(frame.data) >= 1 ->
        cpu_load = :binary.at(frame.data, 0)
        device = %{device | cpu_load: cpu_load}
        capture_stats_cpu(device)

      frame.event == Evt.et_stat_memory() and byte_size(frame.data) >= 8 ->
        <<mem_free::unsigned-big-32, mem_total::unsigned-big-32, _::binary>> = frame.data
        mem_used = mem_total - mem_free
        mem_pct = if mem_total > 0, do: Float.round(mem_used / mem_total * 100, 2), else: 0.0

        device = %{
          device
          | memory_free: mem_free,
            memory_total: mem_total,
            memory_used: mem_used,
            memory_used_pct: mem_pct
        }

        capture_stats_memory(device)

      true ->
        device
    end
  end

  defp capture_stats_cpu(device) do
    entry = %{timestamp: System.system_time(:millisecond) / 1000, cpu_load: device.cpu_load}
    cpu_stats = bounded_enqueue(device.cpu_stats, entry, @statlen_max)
    %{device | cpu_stats: cpu_stats}
  end

  defp capture_stats_memory(device) do
    entry = %{timestamp: System.system_time(:millisecond) / 1000, memory_used: device.memory_used}
    memory_stats = bounded_enqueue(device.memory_stats, entry, @statlen_max)
    %{device | memory_stats: memory_stats}
  end

  defp bounded_enqueue(queue, item, max_len) do
    queue = :queue.in(item, queue)

    if :queue.len(queue) > max_len do
      {_, queue} = :queue.out(queue)
      queue
    else
      queue
    end
  end

  @doc "Get CPU stats."
  @spec get_cpu_stats(%__MODULE__{}) :: map()
  def get_cpu_stats(device) do
    stats_list = :queue.to_list(device.cpu_stats)

    tbegin =
      case List.last(stats_list) do
        nil -> 0
        entry -> entry.timestamp
      end

    %{
      timestamps: Enum.map(stats_list, &(&1.timestamp - tbegin)),
      values: Enum.map(stats_list, & &1.cpu_load),
      max: 100,
      unit: "%"
    }
  end

  @doc "Get memory stats."
  @spec get_memory_stats(%__MODULE__{}) :: map()
  def get_memory_stats(device) do
    stats_list = :queue.to_list(device.memory_stats)

    tbegin =
      case List.last(stats_list) do
        nil -> 0
        entry -> entry.timestamp
      end

    %{
      timestamps: Enum.map(stats_list, &(&1.timestamp - tbegin)),
      values: Enum.map(stats_list, & &1.memory_used),
      max: device.memory_total,
      unit: "B"
    }
  end

  @doc "Get active tasks (within last 5 seconds)."
  @spec get_active_tasks(%__MODULE__{}) :: map()
  def get_active_tasks(device) do
    now = System.system_time(:millisecond) / 1000

    device.active_tasks
    |> Enum.reject(fn {task_id, _} -> String.starts_with?(task_id, "IDLE") end)
    |> Enum.filter(fn {_, task} -> now - task.timestamp < 5 end)
    |> Enum.map(fn {task_id, task} -> {Evt.task_description(task_id), task} end)
    |> Enum.into(%{})
  end
end

defmodule RNS.Interfaces.WeaveInterface.WeaveInterfacePeer do
  @moduledoc """
  Per-peer interface for WeaveInterface.

  Each peer represents a discovered remote Weave endpoint.
  Handles duplicate packet detection using hash deques and
  forwards packets through the parent WeaveInterface's device.
  """

  use RNS.Interfaces.Interface

  alias RNS.Interfaces.WeaveInterface.WeaveDevice

  defstruct default_fields() ++
              [
                owner: nil,
                endpoint_addr: nil,
                via_switch_id: nil,
                peer_addr: nil,
                addr_info: nil,
                _online: false,
                ifac_netname: nil,
                ifac_netkey: nil
              ]

  @doc "Create a new peer interface."
  @spec new(keyword()) :: %__MODULE__{}
  def new(opts \\ []) do
    owner = Keyword.get(opts, :owner)
    endpoint_addr = Keyword.get(opts, :endpoint_addr)
    hw_mtu = Keyword.get(opts, :hw_mtu, 1024)
    fixed_mtu = Keyword.get(opts, :fixed_mtu, true)
    bitrate = Keyword.get(opts, :bitrate, 250_000)
    ifac_size = Keyword.get(opts, :ifac_size, 16)
    ifac_netname = Keyword.get(opts, :ifac_netname)
    ifac_netkey = Keyword.get(opts, :ifac_netkey)
    announce_rate_target = Keyword.get(opts, :announce_rate_target)
    mode = Keyword.get(opts, :mode)

    name = if endpoint_addr, do: RNS.hexrep(endpoint_addr), else: "unknown"
    hash = RNS.Interfaces.Interface.hash(%{name: name})

    %__MODULE__{
      name: name,
      hash: hash,
      owner: owner,
      parent_interface: owner,
      endpoint_addr: endpoint_addr,
      hw_mtu: hw_mtu,
      fixed_mtu: fixed_mtu,
      bitrate: bitrate,
      ifac_size: ifac_size,
      ifac_netname: ifac_netname,
      ifac_netkey: ifac_netkey,
      announce_rate_target: announce_rate_target,
      mode: mode,
      _online: false,
      created: System.system_time(:second)
    }
  end

  @impl true
  @doc "Process incoming data (behaviour callback, no parent state)."
  @spec process_incoming(%__MODULE__{}, binary()) :: {:ok, %__MODULE__{}} | {:error, term()}
  def process_incoming(peer, data) do
    {:ok, %{peer | rxb: peer.rxb + byte_size(data)}}
  end

  @doc "Process incoming data with multi-interface deduplication."
  @spec process_incoming(%__MODULE__{}, binary(), map()) :: {%__MODULE__{}, map()}
  def process_incoming(peer, data, parent_state) do
    if peer._online do
      {deque_hit, parent_state} =
        RNS.Interfaces.WeaveInterface.mif_deque_check(parent_state, data)

      if deque_hit do
        {peer, parent_state}
      else
        parent_state =
          RNS.Interfaces.WeaveInterface.refresh_peer(parent_state, peer.endpoint_addr)

        peer = %{peer | rxb: peer.rxb + byte_size(data)}
        parent_state = %{parent_state | rxb: parent_state.rxb + byte_size(data)}

        # Notify owner
        notify_owner(parent_state, data, peer)

        {peer, parent_state}
      end
    else
      {peer, parent_state}
    end
  end

  @impl true
  @doc "Process outgoing data through parent device."
  @spec process_outgoing(%__MODULE__{}, binary()) :: {:ok, %__MODULE__{}} | {:error, term()}
  def process_outgoing(peer, data) do
    if peer._online do
      if peer.owner && peer.owner.server_name do
        deliver_data = WeaveDevice.build_deliver_packet(peer.endpoint_addr, data)
        GenServer.cast(peer.owner.server_name, {:deliver_outgoing, deliver_data})
      end

      {:ok, %{peer | txb: peer.txb + byte_size(data)}}
    else
      {:ok, peer}
    end
  end

  @impl true
  @doc "Detach the peer."
  @spec detach(%__MODULE__{}) :: :ok | %__MODULE__{}
  def detach(peer) do
    %{peer | _online: false, detached: true}
  end

  @doc "Teardown the peer."
  @spec teardown(%__MODULE__{}) :: %__MODULE__{}
  def teardown(peer) do
    %{peer | _online: false, out: false, in: false}
  end

  @doc "Check if peer is online (depends on parent being online)."
  @spec online?(%__MODULE__{}) :: boolean()
  def online?(peer) do
    peer._online and peer.owner != nil
  end

  defp notify_owner(%{owner: pid}, data, _peer) when is_pid(pid) do
    send(pid, {:weave_peer_data, data})
  end

  defp notify_owner(%{owner: fun}, data, _peer) when is_function(fun, 1) do
    fun.(data)
  end

  defp notify_owner(_, _, _), do: :ok

  defimpl String.Chars, for: __MODULE__ do
    def to_string(peer) do
      addr_str = if peer.endpoint_addr, do: RNS.hexrep(peer.endpoint_addr), else: "unknown"
      "WeaveInterfacePeer[#{addr_str}]"
    end
  end
end
