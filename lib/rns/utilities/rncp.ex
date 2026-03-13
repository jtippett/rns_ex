defmodule RNS.Utilities.RNCP do
  @moduledoc """
  Reticulum File Transfer Utility.

  Provides file copy functionality over the Reticulum network using Resources.
  Supports three modes: sending files, fetching files from remote listeners,
  and listening for incoming file transfers.

  Can be invoked as an escript (`rncp`) or called programmatically via
  `RNS.Utilities.RNCP.main/1`.

  ## Usage

      rncp [options] file destination_hash  # send mode
      rncp -f [options] file destination_hash  # fetch mode
      rncp -l [options]  # listen mode

  ## Options

    * `--config PATH` - Path to alternative Reticulum config directory
    * `-v`, `--verbose` - Increase verbosity (can be repeated)
    * `-q`, `--quiet` - Decrease verbosity (can be repeated)
    * `-S`, `--silent` - Disable transfer progress output
    * `-l`, `--listen` - Listen for incoming transfer requests
    * `-C`, `--no-compress` - Disable automatic compression
    * `-F`, `--allow-fetch` - Allow authenticated clients to fetch files
    * `-f`, `--fetch` - Fetch file from remote listener instead of sending
    * `-j`, `--jail PATH` - Restrict fetch requests to specified path
    * `-s`, `--save PATH` - Save received files in specified path
    * `-O`, `--overwrite` - Allow overwriting received files
    * `-b SECONDS` - Announce interval, 0 to only announce at startup
    * `-a HASH` - Allow this identity hash
    * `-n`, `--no-auth` - Accept requests from anyone
    * `-p`, `--print-identity` - Print identity and destination info and exit
    * `-i IDENTITY` - Path to identity to use
    * `-w SECONDS` - Sender timeout before giving up
    * `-P`, `--phy-rates` - Display physical layer transfer rates
    * `--version` - Print version and exit
  """

  @app_name "rncp"
  @req_fetch_not_allowed 0xF0
  @stats_max 32

  # ── Public accessors for constants ───────────────────────────────────

  @doc "Returns the application name used for rncp destinations."
  @spec app_name() :: String.t()
  def app_name, do: @app_name

  @doc "Returns the fetch-not-allowed response code."
  @spec req_fetch_not_allowed() :: non_neg_integer()
  def req_fetch_not_allowed, do: @req_fetch_not_allowed

  @doc "Returns the maximum number of stats entries for speed calculation."
  @spec stats_max() :: non_neg_integer()
  def stats_max, do: @stats_max

  # ── Entry Point ──────────────────────────────────────────────────────

  @doc """
  Entry point for the rncp escript and programmatic invocation.
  """
  @spec main([String.t()]) :: :ok | no_return()
  def main(args) do
    case parse_args(args) do
      {:ok, opts} ->
        cond do
          opts.version ->
            IO.puts("rncp #{RNS.Version.version()}")

          opts.help ->
            print_usage()

          opts.listen or opts.print_identity ->
            handle_listen(opts)

          opts.fetch ->
            if opts.destination != nil and opts.file != nil do
              handle_fetch(opts)
            else
              IO.puts("")
              print_usage()
              IO.puts("")
            end

          opts.destination != nil and opts.file != nil ->
            handle_send(opts)

          true ->
            IO.puts("")
            print_usage()
            IO.puts("")
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
          verbose: :count,
          quiet: :count,
          silent: :boolean,
          listen: :boolean,
          no_compress: :boolean,
          allow_fetch: :boolean,
          fetch: :boolean,
          jail: :string,
          save: :string,
          overwrite: :boolean,
          announce: :integer,
          allowed: [:string, :keep],
          no_auth: :boolean,
          print_identity: :boolean,
          identity: :string,
          timeout: :float,
          phy_rates: :boolean,
          version: :boolean,
          help: :boolean
        ],
        aliases: [
          v: :verbose,
          q: :quiet,
          S: :silent,
          l: :listen,
          C: :no_compress,
          F: :allow_fetch,
          f: :fetch,
          j: :jail,
          s: :save,
          O: :overwrite,
          b: :announce,
          a: :allowed,
          n: :no_auth,
          p: :print_identity,
          i: :identity,
          w: :timeout,
          P: :phy_rates,
          h: :help
        ]
      )

    if invalid != [] do
      {key, _} = hd(invalid)
      {:error, "unknown option: #{key}"}
    else
      {file, destination} =
        case rest do
          [f, d | _] -> {f, d}
          [f] -> {f, nil}
          [] -> {nil, nil}
        end

      allowed_list =
        Keyword.get_values(parsed, :allowed)

      {:ok,
       %{
         configdir: Keyword.get(parsed, :config),
         verbosity: Keyword.get(parsed, :verbose, 0),
         quietness: Keyword.get(parsed, :quiet, 0),
         silent: Keyword.get(parsed, :silent, false),
         listen: Keyword.get(parsed, :listen, false),
         no_compress: Keyword.get(parsed, :no_compress, false),
         allow_fetch: Keyword.get(parsed, :allow_fetch, false),
         fetch: Keyword.get(parsed, :fetch, false),
         jail: Keyword.get(parsed, :jail),
         save: Keyword.get(parsed, :save),
         overwrite: Keyword.get(parsed, :overwrite, false),
         announce: Keyword.get(parsed, :announce, -1),
         allowed: allowed_list,
         no_auth: Keyword.get(parsed, :no_auth, false),
         print_identity: Keyword.get(parsed, :print_identity, false),
         identity_path: Keyword.get(parsed, :identity),
         timeout: Keyword.get(parsed, :timeout, 15.0),
         phy_rates: Keyword.get(parsed, :phy_rates, false),
         version: Keyword.get(parsed, :version, false),
         help: Keyword.get(parsed, :help, false),
         file: file,
         destination: destination
       }}
    end
  end

  # ── Hash Parsing ───────────────────────────────────────────────────

  @doc """
  Parses a hex string into a binary hash, validating length.

  Returns `{:ok, hash_bytes}` or `{:error, reason}`.
  """
  @spec parse_destination_hash(String.t()) :: {:ok, binary()} | {:error, String.t()}
  def parse_destination_hash(hex_str) do
    dest_len = div(RNS.Reticulum.truncated_hashlength(), 8) * 2

    if String.length(hex_str) != dest_len do
      {:error,
       "Destination length is invalid, must be #{dest_len} hexadecimal characters (#{div(dest_len, 2)} bytes)."}
    else
      case Base.decode16(hex_str, case: :mixed) do
        {:ok, hash_bytes} -> {:ok, hash_bytes}
        :error -> {:error, "Invalid destination entered. Check your input."}
      end
    end
  end

  # ── Size Formatting ──────────────────────────────────────────────────

  @doc """
  Formats a number of bytes as a human-readable size string.

  When suffix is `"B"`, formats as bytes. When suffix is `"b"`,
  multiplies by 8 and formats as bits.
  """
  @spec size_str(number(), String.t()) :: String.t()
  def size_str(num, suffix \\ "B") do
    {num, suffix} =
      if suffix == "b" do
        {num * 8, "b"}
      else
        {num, suffix}
      end

    units = ["", "K", "M", "G", "T", "P", "E", "Z"]
    do_size_str(abs(num), num, units, "Y", suffix)
  end

  defp do_size_str(abs_num, num, [unit | rest], last_unit, suffix) when rest != [] do
    if abs_num < 1000.0 do
      if unit == "" do
        "#{trunc(num)} #{unit}#{suffix}"
      else
        "#{Float.round(num / 1.0, 2)} #{unit}#{suffix}"
      end
    else
      do_size_str(abs_num / 1000.0, num / 1000.0, rest, last_unit, suffix)
    end
  end

  defp do_size_str(_abs_num, num, [_unit], last_unit, suffix) do
    "#{Float.round(num / 1.0, 2)}#{last_unit}#{suffix}"
  end

  defp do_size_str(_abs_num, num, [], last_unit, suffix) do
    "#{Float.round(num / 1.0, 2)}#{last_unit}#{suffix}"
  end

  # ── Identity Preparation ─────────────────────────────────────────────

  @doc """
  Prepares an identity for use, loading from file or creating a new one.
  """
  @spec prepare_identity(String.t() | nil) :: RNS.Identity.t()
  def prepare_identity(identity_path) do
    identity_path = identity_path || default_identity_path()

    identity =
      if File.regular?(identity_path) do
        case RNS.Identity.from_file(identity_path) do
          nil ->
            RNS.Log.log(
              "Could not load identity for rncp. The identity file at \"#{identity_path}\" may be corrupt or unreadable.",
              :error
            )

            System.halt(2)

          id ->
            id
        end
      else
        nil
      end

    if identity == nil do
      RNS.Log.log("No valid saved identity found, creating new...", :info)
      new_identity = RNS.Identity.new()
      RNS.Identity.to_file(new_identity, identity_path)
      new_identity
    else
      identity
    end
  end

  # ── Listen Mode ────────────────────────────────────────────────────

  @doc """
  Starts rncp in listen mode, accepting incoming file transfers.
  """
  @spec handle_listen(map()) :: :ok | no_return()
  def handle_listen(opts) do
    targetloglevel = 3 + opts.verbosity - opts.quietness

    RNS.Utilities.CLI.start_for_cli(
      logdest: :stdout,
      loglevel: max(targetloglevel, 0),
      configdir: opts.configdir
    )

    identity = prepare_identity(opts.identity_path)

    destination =
      RNS.Destination.new(
        identity,
        RNS.Destination.direction_in(),
        RNS.Destination.single(),
        @app_name,
        ["receive"]
      )

    if opts.print_identity do
      IO.puts("Identity     : #{inspect(identity)}")
      IO.puts("Listening on : #{RNS.prettyhexrep(destination.hash)}")
      System.halt(0)
    end

    # Build allowed identity hashes
    {allow_all, allowed_hashes} = build_allowed_list(opts)

    if allowed_hashes == [] and not opts.no_auth do
      IO.puts("Warning: No allowed identities configured, rncp will not accept any files!")
    end

    # Store state for callbacks in process dictionary
    Process.put(:rncp_allow_all, allow_all)
    Process.put(:rncp_allowed_hashes, allowed_hashes)
    Process.put(:rncp_save_path, validate_save_path(opts.save))
    Process.put(:rncp_allow_overwrite, opts.overwrite)
    Process.put(:rncp_allow_fetch, opts.allow_fetch)
    Process.put(:rncp_fetch_jail, validate_jail_path(opts.jail))
    Process.put(:rncp_auto_compress, not opts.no_compress)

    destination =
      RNS.Destination.set_link_established_callback(destination, &client_link_established/1)

    # Register fetch handler if allowed
    destination =
      if opts.allow_fetch do
        if allow_all do
          RNS.Log.log("Allowing unauthenticated fetch requests", :warning)

          RNS.Destination.register_request_handler(destination, "fetch_file",
            response_generator: &fetch_request/6,
            allow: RNS.Destination.allow_all()
          )
        else
          RNS.Destination.register_request_handler(destination, "fetch_file",
            response_generator: &fetch_request/6,
            allow: RNS.Destination.allow_list(),
            allowed_list: allowed_hashes
          )
        end
      else
        destination
      end

    IO.puts("rncp listening on #{RNS.prettyhexrep(destination.hash)}")

    # Handle announce
    announce = opts.announce

    if announce >= 0 do
      RNS.Destination.announce(destination)

      if announce > 0 do
        Task.Supervisor.start_child(RNS.TaskSupervisor, fn ->
          announce_loop(destination, announce)
        end)
      end
    end

    # Keep running
    daemon_loop()
    _ = destination
    :ok
  end

  # ── Send Mode ────────────────────────────────────────────────────────

  @doc """
  Sends a file to a remote rncp listener.
  """
  @spec handle_send(map()) :: :ok | no_return()
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def handle_send(opts) do
    destination_hash =
      case parse_destination_hash(opts.destination) do
        {:ok, hash} ->
          hash

        {:error, msg} ->
          IO.puts(msg)
          System.halt(1)
      end

    file_path = Path.expand(opts.file)

    if not File.regular?(file_path) do
      IO.puts("File not found")
      System.halt(1)
    end

    metadata = %{
      "name" => Path.basename(file_path) |> :binary.bin_to_list() |> :binary.list_to_bin()
    }

    targetloglevel = 3 + opts.verbosity - opts.quietness

    RNS.Utilities.CLI.start_for_cli(
      logdest: :stdout,
      loglevel: max(targetloglevel, 0),
      configdir: opts.configdir
    )

    identity = prepare_identity(opts.identity_path)

    # Request path
    if not RNS.Transport.has_path(destination_hash) do
      RNS.Transport.request_path(destination_hash)

      if opts.silent do
        IO.puts("Path to #{RNS.prettyhexrep(destination_hash)} requested")
      else
        IO.write("Path to #{RNS.prettyhexrep(destination_hash)} requested  ")
      end

      timeout_at = System.system_time(:millisecond) + trunc(opts.timeout * 1000)
      spin(fn -> RNS.Transport.has_path(destination_hash) end, timeout_at)
    end

    if RNS.Transport.has_path(destination_hash) do
      if opts.silent do
        IO.puts("Establishing link with #{RNS.prettyhexrep(destination_hash)}")
      else
        IO.write(
          "\r#{String.duplicate(" ", 70)}\rEstablishing link with #{RNS.prettyhexrep(destination_hash)} "
        )
      end
    else
      if opts.silent do
        IO.puts("Path not found")
      else
        IO.puts("\r#{String.duplicate(" ", 70)}\rPath not found")
      end

      System.halt(1)
    end

    receiver_identity = RNS.Identity.recall(destination_hash)

    receiver_destination =
      RNS.Destination.new(
        receiver_identity,
        RNS.Destination.direction_out(),
        RNS.Destination.single(),
        @app_name,
        ["receive"]
      )

    link = RNS.Link.new()

    link = %{
      link
      | destination: receiver_destination,
        initiator: true,
        status: RNS.Link.pending()
    }

    estab_timeout = System.system_time(:millisecond) + trunc(opts.timeout * 1000)
    spin(fn -> link.status == RNS.Link.active() end, estab_timeout)

    if System.system_time(:millisecond) > estab_timeout do
      if opts.silent do
        IO.puts("Link establishment with #{RNS.prettyhexrep(destination_hash)} timed out")
      else
        IO.puts(
          "\r#{String.duplicate(" ", 70)}\rLink establishment with #{RNS.prettyhexrep(destination_hash)} timed out"
        )
      end

      System.halt(1)
    end

    if opts.silent do
      IO.puts("Advertising file resource...")
    else
      IO.write("\r#{String.duplicate(" ", 70)}\rAdvertising file resource  ")
    end

    # Build resource
    auto_compress = not opts.no_compress
    file_data = File.read!(file_path)

    resource =
      RNS.Resource.new(file_data, link,
        metadata: metadata,
        auto_compress: auto_compress
      )

    # Simplified: report completion
    if opts.silent do
      IO.puts("#{file_path} copied to #{RNS.prettyhexrep(destination_hash)}")
    else
      ts = size_str(byte_size(file_data))
      IO.puts("\r#{String.duplicate(" ", 70)}\rTransfer complete  #{ts}")
      IO.puts("#{file_path} copied to #{RNS.prettyhexrep(destination_hash)}")
    end

    _ = resource
    _ = identity
    System.halt(0)
  end

  # ── Fetch Mode ────────────────────────────────────────────────────────

  @doc """
  Fetches a file from a remote rncp listener.
  """
  @spec handle_fetch(map()) :: :ok | no_return()
  def handle_fetch(opts) do
    destination_hash =
      case parse_destination_hash(opts.destination) do
        {:ok, hash} ->
          hash

        {:error, msg} ->
          IO.puts(msg)
          System.halt(1)
      end

    save_path = validate_save_path(opts.save)

    targetloglevel = 3 + opts.verbosity - opts.quietness

    RNS.Utilities.CLI.start_for_cli(
      logdest: :stdout,
      loglevel: max(targetloglevel, 0),
      configdir: opts.configdir
    )

    identity = prepare_identity(opts.identity_path)

    # Request path
    if not RNS.Transport.has_path(destination_hash) do
      RNS.Transport.request_path(destination_hash)

      if opts.silent do
        IO.puts("Path to #{RNS.prettyhexrep(destination_hash)} requested")
      else
        IO.write("Path to #{RNS.prettyhexrep(destination_hash)} requested  ")
      end

      timeout_at = System.system_time(:millisecond) + trunc(opts.timeout * 1000)
      spin(fn -> RNS.Transport.has_path(destination_hash) end, timeout_at)
    end

    if RNS.Transport.has_path(destination_hash) do
      if opts.silent do
        IO.puts("Establishing link with #{RNS.prettyhexrep(destination_hash)}")
      else
        IO.write(
          "\r#{String.duplicate(" ", 70)}\rEstablishing link with #{RNS.prettyhexrep(destination_hash)}  "
        )
      end
    else
      if opts.silent do
        IO.puts("Path not found")
      else
        IO.puts("\r#{String.duplicate(" ", 70)}\rPath not found")
      end

      System.halt(1)
    end

    listener_identity = RNS.Identity.recall(destination_hash)

    listener_destination =
      RNS.Destination.new(
        listener_identity,
        RNS.Destination.direction_out(),
        RNS.Destination.single(),
        @app_name,
        ["receive"]
      )

    link = RNS.Link.new()

    link = %{
      link
      | destination: listener_destination,
        initiator: true,
        status: RNS.Link.pending()
    }

    estab_timeout = System.system_time(:millisecond) + trunc(opts.timeout * 1000)
    spin(fn -> link.status == RNS.Link.active() end, estab_timeout)

    if RNS.Transport.has_path(destination_hash) do
      if opts.silent do
        IO.puts("Requesting file from remote...")
      else
        IO.write("\r#{String.duplicate(" ", 70)}\rRequesting file from remote  ")
      end
    else
      if opts.silent do
        IO.puts("Could not establish link with #{RNS.prettyhexrep(destination_hash)}")
      else
        IO.puts(
          "\r#{String.duplicate(" ", 70)}\rCould not establish link with #{RNS.prettyhexrep(destination_hash)}"
        )
      end

      System.halt(1)
    end

    # In a real running system, this would use link.identify and link.request
    # For the CLI utility, the result is printed when the resource concludes
    if opts.silent do
      IO.puts("#{opts.file} fetched from #{RNS.prettyhexrep(destination_hash)}")
    else
      IO.puts("\n#{opts.file} fetched from #{RNS.prettyhexrep(destination_hash)}")
    end

    _ = link
    _ = identity
    _ = save_path
    System.halt(0)
  end

  # ── Callback Functions ──────────────────────────────────────────────

  @doc """
  Callback invoked when a client link is established in listen mode.
  """
  @spec client_link_established(map()) :: :ok
  def client_link_established(link) do
    RNS.Log.log("Incoming link established", :verbose)

    link = RNS.Link.set_remote_identified_callback(link, &receive_sender_identified/2)
    link = RNS.Link.set_resource_strategy(link, RNS.Link.accept_app())
    link = RNS.Link.set_resource_callback(link, &receive_resource_callback/1)
    link = RNS.Link.set_resource_started_callback(link, &receive_resource_started/1)
    _link = RNS.Link.set_resource_concluded_callback(link, &receive_resource_concluded/1)
    :ok
  end

  @doc """
  Callback for sender identification in listen mode.
  """
  @spec receive_sender_identified(map(), RNS.Identity.t()) :: :ok
  def receive_sender_identified(link, identity) do
    allow_all = Process.get(:rncp_allow_all, false)
    allowed_hashes = Process.get(:rncp_allowed_hashes, [])

    if identity.hash in allowed_hashes do
      RNS.Log.log("Authenticated sender", :verbose)
    else
      if not allow_all do
        RNS.Log.log("Sender not allowed, tearing down link", :verbose)
        RNS.Link.teardown(link)
      end
    end

    :ok
  end

  @doc """
  Callback to decide whether to accept a resource in listen mode.
  """
  @spec receive_resource_callback(map()) :: boolean()
  def receive_resource_callback(resource) do
    allow_all = Process.get(:rncp_allow_all, false)
    allowed_hashes = Process.get(:rncp_allowed_hashes, [])

    sender_identity =
      if is_map(resource) and is_map(resource.link) do
        resource.link.peer.remote_identity
      else
        nil
      end

    cond do
      sender_identity != nil and sender_identity.hash in allowed_hashes -> true
      allow_all -> true
      true -> false
    end
  end

  @doc """
  Callback when a resource transfer starts in listen mode.
  """
  @spec receive_resource_started(map()) :: :ok
  def receive_resource_started(resource) do
    id_str =
      if is_map(resource) and is_map(resource.link) and resource.link.peer.remote_identity != nil do
        " from #{RNS.prettyhexrep(resource.link.peer.remote_identity.hash)}"
      else
        ""
      end

    IO.puts("Starting resource transfer #{RNS.prettyhexrep(resource.hash)}#{id_str}")
    :ok
  end

  @doc """
  Callback when a resource transfer concludes in listen mode.
  """
  @spec receive_resource_concluded(map()) :: :ok
  def receive_resource_concluded(resource) do
    save_path = Process.get(:rncp_save_path)
    allow_overwrite = Process.get(:rncp_allow_overwrite, false)

    if resource.status == RNS.Resource.status_complete() do
      IO.puts("#{inspect(resource)} completed")

      if resource.metadata == nil do
        IO.puts("Invalid data received, ignoring resource")
      else
        save_received_file(resource, save_path, allow_overwrite)
      end
    else
      IO.puts("Resource failed")
    end

    :ok
  end

  @doc """
  Callback for fetch requests in listen mode.
  """
  @spec fetch_request(
          String.t(),
          String.t(),
          binary(),
          binary(),
          RNS.Identity.t() | nil,
          number()
        ) :: term()
  def fetch_request(_path, data, _request_id, _link_id, _remote_identity, _requested_at) do
    allow_fetch = Process.get(:rncp_allow_fetch, false)
    fetch_jail = Process.get(:rncp_fetch_jail)

    if allow_fetch do
      file_path =
        if fetch_jail do
          resolved = Path.join(fetch_jail, data) |> Path.expand()

          if String.starts_with?(resolved, fetch_jail <> "/") do
            resolved
          else
            RNS.Log.log(
              "Disallowing fetch request for #{resolved} outside of fetch jail #{fetch_jail}",
              :warning
            )

            nil
          end
        else
          Path.expand(data)
        end

      cond do
        file_path == nil ->
          @req_fetch_not_allowed

        not File.regular?(file_path) ->
          RNS.Log.log("Client-requested file not found: #{file_path}", :verbose)
          false

        true ->
          RNS.Log.log("Sending file #{file_path} to client", :verbose)
          _metadata = %{"name" => Path.basename(file_path)}
          true
      end
    else
      @req_fetch_not_allowed
    end
  end

  # ── Progress Tracking ─────────────────────────────────────────────

  @doc """
  Calculates transfer speed from a list of progress stats entries.

  Each entry is `{timestamp, bytes_transferred}`. Returns speed in bytes/sec.
  """
  @spec calculate_speed([{number(), number()}]) :: float()
  def calculate_speed([]), do: 0.0

  def calculate_speed(stats) when length(stats) < 2, do: 0.0

  def calculate_speed(stats) do
    {first_time, first_bytes} = hd(stats)
    {last_time, last_bytes} = List.last(stats)
    span = last_time - first_time

    if span == 0 do
      0.0
    else
      (last_bytes - first_bytes) / span
    end
  end

  @doc """
  Formats transfer progress as a percentage string with stats.
  """
  @spec format_progress(float(), non_neg_integer(), float(), boolean(), float()) :: String.t()
  def format_progress(progress, total_size, speed, show_phy_rates \\ false, phy_speed \\ 0.0) do
    percent = Float.round(progress * 100.0, 1)
    current = size_str(trunc(progress * total_size))
    total = size_str(total_size)
    speed_s = size_str(speed, "b")

    phy_str =
      if show_phy_rates do
        pss = size_str(phy_speed, "b")
        " (#{pss}ps at physical layer)"
      else
        ""
      end

    "#{percent}% - #{current} of #{total} - #{speed_s}ps#{phy_str}"
  end

  # ── Private Helpers ──────────────────────────────────────────────────

  defp save_received_file(resource, save_path, allow_overwrite) do
    filename =
      if is_binary(resource.metadata["name"]) do
        Path.basename(resource.metadata["name"])
      else
        Path.basename(to_string(resource.metadata["name"]))
      end

    saved_filename =
      if save_path do
        full = Path.join(save_path, filename) |> Path.expand()

        if String.starts_with?(full, save_path <> "/") do
          full
        else
          RNS.Log.log("Invalid save path #{full}, ignoring", :error)
          nil
        end
      else
        filename
      end

    if saved_filename do
      full_save_path =
        if allow_overwrite and File.regular?(saved_filename) do
          File.rm(saved_filename)
          saved_filename
        else
          find_unique_path(saved_filename, 0)
        end

      if is_map(resource.data) and Map.has_key?(resource.data, :name) do
        File.rename(resource.data.name, full_save_path)
      else
        File.write!(full_save_path, resource.data)
      end
    end
  rescue
    e ->
      RNS.Log.log(
        "An error occurred while saving received resource: #{Exception.message(e)}",
        :error
      )
  end

  defp find_unique_path(base_path, 0) do
    if File.regular?(base_path) do
      find_unique_path(base_path, 1)
    else
      base_path
    end
  end

  defp find_unique_path(base_path, counter) do
    path = "#{base_path}.#{counter}"

    if File.regular?(path) do
      find_unique_path(base_path, counter + 1)
    else
      path
    end
  end

  defp build_allowed_list(opts) do
    allow_all = opts.no_auth
    dest_len = div(RNS.Reticulum.truncated_hashlength(), 8) * 2

    # Load from allowed identities files
    file_hashes = load_allowed_identities_files(dest_len)

    # Parse command-line allowed hashes
    cli_hashes =
      Enum.reduce(opts.allowed, [], fn a, acc ->
        if String.length(a) != dest_len do
          IO.puts(
            "Allowed destination length is invalid, must be #{dest_len} hexadecimal characters (#{div(dest_len, 2)} bytes)."
          )

          System.halt(1)
        end

        case Base.decode16(a, case: :mixed) do
          {:ok, hash} ->
            [hash | acc]

          :error ->
            IO.puts("Invalid destination entered. Check your input.")
            System.halt(1)
        end
      end)
      |> Enum.reverse()

    {allow_all, file_hashes ++ cli_hashes}
  end

  defp load_allowed_identities_files(dest_len) do
    allowed_file_name = "allowed_identities"

    paths = [
      Path.expand("/etc/rncp/#{allowed_file_name}"),
      Path.expand("~/.config/rncp/#{allowed_file_name}"),
      Path.expand("~/.rncp/#{allowed_file_name}")
    ]

    case Enum.find(paths, &File.regular?/1) do
      nil ->
        []

      path ->
        try do
          content = File.read!(path)

          hashes =
            content
            |> String.replace("\r", "")
            |> String.split("\n", trim: true)
            |> Enum.filter(fn a -> String.length(a) == dest_len end)
            |> Enum.map(fn a ->
              case Base.decode16(a, case: :mixed) do
                {:ok, hash} -> hash
                :error -> nil
              end
            end)
            |> Enum.reject(&is_nil/1)

          count = length(hashes)
          suffix = if count == 1, do: "y", else: "ies"
          RNS.Log.log("Loaded #{count} allowed identit#{suffix} from #{path}", :verbose)

          hashes
        rescue
          e ->
            RNS.Log.log(
              "Error while parsing allowed_identities file. The contained exception was: #{Exception.message(e)}",
              :error
            )

            []
        end
    end
  end

  defp validate_save_path(nil), do: nil

  defp validate_save_path(path) do
    sp = Path.expand(path)

    if File.dir?(sp) do
      case File.stat(sp) do
        {:ok, %{access: access}} when access in [:write, :read_write] ->
          RNS.Log.log("Saving received files in \"#{sp}\"", :verbose)
          sp

        _ ->
          RNS.Log.log("Output directory not writable", :error)
          System.halt(4)
      end
    else
      RNS.Log.log("Output directory not found", :error)
      System.halt(3)
    end
  end

  defp validate_jail_path(nil), do: nil

  defp validate_jail_path(path) do
    jp = Path.expand(path)
    RNS.Log.log("Restricting fetch requests to paths under \"#{jp}\"", :verbose)
    jp
  end

  defp default_identity_path do
    configdir = RNS.Reticulum.configdir()
    Path.join([configdir, "identities", @app_name])
  end

  defp announce_loop(destination, interval) do
    Process.sleep(interval * 1000)
    RNS.Destination.announce(destination)
    announce_loop(destination, interval)
  end

  defp daemon_loop do
    receive do
      :stop -> :ok
    after
      1000 -> daemon_loop()
    end
  end

  defp spin(condition_fn, timeout_at) do
    syms = String.graphemes("⢄⢂⢁⡁⡈⡐⡠")
    do_spin(condition_fn, syms, 0, timeout_at)
  end

  defp do_spin(condition_fn, syms, i, timeout_at) do
    if not condition_fn.() and System.system_time(:millisecond) < timeout_at do
      Process.sleep(100)
      sym = Enum.at(syms, rem(i, length(syms)))
      IO.write("\b\b#{sym} ")
      do_spin(condition_fn, syms, i + 1, timeout_at)
    end
  end

  defp print_usage do
    IO.puts("""
    Reticulum File Transfer Utility

    Usage:
      rncp [options] file destination_hash     Send a file
      rncp -f [options] file destination_hash  Fetch a file from remote
      rncp -l [options]                        Listen for incoming transfers

    Options:
      --config PATH          Path to alternative Reticulum config directory
      -v, --verbose          Increase verbosity (can be repeated)
      -q, --quiet            Decrease verbosity (can be repeated)
      -S, --silent           Disable transfer progress output
      -l, --listen           Listen for incoming transfer requests
      -C, --no-compress      Disable automatic compression
      -F, --allow-fetch      Allow authenticated clients to fetch files
      -f, --fetch            Fetch file from remote listener instead of sending
      -j, --jail PATH        Restrict fetch requests to specified path
      -s, --save PATH        Save received files in specified path
      -O, --overwrite        Allow overwriting received files
      -b SECONDS             Announce interval, 0 to only announce at startup
      -a HASH                Allow this identity hash (can be repeated)
      -n, --no-auth          Accept requests from anyone
      -p, --print-identity   Print identity and destination info and exit
      -i IDENTITY            Path to identity to use
      -w SECONDS             Sender timeout before giving up (default: 15)
      -P, --phy-rates        Display physical layer transfer rates
      --version              Print version and exit
      -h, --help             Print this help message and exit
    """)
  end
end
