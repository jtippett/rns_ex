defmodule RNS.Utilities.RNPath do
  @moduledoc """
  Reticulum Path Management Utility.

  Provides path lookup, path table display, announce rate information,
  path dropping, announce queue management, and identity blackholing.

  Can be invoked as an escript (`rnpath`) or called programmatically via
  `RNS.Utilities.RNPath.main/1`.

  ## Usage

      rnpath [options] [destination] [list_filter]

  ## Options

    * `--config PATH` - Path to alternative Reticulum config directory
    * `-t`, `--table` - Show all known paths
    * `-m`, `--max HOPS` - Maximum hops to filter path table by
    * `-r`, `--rates` - Show announce rate info
    * `-d`, `--drop` - Remove the path to a destination
    * `-D`, `--drop-announces` - Drop all queued announces
    * `-x`, `--drop-via` - Drop all paths via specified transport instance
    * `-w SECONDS` - Timeout before giving up (default: #{RNS.Transport.path_request_timeout()})
    * `-b`, `--blackholed` - List blackholed identities
    * `-B`, `--blackhole` - Blackhole identity
    * `-U`, `--unblackhole` - Unblackhole identity
    * `--duration HOURS` - Duration of blackhole enforcement in hours
    * `--reason TEXT` - Reason for blackholing identity
    * `-j`, `--json` - Output in JSON format
    * `-v`, `--verbose` - Increase verbosity (can be repeated)
    * `--version` - Print version and exit
    * `-h`, `--help` - Print help and exit

  Ported from `python/RNS/Utilities/rnpath.py`.
  """

  # ── Entry Point ──────────────────────────────────────────────────────

  @doc """
  Entry point for the rnpath escript and programmatic invocation.
  """
  @spec main([String.t()]) :: :ok | no_return()
  def main(args) do
    case parse_args(args) do
      {:ok, opts} ->
        cond do
          opts.version ->
            IO.puts("rnpath #{RNS.Version.version()}")

          opts.help ->
            print_usage()

          not opts.table and not opts.rates and not opts.drop_announces and
            not opts.drop_via and not opts.blackholed and
              opts.destination == nil ->
            IO.puts("")
            print_usage()
            IO.puts("")

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
          table: :boolean,
          max: :integer,
          rates: :boolean,
          drop: :boolean,
          drop_announces: :boolean,
          drop_via: :boolean,
          timeout: :float,
          blackholed: :boolean,
          blackhole: :boolean,
          unblackhole: :boolean,
          duration: :float,
          reason: :string,
          json: :boolean,
          verbose: :count,
          version: :boolean,
          help: :boolean
        ],
        aliases: [
          t: :table,
          m: :max,
          r: :rates,
          d: :drop,
          D: :drop_announces,
          x: :drop_via,
          w: :timeout,
          b: :blackholed,
          B: :blackhole,
          U: :unblackhole,
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
        # Positional args: destination [list_filter]
        {destination, list_filter} =
          case rest do
            [dest, filter | _] -> {dest, filter}
            [dest] -> {dest, nil}
            [] -> {nil, nil}
          end

        {:ok,
         %{
           configdir: Keyword.get(parsed, :config),
           table: Keyword.get(parsed, :table, false),
           max_hops: Keyword.get(parsed, :max),
           rates: Keyword.get(parsed, :rates, false),
           drop: Keyword.get(parsed, :drop, false),
           drop_announces: Keyword.get(parsed, :drop_announces, false),
           drop_via: Keyword.get(parsed, :drop_via, false),
           timeout: Keyword.get(parsed, :timeout, RNS.Transport.path_request_timeout() * 1.0),
           blackholed: Keyword.get(parsed, :blackholed, false),
           blackhole: Keyword.get(parsed, :blackhole, false),
           unblackhole: Keyword.get(parsed, :unblackhole, false),
           duration: Keyword.get(parsed, :duration),
           reason: Keyword.get(parsed, :reason),
           json: Keyword.get(parsed, :json, false),
           verbosity: Keyword.get(parsed, :verbose, 0),
           version: Keyword.get(parsed, :version, false),
           help: Keyword.get(parsed, :help, false),
           destination: destination,
           list_filter: list_filter
         }}
    end
  end

  # ── Hash Parsing ─────────────────────────────────────────────────────

  @doc """
  Parses a hex string into a binary hash, validating length.

  Returns `{:ok, hash_bytes}` or `{:error, reason}`.
  """
  @spec parse_hash(String.t()) :: {:ok, binary()} | {:error, String.t()}
  def parse_hash(input_str) do
    dest_len = div(RNS.Reticulum.truncated_hashlength(), 8) * 2

    if String.length(input_str) != dest_len do
      {:error,
       "Hash length is invalid, must be #{dest_len} hexadecimal characters (#{div(dest_len, 2)} bytes)."}
    else
      case Base.decode16(input_str, case: :mixed) do
        {:ok, hash_bytes} -> {:ok, hash_bytes}
        :error -> {:error, "Invalid hash entered. Check your input."}
      end
    end
  end

  # ── Program Setup ────────────────────────────────────────────────────

  @doc """
  Executes the path management operation specified by the given options.
  """
  @spec program_setup(map()) :: :ok | no_return()
  def program_setup(opts) do
    ensure_application_started()

    reticulum_opts =
      [logdest: RNS.Log.log_stdout()]
      |> maybe_add_opt(:configdir, opts[:configdir])
      |> maybe_add_opt(:verbosity, if(opts.verbosity > 0, do: opts.verbosity))

    case start_reticulum(reticulum_opts) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} ->
        IO.puts(:stderr, "Could not start Reticulum: #{inspect(reason)}")
        System.halt(1)
    end

    cond do
      opts.blackholed -> handle_blackholed(opts)
      opts.blackhole -> handle_blackhole(opts)
      opts.unblackhole -> handle_unblackhole(opts)
      opts.table -> handle_table(opts)
      opts.rates -> handle_rates(opts)
      opts.drop_announces -> handle_drop_announces()
      opts.drop -> handle_drop(opts)
      opts.drop_via -> handle_drop_via(opts)
      true -> handle_path_request(opts)
    end
  end

  # ── Command Handlers ─────────────────────────────────────────────────

  @doc false
  def handle_table(opts) do
    destination_hash =
      if opts.destination do
        case parse_hash(opts.destination) do
          {:ok, hash} -> hash
          {:error, msg} ->
            IO.puts(msg)
            System.halt(1)
        end
      end

    table = get_path_table(opts.max_hops)

    if opts.json do
      print_json_path_table(table)
    else
      displayed = 0

      displayed =
        Enum.reduce(table, displayed, fn path, acc ->
          if destination_hash == nil or destination_hash == path.hash do
            exp_str = RNS.timestamp_str(path.expires)
            m_str = if path.hops == 1, do: " ", else: "s"

            IO.puts(
              "#{RNS.prettyhexrep(path.hash)} is #{path.hops} hop#{m_str} away via " <>
                "#{RNS.prettyhexrep(path.via)} on #{path.interface_name} expires #{exp_str}"
            )

            acc + 1
          else
            acc
          end
        end)

      if destination_hash != nil and displayed == 0 do
        IO.puts("No path known")
        System.halt(1)
      end
    end
  end

  @doc false
  def handle_rates(opts) do
    destination_hash =
      if opts.destination do
        case parse_hash(opts.destination) do
          {:ok, hash} -> hash
          {:error, msg} ->
            IO.puts(msg)
            System.halt(1)
        end
      end

    table = get_rate_table()

    if opts.json do
      json_table =
        Enum.map(table, fn entry ->
          Map.new(entry, fn
            {k, v} when is_binary(v) and not is_bitstring(v) ->
              {Atom.to_string(k), RNS.hexrep(v, false)}

            {k, v} when is_binary(v) ->
              if String.valid?(v), do: {Atom.to_string(k), v}, else: {Atom.to_string(k), RNS.hexrep(v, false)}

            {k, v} ->
              {Atom.to_string(k), v}
          end)
        end)

      IO.puts(inspect(json_table))
    else
      if Enum.empty?(table) do
        IO.puts("No information available")
      else
        displayed =
          Enum.reduce(table, 0, fn entry, acc ->
            if destination_hash == nil or destination_hash == entry.hash do
              try do
                last_str = pretty_date(entry.last)
                start_ts = List.last(entry.timestamps) || entry.last
                now = System.system_time(:second)
                span = max(now - start_ts, 3600)
                span_hours = span / 3600.0
                span_str = pretty_date(start_ts)
                hour_rate = Float.round(length(entry.timestamps) / span_hours, 3)

                hour_rate_str =
                  if hour_rate - trunc(hour_rate) == 0.0,
                    do: "#{trunc(hour_rate)}",
                    else: "#{hour_rate}"

                rv_str =
                  if entry.rate_violations > 0 do
                    s_str = if entry.rate_violations == 1, do: "", else: "s"
                    ", #{entry.rate_violations} active rate violation#{s_str}"
                  else
                    ""
                  end

                bl_str =
                  if entry.blocked_until > now do
                    bli = now - (entry.blocked_until - now)
                    ", new announces allowed in #{pretty_date(bli)}"
                  else
                    ""
                  end

                IO.puts(
                  "#{RNS.prettyhexrep(entry.hash)} last heard #{last_str} ago, " <>
                    "#{hour_rate_str} announces/hour in the last #{span_str}#{rv_str}#{bl_str}"
                )

                acc + 1
              rescue
                e ->
                  IO.puts("Error while processing entry for #{RNS.prettyhexrep(entry.hash)}")
                  IO.puts(Exception.message(e))
                  acc
              end
            else
              acc
            end
          end)

        if destination_hash != nil and displayed == 0 do
          IO.puts("No information available")
          System.halt(1)
        end
      end
    end
  end

  @doc false
  def handle_drop(opts) do
    case parse_destination(opts.destination) do
      {:ok, destination_hash} ->
        if drop_path(destination_hash) do
          IO.puts("Dropped path to #{RNS.prettyhexrep(destination_hash)}")
        else
          IO.puts(
            "Unable to drop path to #{RNS.prettyhexrep(destination_hash)}. Does it exist?"
          )

          System.halt(1)
        end

      {:error, msg} ->
        IO.puts(msg)
        System.halt(1)
    end
  end

  @doc false
  def handle_drop_via(opts) do
    case parse_destination(opts.destination) do
      {:ok, destination_hash} ->
        if drop_all_via(destination_hash) do
          IO.puts("Dropped all paths via #{RNS.prettyhexrep(destination_hash)}")
        else
          IO.puts(
            "Unable to drop paths via #{RNS.prettyhexrep(destination_hash)}. Does the transport instance exist?"
          )

          System.halt(1)
        end

      {:error, msg} ->
        IO.puts(msg)
        System.halt(1)
    end
  end

  @doc false
  def handle_drop_announces do
    IO.puts("Dropping announce queues on all interfaces...")
    drop_announce_queues()
  end

  @doc false
  def handle_blackholed(opts) do
    blackholed_list = get_blackholed_identities()

    if blackholed_list == nil or map_size(blackholed_list) == 0 do
      IO.puts("No blackholed identity data available")
      System.halt(20)
    else
      now = System.system_time(:second)

      Enum.each(blackholed_list, fn {identity_hash, entry} ->
        until_val = entry[:until]
        reason = entry[:reason]
        source = entry[:source]

        until_str =
          if until_val do
            "for #{RNS.prettytime(max(0, until_val - now))}"
          else
            "indefinitely"
          end

        reason_str = if reason, do: " (#{truncate_str(reason, 64)})", else: ""

        by_str =
          if source do
            " by #{RNS.prettyhexrep(source)}"
          else
            ""
          end

        filter_str = "#{RNS.prettyhexrep(identity_hash)} #{until_str} #{reason_str} #{by_str}"

        should_display =
          if opts.destination do
            String.contains?(filter_str, opts.destination)
          else
            true
          end

        if should_display do
          IO.puts(
            "#{RNS.prettyhexrep(identity_hash)} blackholed #{until_str}#{reason_str}#{by_str}"
          )
        end
      end)
    end
  end

  @doc false
  def handle_blackhole(opts) do
    case parse_destination(opts.destination) do
      {:ok, identity_hash} ->
        until_val =
          if opts.duration do
            System.system_time(:second) + trunc(opts.duration * 60 * 60)
          end

        result = blackhole_identity(identity_hash, until_val, opts.reason)

        case result do
          :ok -> IO.puts("Blackholed identity #{opts.destination}")
          :already -> IO.puts("Identity #{opts.destination} already blackholed")
          :error -> IO.puts("Could not blackhole identity #{opts.destination}")
        end

      {:error, msg} ->
        IO.puts("Could not blackhole identity: #{msg}")
        System.halt(20)
    end
  end

  @doc false
  def handle_unblackhole(opts) do
    case parse_destination(opts.destination) do
      {:ok, identity_hash} ->
        result = unblackhole_identity(identity_hash)

        case result do
          :ok -> IO.puts("Lifted blackhole for identity #{opts.destination}")
          :not_found -> IO.puts("Identity #{opts.destination} not blackholed")
          :error -> IO.puts("Could not unblackhole identity #{opts.destination}")
        end

      {:error, msg} ->
        IO.puts("Could not unblackhole identity: #{msg}")
        System.halt(20)
    end
  end

  @doc false
  def handle_path_request(opts) do
    case parse_destination(opts.destination) do
      {:ok, destination_hash} ->
        timeout = opts.timeout

        if not RNS.Transport.has_path(destination_hash) do
          request_path(destination_hash)
          IO.write("Path to #{RNS.prettyhexrep(destination_hash)} requested  ")

          syms = String.graphemes("⢄⢂⢁⡁⡈⡐⡠")
          limit = System.system_time(:second) + trunc(timeout)

          wait_for_path(destination_hash, syms, 0, limit)
        end

        if RNS.Transport.has_path(destination_hash) do
          hops = RNS.Transport.hops_to(destination_hash)
          next_hop_bytes = RNS.Transport.next_hop(destination_hash)

          if next_hop_bytes == nil do
            IO.puts("\rError: Invalid path data returned")
            System.halt(1)
          else
            next_hop = RNS.prettyhexrep(next_hop_bytes)
            next_hop_iface = get_next_hop_if_name(destination_hash)
            ms = if hops != 1, do: "s", else: ""

            IO.puts(
              "\rPath found, destination #{RNS.prettyhexrep(destination_hash)} is " <>
                "#{hops} hop#{ms} away via #{next_hop} on #{next_hop_iface}"
            )
          end
        else
          IO.puts("\r#{String.duplicate(" ", 55)}\rPath not found")
          System.halt(1)
        end

      {:error, msg} ->
        IO.puts(msg)
        System.halt(1)
    end
  end

  # ── Path Table Access ────────────────────────────────────────────────

  @doc """
  Retrieves the path table as a list of maps, optionally filtered by max hops.
  """
  @spec get_path_table(non_neg_integer() | nil) :: [map()]
  def get_path_table(max_hops \\ nil) do
    try do
      entries = :ets.tab2list(:rns_path_table)

      entries
      |> Enum.map(fn {hash, entry} ->
        interface_name =
          if is_map(entry.interface) and Map.has_key?(entry.interface, :name) do
            entry.interface.name || "Unknown"
          else
            "Unknown"
          end

        %{
          hash: hash,
          via: entry.next_hop,
          hops: entry.hops,
          expires: entry.expires,
          interface_name: interface_name,
          interface: interface_name
        }
      end)
      |> Enum.filter(fn path ->
        max_hops == nil or path.hops <= max_hops
      end)
      |> Enum.sort_by(fn path -> {path.interface_name, path.hops} end)
    rescue
      _ -> []
    end
  end

  @doc """
  Retrieves the announce rate table as a list of maps.
  """
  @spec get_rate_table() :: [map()]
  def get_rate_table do
    try do
      entries = :ets.tab2list(:rns_announce_rate_table)

      entries
      |> Enum.map(fn {hash, entry} ->
        %{
          hash: hash,
          last: entry[:last] || 0,
          timestamps: entry[:timestamps] || [],
          rate_violations: entry[:rate_violations] || 0,
          blocked_until: entry[:blocked_until] || 0
        }
      end)
      |> Enum.sort_by(fn e -> e.last end)
    rescue
      _ -> []
    end
  end

  @doc """
  Drops a path to the specified destination. Returns true if path existed.
  """
  @spec drop_path(binary()) :: boolean()
  def drop_path(destination_hash) do
    try do
      case :ets.lookup(:rns_path_table, destination_hash) do
        [{^destination_hash, _}] ->
          :ets.delete(:rns_path_table, destination_hash)
          true

        [] ->
          false
      end
    rescue
      _ -> false
    end
  end

  @doc """
  Drops all paths that route via the specified transport instance.
  Returns true if any paths were dropped.
  """
  @spec drop_all_via(binary()) :: boolean()
  def drop_all_via(transport_hash) do
    try do
      entries = :ets.tab2list(:rns_path_table)

      dropped =
        Enum.filter(entries, fn {_hash, entry} ->
          entry.next_hop == transport_hash
        end)

      Enum.each(dropped, fn {hash, _entry} ->
        :ets.delete(:rns_path_table, hash)
      end)

      length(dropped) > 0
    rescue
      _ -> false
    end
  end

  @doc """
  Drops announce queues on all interfaces.
  """
  @spec drop_announce_queues() :: :ok
  def drop_announce_queues do
    interfaces = RNS.Transport.get_interfaces()

    Enum.each(interfaces, fn iface ->
      if Map.has_key?(iface, :announce_queue) do
        # Clear the announce queue by sending a message if it's a GenServer
        if iface[:pid] do
          try do
            GenServer.cast(iface.pid, :clear_announce_queue)
          rescue
            _ -> :ok
          end
        end
      end
    end)

    :ok
  end

  @doc """
  Requests a path to the specified destination.
  """
  @spec request_path(binary()) :: :ok
  def request_path(destination_hash) do
    try do
      RNS.Transport.request_path(destination_hash)
    rescue
      UndefinedFunctionError ->
        # If request_path isn't implemented yet, log a warning
        RNS.log("Path request not yet fully implemented", RNS.log_warning())
    end

    :ok
  end

  @doc """
  Returns the interface name for the next hop to a destination.
  """
  @spec get_next_hop_if_name(binary()) :: String.t()
  def get_next_hop_if_name(destination_hash) do
    iface = RNS.Transport.next_hop_interface(destination_hash)

    if is_map(iface) and Map.has_key?(iface, :name) do
      iface.name || "Unknown"
    else
      "Unknown"
    end
  end

  @doc """
  Gets the map of blackholed identities.
  """
  @spec get_blackholed_identities() :: map() | nil
  def get_blackholed_identities do
    try do
      GenServer.call(RNS.Reticulum, :get_blackholed_identities)
    rescue
      _ -> nil
    end
  end

  @doc """
  Blackholes an identity hash.
  """
  @spec blackhole_identity(binary(), non_neg_integer() | nil, String.t() | nil) ::
          :ok | :already | :error
  def blackhole_identity(identity_hash, until_val, reason) do
    try do
      existing = get_blackholed_identities() || %{}

      if Map.has_key?(existing, identity_hash) do
        :already
      else
        entry = %{
          until: until_val,
          reason: reason,
          source: get_local_identity_hash()
        }

        GenServer.call(RNS.Reticulum, {:blackhole_identity, identity_hash, entry})
        :ok
      end
    rescue
      _ -> :error
    end
  end

  @doc """
  Removes blackhole for an identity hash.
  """
  @spec unblackhole_identity(binary()) :: :ok | :not_found | :error
  def unblackhole_identity(identity_hash) do
    try do
      existing = get_blackholed_identities() || %{}

      if Map.has_key?(existing, identity_hash) do
        GenServer.call(RNS.Reticulum, {:unblackhole_identity, identity_hash})
        :ok
      else
        :not_found
      end
    rescue
      _ -> :error
    end
  end

  @doc """
  Formats a timestamp into a relative time string (e.g., "5 minutes").

  This matches the Python `pretty_date` function from rnpath.py.
  """
  @spec pretty_date(integer()) :: String.t()
  def pretty_date(timestamp) do
    now = System.system_time(:second)
    diff = now - timestamp

    if diff < 0 do
      ""
    else
      day_diff = div(diff, 86400)
      second_diff = rem(diff, 86400)

      cond do
        day_diff == 0 and second_diff < 10 -> "#{second_diff} seconds"
        day_diff == 0 and second_diff < 60 -> "#{second_diff} seconds"
        day_diff == 0 and second_diff < 120 -> "1 minute"
        day_diff == 0 and second_diff < 3600 -> "#{div(second_diff, 60)} minutes"
        day_diff == 0 and second_diff < 7200 -> "an hour"
        day_diff == 0 -> "#{div(second_diff, 3600)} hours"
        day_diff == 1 -> "1 day"
        day_diff < 7 -> "#{day_diff} days"
        day_diff < 31 -> "#{div(day_diff, 7)} weeks"
        day_diff < 365 -> "#{div(day_diff, 30)} months"
        true -> "#{div(day_diff, 365)} years"
      end
    end
  end

  # ── Private Helpers ──────────────────────────────────────────────────

  defp parse_destination(nil) do
    {:error, "No destination specified."}
  end

  defp parse_destination(hexhash) do
    parse_hash(hexhash)
  end

  defp wait_for_path(destination_hash, syms, i, limit) do
    if not RNS.Transport.has_path(destination_hash) and
         System.system_time(:second) < limit do
      Process.sleep(100)
      sym = Enum.at(syms, rem(i, length(syms)))
      IO.write("\b\b#{sym} ")
      wait_for_path(destination_hash, syms, i + 1, limit)
    end
  end

  defp truncate_str(str, max_len) do
    if String.length(str) <= max_len do
      str
    else
      String.slice(str, 0, max_len - 1) <> "…"
    end
  end

  defp get_local_identity_hash do
    try do
      state = :sys.get_state(RNS.Transport)
      Map.get(state, :identity_hash)
    rescue
      _ -> nil
    end
  end

  defp print_json_path_table(table) do
    json_table =
      Enum.map(table, fn path ->
        %{
          "hash" => RNS.hexrep(path.hash, false),
          "via" => RNS.hexrep(path.via, false),
          "hops" => path.hops,
          "expires" => path.expires,
          "interface" => path.interface_name
        }
      end)

    IO.puts(inspect(json_table))
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
    Reticulum Path Management Utility

    Usage: rnpath [options] [destination] [list_filter]

    Options:
      --config PATH          Path to alternative Reticulum config directory
      -t, --table            Show all known paths
      -m, --max HOPS         Maximum hops to filter path table by
      -r, --rates            Show announce rate info
      -d, --drop             Remove the path to a destination
      -D, --drop-announces   Drop all queued announces
      -x, --drop-via         Drop all paths via specified transport instance
      -w SECONDS             Timeout before giving up (default: 15)
      -b, --blackholed       List blackholed identities
      -B, --blackhole        Blackhole identity
      -U, --unblackhole      Unblackhole identity
      --duration HOURS       Duration of blackhole enforcement in hours
      --reason TEXT          Reason for blackholing identity
      -j, --json             Output in JSON format
      -v, --verbose          Increase verbosity (can be repeated)
      --version              Print version and exit
      -h, --help             Print this help message and exit

    Arguments:
      destination            Hexadecimal hash of the destination
      list_filter            Filter for remote blackhole list view
    """)
  end
end
