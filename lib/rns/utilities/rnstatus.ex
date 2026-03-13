defmodule RNS.Utilities.RNStatus do
  @moduledoc """
  Reticulum Network Stack Status Utility.

  Displays the status of running Reticulum interfaces, including traffic
  statistics, announce stats, link counts, and more.

  Can be invoked as an escript (`rnstatus`) or called programmatically via
  `RNS.Utilities.RNStatus.main/1`.

  ## Usage

      rnstatus [options] [filter]

  ## Options

    * `--config PATH` - Path to alternative Reticulum config directory
    * `-a`, `--all` - Show all interfaces
    * `-A`, `--announce-stats` - Show announce stats
    * `-l`, `--link-stats` - Show link stats
    * `-t`, `--totals` - Display traffic totals
    * `-s`, `--sort FIELD` - Sort interfaces by field
    * `-r`, `--reverse` - Reverse sorting
    * `-j`, `--json` - Output in JSON format
    * `-v`, `--verbose` - Increase verbosity (can be repeated)
    * `--version` - Print version and exit
    * `-h`, `--help` - Print help and exit

  ## Sort Fields

  rate, traffic, rx, tx, rxs, txs, announces, arx, atx, held

  Ported from `python/RNS/Utilities/rnstatus.py`.
  """

  alias RNS.Interfaces.Interface

  # ── Entry Point ──────────────────────────────────────────────────────

  @doc """
  Entry point for the rnstatus escript and programmatic invocation.
  """
  @spec main([String.t()]) :: :ok | no_return()
  def main(args) do
    case parse_args(args) do
      {:ok, opts} ->
        cond do
          opts.version ->
            IO.puts("rnstatus #{RNS.Version.version()}")

          opts.help ->
            print_usage()

          true ->
            program_setup(opts)
        end

      {:error, message} ->
        IO.puts(:stderr, "error: #{message}")
        IO.puts(:stderr, "")
        print_usage()
        System.halt(1)
    end
  end

  # ── Argument Parsing ─────────────────────────────────────────────────

  @doc """
  Parses command-line arguments into an options map.

  Returns `{:ok, opts}` on success or `{:error, message}` on failure.
  """
  @spec parse_args([String.t()]) :: {:ok, map()} | {:error, String.t()}
  def parse_args(args) do
    {parsed, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          config: :string,
          all: :boolean,
          announce_stats: :boolean,
          link_stats: :boolean,
          totals: :boolean,
          sort: :string,
          reverse: :boolean,
          json: :boolean,
          verbose: :count,
          version: :boolean,
          help: :boolean
        ],
        aliases: [
          a: :all,
          A: :announce_stats,
          l: :link_stats,
          t: :totals,
          s: :sort,
          r: :reverse,
          j: :json,
          v: :verbose,
          h: :help
        ]
      )

    cond do
      invalid != [] ->
        {key, _} = hd(invalid)
        {:error, "unknown option: #{key}"}

      true ->
        # Remaining positional args become the name filter
        name_filter =
          case rest do
            [filter | _] -> filter
            [] -> nil
          end

        {:ok,
         %{
           configdir: Keyword.get(parsed, :config),
           all: Keyword.get(parsed, :all, false),
           announce_stats: Keyword.get(parsed, :announce_stats, false),
           link_stats: Keyword.get(parsed, :link_stats, false),
           totals: Keyword.get(parsed, :totals, false),
           sort: Keyword.get(parsed, :sort),
           reverse: Keyword.get(parsed, :reverse, false),
           json: Keyword.get(parsed, :json, false),
           verbosity: Keyword.get(parsed, :verbose, 0),
           version: Keyword.get(parsed, :version, false),
           help: Keyword.get(parsed, :help, false),
           name_filter: name_filter
         }}
    end
  end

  # ── Program Setup ────────────────────────────────────────────────────

  @doc """
  Collects interface stats and displays them according to the given options.

  When called programmatically, `opts` may include `:rns_instance` to skip
  starting a new Reticulum instance.
  """
  @spec program_setup(map()) :: :ok | no_return()
  def program_setup(opts) do
    ensure_application_started()

    reticulum_opts =
      [logdest: :stdout]
      |> maybe_add_opt(:configdir, opts[:configdir])
      |> maybe_add_opt(:verbosity, if(opts.verbosity > 0, do: opts.verbosity))

    case start_reticulum(reticulum_opts) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "No shared RNS instance available to get status from")
        if Map.get(opts, :must_exit, true), do: System.halt(1)
        {:error, reason}
    end

    stats = collect_stats(opts)

    if stats != nil do
      if opts.json do
        print_json_stats(stats)
      else
        print_stats(stats, opts)
      end
    else
      IO.puts("Could not get RNS status")
      if Map.get(opts, :must_exit, true), do: System.halt(2)
    end

    :ok
  end

  # ── Stats Collection ─────────────────────────────────────────────────

  @doc """
  Collects interface statistics from the running Reticulum instance.

  Returns a map with `:interfaces` (list of interface stat maps), and
  optionally `:transport_id`, `:transport_uptime`, `:rxb`, `:txb`, etc.
  Returns nil if stats cannot be collected.
  """
  @spec collect_stats(map()) :: map() | nil
  def collect_stats(opts) do
    try do
      interfaces = RNS.Transport.get_interfaces()

      link_count =
        if opts[:link_stats] do
          try do
            get_link_count()
          rescue
            _ -> nil
          end
        end

      interface_stats = Enum.map(interfaces, &interface_to_stat_map/1)

      transport_id = get_transport_id()
      transport_uptime = get_transport_uptime()

      total_rxb = Enum.reduce(interface_stats, 0, fn s, acc -> acc + (s["rxb"] || 0) end)
      total_txb = Enum.reduce(interface_stats, 0, fn s, acc -> acc + (s["txb"] || 0) end)

      %{
        "interfaces" => interface_stats,
        "transport_id" => transport_id,
        "transport_uptime" => transport_uptime,
        "link_count" => link_count,
        "rxb" => total_rxb,
        "txb" => total_txb,
        "rxs" => 0,
        "txs" => 0
      }
    rescue
      _ -> nil
    end
  end

  @doc """
  Converts an interface struct/map to a stats map for display.
  """
  @spec interface_to_stat_map(map()) :: map()
  def interface_to_stat_map(iface) do
    now = System.system_time(:second)
    created = Map.get(iface, :created, now)
    age = if created, do: now - created, else: 0

    ia_freq = incoming_announce_frequency(iface)
    oa_freq = outgoing_announce_frequency(iface)

    %{
      "name" => Map.get(iface, :name, "Unknown"),
      "status" => Map.get(iface, :online, false),
      "mode" => Map.get(iface, :mode, Interface.mode_full()),
      "rxb" => Map.get(iface, :rxb, 0),
      "txb" => Map.get(iface, :txb, 0),
      "rxs" => 0,
      "txs" => 0,
      "clients" => Map.get(iface, :clients),
      "bitrate" => Map.get(iface, :bitrate),
      "peers" => Map.get(iface, :peers),
      "ifac_signature" => Map.get(iface, :ifac_identity),
      "ifac_size" => Map.get(iface, :ifac_size, 0),
      "ifac_netname" => Map.get(iface, :ifac_netname),
      "announce_queue" => length(Map.get(iface, :announce_queue, [])),
      "held_announces" => map_size(Map.get(iface, :held_announces, %{})),
      "incoming_announce_frequency" => ia_freq,
      "outgoing_announce_frequency" => oa_freq,
      "age" => age,
      "in" => Map.get(iface, :in, false),
      "out" => Map.get(iface, :out, false)
    }
  end

  # ── Output Formatting ───────────────────────────────────────────────

  @doc """
  Prints interface stats in JSON format.
  """
  @spec print_json_stats(map()) :: :ok
  def print_json_stats(stats) do
    json_stats = sanitize_for_json(stats)
    IO.puts(Jason.encode!(json_stats))
  rescue
    # If Jason is not available, fall back to inspect
    UndefinedFunctionError ->
      IO.puts(inspect(sanitize_for_json(stats)))
  end

  @doc """
  Prints interface stats in human-readable format.
  """
  @spec print_stats(map(), map()) :: :ok
  def print_stats(stats, opts) do
    interfaces = stats["interfaces"] || []
    interfaces = sort_interfaces(interfaces, opts[:sort], opts[:reverse])

    for ifstat <- interfaces do
      name = ifstat["name"]

      if should_display?(name, opts[:all], opts[:name_filter]) do
        print_interface_stat(ifstat, opts)
      end
    end

    # Link stats
    link_count = stats["link_count"]

    lstr =
      if link_count != nil and opts[:link_stats] do
        ms = if link_count == 1, do: "y", else: "ies"

        if stats["transport_id"] != nil do
          ", #{link_count} entr#{ms} in link table"
        else
          " #{link_count} entr#{ms} in link table"
        end
      else
        ""
      end

    # Traffic totals
    if opts[:totals] do
      rxb_str = "↓" <> RNS.prettysize(stats["rxb"] || 0)
      txb_str = "↑" <> RNS.prettysize(stats["txb"] || 0)
      {rxb_str, txb_str} = pad_strings(rxb_str, txb_str)

      rxstat = rxb_str <> "  " <> RNS.prettyspeed(stats["rxs"] || 0)
      txstat = txb_str <> "  " <> RNS.prettyspeed(stats["txs"] || 0)

      IO.puts("\n Totals       : #{txstat}\n                #{rxstat}")
    end

    # Transport info
    if stats["transport_id"] != nil do
      IO.puts("\n Transport Instance #{RNS.prettyhexrep(stats["transport_id"])} running")

      if stats["transport_uptime"] != nil do
        IO.puts(" Uptime is #{RNS.prettytime(stats["transport_uptime"])}#{lstr}")
      end
    else
      if lstr != "" do
        IO.puts("\n#{lstr}")
      end
    end

    IO.puts("")
    :ok
  end

  @doc """
  Prints a single interface's status information.
  """
  @spec print_interface_stat(map(), map()) :: :ok
  def print_interface_stat(ifstat, opts) do
    IO.puts("")

    ss = if ifstat["status"], do: "Up", else: "Down"
    modestr = mode_string(ifstat["mode"])
    name = ifstat["name"]

    IO.puts(" #{name}")

    if ifstat["ifac_netname"] != nil do
      IO.puts("    Network   : #{ifstat["ifac_netname"]}")
    end

    IO.puts("    Status    : #{ss}")

    # Clients
    if ifstat["clients"] != nil do
      clients_string = format_clients_string(name, ifstat["clients"])

      if clients_string != "" do
        IO.puts("    #{clients_string}")
      end
    end

    # Mode (skip for certain interface types)
    unless String.starts_with?(name, "Shared Instance[") or
             String.starts_with?(name, "TCPInterface[Client") or
             String.starts_with?(name, "LocalInterface[") do
      IO.puts("    Mode      : #{modestr}")
    end

    # Bitrate
    if ifstat["bitrate"] != nil do
      IO.puts("    Rate      : #{speed_str(ifstat["bitrate"])}")
    end

    # Peers
    if ifstat["peers"] != nil do
      IO.puts("    Peers     : #{ifstat["peers"]} reachable")
    end

    # IFAC
    if ifstat["ifac_signature"] != nil do
      sig = ifstat["ifac_signature"]
      sig_bytes = if is_binary(sig), do: sig, else: <<>>

      sig_size = byte_size(sig_bytes)
      skip = max(sig_size - 5, 0)
      <<_::binary-size(skip), last_5::binary>> = sig_bytes

      sigstr = "<…#{RNS.hexrep(last_5, false)}>"
      IO.puts("    Access    : #{ifstat["ifac_size"] * 8}-bit IFAC by #{sigstr}")
    end

    # Announce stats
    if opts[:announce_stats] do
      aqn = ifstat["announce_queue"] || 0

      if aqn > 0 do
        suffix = if aqn == 1, do: "announce", else: "announces"
        IO.puts("    Queued    : #{aqn} #{suffix}")
      end

      held = ifstat["held_announces"] || 0

      if held > 0 do
        suffix = if held == 1, do: "announce", else: "announces"
        IO.puts("    Held      : #{held} #{suffix}")
      end

      if ifstat["incoming_announce_frequency"] != nil do
        IO.puts(
          "    Announces : #{RNS.prettyfrequency(ifstat["outgoing_announce_frequency"] || 0)}↑"
        )

        IO.puts(
          "                #{RNS.prettyfrequency(ifstat["incoming_announce_frequency"] || 0)}↓"
        )
      end
    end

    # Traffic
    rxb_str = "↓" <> RNS.prettysize(ifstat["rxb"] || 0)
    txb_str = "↑" <> RNS.prettysize(ifstat["txb"] || 0)
    {rxb_str, txb_str} = pad_strings(rxb_str, txb_str)

    rxstat = rxb_str
    txstat = txb_str

    rxstat =
      if ifstat["rxs"] != nil and ifstat["txs"] != nil do
        rxstat <> "  " <> RNS.prettyspeed(ifstat["rxs"])
      else
        rxstat
      end

    txstat =
      if ifstat["rxs"] != nil and ifstat["txs"] != nil do
        txstat <> "  " <> RNS.prettyspeed(ifstat["txs"])
      else
        txstat
      end

    IO.puts("    Traffic   : #{txstat}\n                #{rxstat}")
    :ok
  end

  # ── Helper Functions ─────────────────────────────────────────────────

  @doc """
  Formats a bitrate as a human-readable speed string.
  """
  @spec speed_str(number()) :: String.t()
  def speed_str(num, suffix \\ "bps") do
    units = ["", "k", "M", "G", "T", "P", "E", "Z"]
    last_unit = "Y"
    do_speed_str(num * 1.0, units, last_unit, suffix)
  end

  defp do_speed_str(num, [unit], last_unit, suffix) do
    _ = unit
    :io_lib.format("~.2f ~s~s", [num, last_unit, suffix]) |> IO.iodata_to_binary()
  end

  defp do_speed_str(num, [unit | _rest], _last_unit, suffix) when abs(num) < 1000.0 do
    :io_lib.format("~.2f ~s~s", [num, unit, suffix]) |> IO.iodata_to_binary()
  end

  defp do_speed_str(num, [_ | rest], last_unit, suffix) do
    do_speed_str(num / 1000.0, rest, last_unit, suffix)
  end

  @doc """
  Converts an interface mode constant to a human-readable string.
  """
  @spec mode_string(non_neg_integer()) :: String.t()
  def mode_string(mode) do
    cond do
      mode == Interface.mode_access_point() -> "Access Point"
      mode == Interface.mode_point_to_point() -> "Point-to-Point"
      mode == Interface.mode_roaming() -> "Roaming"
      mode == Interface.mode_boundary() -> "Boundary"
      mode == Interface.mode_gateway() -> "Gateway"
      true -> "Full"
    end
  end

  @doc """
  Determines whether an interface should be displayed based on filters.
  """
  @spec should_display?(String.t(), boolean(), String.t() | nil) :: boolean()
  def should_display?(name, display_all, name_filter) do
    # By default, hide certain internal interface types
    hidden =
      not display_all and
        (String.starts_with?(name, "LocalInterface[") or
           String.starts_with?(name, "TCPInterface[Client") or
           String.starts_with?(name, "BackboneInterface[Client on") or
           String.starts_with?(name, "AutoInterfacePeer[") or
           String.starts_with?(name, "WeaveInterfacePeer[") or
           String.starts_with?(name, "I2PInterfacePeer[Connected peer"))

    if hidden do
      false
    else
      # Apply name filter
      if name_filter == nil do
        true
      else
        String.contains?(String.downcase(name), String.downcase(name_filter))
      end
    end
  end

  @doc """
  Sorts interfaces by the specified field.
  """
  @spec sort_interfaces([map()], String.t() | nil, boolean()) :: [map()]
  def sort_interfaces(interfaces, nil, _reverse), do: interfaces

  def sort_interfaces(interfaces, sort_field, sort_reverse) do
    sort_field = String.downcase(sort_field)

    sorter =
      case sort_field do
        s when s in ["rate", "bitrate"] ->
          fn i -> i["bitrate"] || 0 end

        "rx" ->
          fn i -> i["rxb"] || 0 end

        "tx" ->
          fn i -> i["txb"] || 0 end

        "rxs" ->
          fn i -> i["rxs"] || 0 end

        "txs" ->
          fn i -> i["txs"] || 0 end

        "traffic" ->
          fn i -> (i["rxb"] || 0) + (i["txb"] || 0) end

        s when s in ["announces", "announce"] ->
          fn i ->
            (i["incoming_announce_frequency"] || 0) + (i["outgoing_announce_frequency"] || 0)
          end

        "arx" ->
          fn i -> i["incoming_announce_frequency"] || 0 end

        "atx" ->
          fn i -> i["outgoing_announce_frequency"] || 0 end

        "held" ->
          fn i -> i["held_announces"] || 0 end

        _ ->
          nil
      end

    if sorter do
      sorted = Enum.sort_by(interfaces, sorter)
      if sort_reverse, do: Enum.reverse(sorted), else: sorted
    else
      interfaces
    end
  end

  @doc """
  Formats a pretty_date-style relative time string from an integer timestamp.
  """
  @spec pretty_date(integer()) :: String.t()
  def pretty_date(timestamp) do
    now = System.system_time(:second)
    diff = now - timestamp

    cond do
      diff < 0 -> ""
      diff < 10 -> "#{diff} seconds"
      diff < 60 -> "#{diff} seconds"
      diff < 120 -> "1 minute"
      diff < 3600 -> "#{div(diff, 60)} minutes"
      diff < 7200 -> "an hour"
      diff < 86400 -> "#{div(diff, 3600)} hours"
      diff < 86400 * 2 -> "1 day"
      diff < 86400 * 7 -> "#{div(diff, 86400)} days"
      diff < 86400 * 31 -> "#{div(diff, 86400 * 7)} weeks"
      diff < 86400 * 365 -> "#{div(diff, 86400 * 30)} months"
      true -> "#{div(diff, 86400 * 365)} years"
    end
  end

  # ── Private Helpers ──────────────────────────────────────────────────

  defp format_clients_string(name, clients) do
    cond do
      String.starts_with?(name, "Shared Instance[") ->
        cnum = max(clients - 1, 0)
        spec = if cnum == 1, do: " program", else: " programs"
        "Serving   : #{cnum}#{spec}"

      String.starts_with?(name, "I2PInterface[") ->
        spec = if clients == 1, do: " connected I2P endpoint", else: " connected I2P endpoints"
        "Peers     : #{clients}#{spec}"

      true ->
        "Clients   : #{clients}"
    end
  end

  defp pad_strings(str1, str2) do
    diff = String.length(str1) - String.length(str2)

    cond do
      diff > 0 -> {str1, str2 <> String.duplicate(" ", diff)}
      diff < 0 -> {str1 <> String.duplicate(" ", -diff), str2}
      true -> {str1, str2}
    end
  end

  defp sanitize_for_json(data) when is_map(data) do
    Map.new(data, fn
      {k, v} when is_binary(v) ->
        if String.valid?(v) do
          {k, v}
        else
          {k, RNS.hexrep(v, false)}
        end

      {k, v} when is_list(v) ->
        {k, Enum.map(v, &sanitize_for_json/1)}

      {k, v} when is_map(v) ->
        {k, sanitize_for_json(v)}

      {k, v} ->
        {k, v}
    end)
  end

  defp sanitize_for_json(data) when is_list(data) do
    Enum.map(data, &sanitize_for_json/1)
  end

  defp sanitize_for_json(data), do: data

  defp incoming_announce_frequency(iface) do
    deque = Map.get(iface, :ia_freq_deque, [])
    calculate_frequency(deque)
  end

  defp outgoing_announce_frequency(iface) do
    deque = Map.get(iface, :oa_freq_deque, [])
    calculate_frequency(deque)
  end

  defp calculate_frequency(deque) when length(deque) < 2, do: 0

  defp calculate_frequency(deque) do
    sorted = Enum.sort(deque)
    first = List.first(sorted)
    last = List.last(sorted)
    span = last - first

    if span > 0 do
      length(deque) / span
    else
      0
    end
  end

  defp get_transport_id do
    try do
      case GenServer.whereis(RNS.Transport) do
        nil ->
          nil

        _pid ->
          state = :sys.get_state(RNS.Transport)
          Map.get(state, :identity_hash)
      end
    rescue
      _ -> nil
    end
  end

  defp get_transport_uptime do
    try do
      case GenServer.whereis(RNS.Transport) do
        nil ->
          nil

        _pid ->
          state = :sys.get_state(RNS.Transport)
          started = Map.get(state, :started_at)
          if started, do: System.system_time(:second) - started, else: nil
      end
    rescue
      _ -> nil
    end
  end

  defp get_link_count do
    try do
      # Count entries in the link table ETS
      :ets.info(:rns_active_links, :size) || 0
    rescue
      _ -> 0
    end
  end

  defp ensure_application_started do
    case Application.ensure_all_started(:rns_ex) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end

  defp start_reticulum(opts) do
    case GenServer.whereis(RNS.Reticulum) do
      nil -> RNS.Reticulum.start_link(opts)
      pid when is_pid(pid) -> {:error, {:already_started, pid}}
    end
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp print_usage do
    IO.puts("""
    Reticulum Network Stack Status

    Usage: rnstatus [options] [filter]

    Options:
      --config PATH          Path to alternative Reticulum config directory
      -a, --all              Show all interfaces
      -A, --announce-stats   Show announce stats
      -l, --link-stats       Show link stats
      -t, --totals           Display traffic totals
      -s, --sort FIELD       Sort by: rate, traffic, rx, tx, rxs, txs, announces, arx, atx, held
      -r, --reverse          Reverse sorting
      -j, --json             Output in JSON format
      -v, --verbose          Increase verbosity (can be repeated)
      --version              Print version and exit
      -h, --help             Print this help message and exit

    Arguments:
      filter                 Only display interfaces with names including filter
    """)
  end
end
