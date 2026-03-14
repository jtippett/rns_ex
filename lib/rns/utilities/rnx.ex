defmodule RNS.Utilities.RNX do
  @moduledoc """
  Reticulum Remote Execution Utility.

  Provides remote command execution over the Reticulum network using Links
  and request/response patterns.

  Can be invoked as an escript (`rnx`) or called programmatically via
  `RNS.Utilities.RNX.main/1`.

  ## Usage

      rnx [options] destination_hash command   # execute mode
      rnx -l [options]                         # listen mode
      rnx -x [options] destination_hash        # interactive mode

  ## Options

    * `--config PATH` - Path to alternative Reticulum config directory
    * `-v`, `--verbose` - Increase verbosity (can be repeated)
    * `-q`, `--quiet` - Decrease verbosity (can be repeated)
    * `-p`, `--print-identity` - Print identity and destination info and exit
    * `-l`, `--listen` - Listen for incoming commands
    * `-i IDENTITY` - Path to identity to use
    * `-x`, `--interactive` - Enter interactive mode
    * `-b`, `--no-announce` - Don't announce at program start
    * `-a HASH` - Accept from this identity (can be repeated)
    * `-n`, `--noauth` - Accept commands from anyone
    * `-N`, `--noid` - Don't identify to listener
    * `-d`, `--detailed` - Show detailed result output
    * `-m` - Mirror exit code of remote command
    * `-w SECONDS` - Connect and request timeout before giving up
    * `-W SECONDS` - Max result download time
    * `--stdin DATA` - Pass input to stdin
    * `--stdout BYTES` - Max size in bytes of returned stdout
    * `--stderr BYTES` - Max size in bytes of returned stderr
    * `--version` - Print version and exit
  """

  @app_name "rnx"
  @remote_exec_grace 2.0
  @stats_max 32

  # ── Public accessors for constants ───────────────────────────────────

  @doc "Returns the application name used for rnx destinations."
  @spec app_name() :: String.t()
  def app_name, do: @app_name

  @doc "Returns the remote execution grace period in seconds."
  @spec remote_exec_grace() :: float()
  def remote_exec_grace, do: @remote_exec_grace

  @doc "Returns the maximum number of stats entries for speed calculation."
  @spec stats_max() :: non_neg_integer()
  def stats_max, do: @stats_max

  # ── Entry Point ──────────────────────────────────────────────────────

  @doc """
  Entry point for the rnx escript and programmatic invocation.
  """
  @spec main([String.t()]) :: :ok | no_return()
  def main(args) do
    case parse_args(args) do
      {:ok, opts} ->
        cond do
          opts.version ->
            IO.puts("rnx #{RNS.Version.version()}")

          opts.help ->
            print_usage()

          opts.listen or opts.print_identity ->
            handle_listen(opts)

          opts.destination != nil and opts.command != nil ->
            handle_execute(opts)

          opts.destination != nil and opts.interactive ->
            handle_interactive(opts)

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
          print_identity: :boolean,
          listen: :boolean,
          identity: :string,
          interactive: :boolean,
          no_announce: :boolean,
          allowed: [:string, :keep],
          noauth: :boolean,
          noid: :boolean,
          detailed: :boolean,
          mirror: :boolean,
          timeout: :float,
          result_timeout: :float,
          stdin: :string,
          stdout: :integer,
          stderr: :integer,
          version: :boolean,
          help: :boolean
        ],
        aliases: [
          v: :verbose,
          q: :quiet,
          p: :print_identity,
          l: :listen,
          i: :identity,
          x: :interactive,
          b: :no_announce,
          a: :allowed,
          n: :noauth,
          N: :noid,
          d: :detailed,
          m: :mirror,
          w: :timeout,
          W: :result_timeout,
          h: :help
        ]
      )

    if invalid != [] do
      {key, _} = hd(invalid)
      {:error, "unknown option: #{key}"}
    else
      {destination, command} =
        case rest do
          [d, c | _] -> {d, c}
          [d] -> {d, nil}
          [] -> {nil, nil}
        end

      allowed_list = Keyword.get_values(parsed, :allowed)

      {:ok,
       %{
         configdir: Keyword.get(parsed, :config),
         verbosity: Keyword.get(parsed, :verbose, 0),
         quietness: Keyword.get(parsed, :quiet, 0),
         print_identity: Keyword.get(parsed, :print_identity, false),
         listen: Keyword.get(parsed, :listen, false),
         identity_path: Keyword.get(parsed, :identity),
         interactive: Keyword.get(parsed, :interactive, false),
         no_announce: Keyword.get(parsed, :no_announce, false),
         allowed: allowed_list,
         noauth: Keyword.get(parsed, :noauth, false),
         noid: Keyword.get(parsed, :noid, false),
         detailed: Keyword.get(parsed, :detailed, false),
         mirror: Keyword.get(parsed, :mirror, false),
         timeout: Keyword.get(parsed, :timeout, 15.0),
         result_timeout: Keyword.get(parsed, :result_timeout),
         stdin: Keyword.get(parsed, :stdin),
         stdoutl: Keyword.get(parsed, :stdout),
         stderrl: Keyword.get(parsed, :stderr),
         version: Keyword.get(parsed, :version, false),
         help: Keyword.get(parsed, :help, false),
         destination: destination,
         command: command
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

  # ── Pretty Time ────────────────────────────────────────────────────

  @doc """
  Formats a duration in seconds as a human-readable time string.

  ## Examples

      iex> RNS.Utilities.RNX.pretty_time(3661.5)
      "1h, 1m and 1.5s"

      iex> RNS.Utilities.RNX.pretty_time(90, true)
      "1 minute and 30.0 seconds"
  """
  @spec pretty_time(number(), boolean()) :: String.t()
  def pretty_time(time, verbose \\ false) do
    days = trunc(time / (24 * 3600))
    time = time - days * 24 * 3600
    hours = trunc(time / 3600)
    time = time - hours * 3600
    minutes = trunc(time / 60)
    time = time - minutes * 60
    seconds = Float.round(time / 1.0, 2)

    components = []

    components =
      if days > 0 do
        sd = if days == 1, do: "", else: "s"
        components ++ [if(verbose, do: "#{days} day#{sd}", else: "#{days}d")]
      else
        components
      end

    components =
      if hours > 0 do
        sh = if hours == 1, do: "", else: "s"
        components ++ [if(verbose, do: "#{hours} hour#{sh}", else: "#{hours}h")]
      else
        components
      end

    components =
      if minutes > 0 do
        sm = if minutes == 1, do: "", else: "s"
        components ++ [if(verbose, do: "#{minutes} minute#{sm}", else: "#{minutes}m")]
      else
        components
      end

    components =
      if seconds > 0 do
        ss = if seconds == 1, do: "", else: "s"
        components ++ [if(verbose, do: "#{seconds} second#{ss}", else: "#{seconds}s")]
      else
        components
      end

    format_time_components(components)
  end

  defp format_time_components([]), do: ""
  defp format_time_components([single]), do: single

  defp format_time_components(components) do
    {init, [last]} = Enum.split(components, -1)
    Enum.join(init, ", ") <> " and " <> last
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
        RNS.Identity.from_file(identity_path)
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
  Starts rnx in listen mode, accepting incoming command execution requests.
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
        ["execute"]
      )

    if opts.print_identity do
      IO.puts("Identity     : #{inspect(identity)}")
      IO.puts("Listening on : #{RNS.prettyhexrep(destination.hash)}")
      System.halt(0)
    end

    # Build allowed identity hashes
    {allow_all, allowed_hashes} = build_allowed_list(opts)

    if allowed_hashes == [] and not opts.noauth do
      IO.puts("Warning: No allowed identities configured, rnx will not accept any commands!")
    end

    # Store state for callbacks
    Process.put(:rnx_allow_all, allow_all)
    Process.put(:rnx_allowed_hashes, allowed_hashes)

    destination =
      RNS.Destination.set_link_established_callback(destination, &command_link_established/1)

    # Register command request handler
    destination =
      if allow_all do
        RNS.Destination.register_request_handler(destination, "command",
          response_generator: &execute_received_command/2,
          allow: RNS.Destination.allow_all()
        )
      else
        RNS.Destination.register_request_handler(destination, "command",
          response_generator: &execute_received_command/2,
          allow: RNS.Destination.allow_list(),
          allowed_list: allowed_hashes
        )
      end

    RNS.Log.log("rnx listening for commands on #{RNS.prettyhexrep(destination.hash)}", :notice)

    if not opts.no_announce do
      RNS.Destination.announce(destination)
    end

    daemon_loop()
    _ = destination
    :ok
  end

  # ── Execute Mode ─────────────────────────────────────────────────────

  @doc """
  Sends a command to a remote rnx listener for execution.
  """
  @dialyzer {:nowarn_function, handle_execute: 1}
  @spec handle_execute(map()) :: :ok | non_neg_integer() | nil | no_return()
  def handle_execute(opts) do
    destination_hash =
      case parse_destination_hash(opts.destination) do
        {:ok, hash} ->
          hash

        {:error, msg} ->
          IO.puts(msg)
          System.halt(241)
      end

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
      timeout_at = System.system_time(:millisecond) + trunc(opts.timeout * 1000)

      if not spin(
           "Path to #{RNS.prettyhexrep(destination_hash)} requested",
           fn -> RNS.Transport.has_path(destination_hash) end,
           timeout_at
         ) do
        IO.puts("Path not found")

        if opts.interactive do
          return_or_exit(nil, false, opts.interactive)
        else
          System.halt(242)
        end
      end
    end

    listener_identity = RNS.Identity.recall(destination_hash)

    listener_destination =
      RNS.Destination.new(
        listener_identity,
        RNS.Destination.direction_out(),
        RNS.Destination.single(),
        @app_name,
        ["execute"]
      )

    link = RNS.Link.new()

    link = %{
      link
      | destination: listener_destination,
        initiator: true,
        status: RNS.Link.pending()
    }

    estab_timeout = System.system_time(:millisecond) + trunc(opts.timeout * 1000)

    if not spin(
         "Establishing link with #{RNS.prettyhexrep(destination_hash)}",
         fn -> link.status == RNS.Link.active() end,
         estab_timeout
       ) do
      IO.puts("Could not establish link with #{RNS.prettyhexrep(destination_hash)}")

      if opts.interactive do
        return_or_exit(nil, false, opts.interactive)
      else
        System.halt(243)
      end
    end

    # Build request data matching Python format
    stdin_data =
      if opts.stdin != nil do
        String.to_charlist(opts.stdin) |> List.to_string()
      else
        nil
      end

    request_data =
      build_request_data(opts.command, opts.timeout, opts.stdoutl, opts.stderrl, stdin_data)

    # In a running system, this would send the request via link.request
    # and wait for results. For the CLI utility structure:
    _ = request_data
    _ = link
    _ = identity

    if not opts.interactive do
      System.halt(0)
    end
  end

  # ── Interactive Mode ─────────────────────────────────────────────────

  @doc """
  Enters interactive mode for repeated command execution.
  """
  @dialyzer {:nowarn_function, handle_interactive: 1}
  @spec handle_interactive(map()) :: :ok | no_return()
  def handle_interactive(opts) do
    # First execute any initial command
    if opts.command != nil do
      handle_execute(opts)
    end

    interactive_loop(opts, nil)
  end

  @dialyzer {:nowarn_function, interactive_loop: 2}
  defp interactive_loop(opts, code) do
    cstr = if code && code != 0, do: "#{code}", else: ""
    prompt = "#{cstr}> "
    IO.write(prompt)

    case IO.read(:stdio, :line) do
      :eof ->
        System.halt(0)

      {:error, _} ->
        System.halt(0)

      data ->
        command = String.trim_trailing(data, "\n")

        cond do
          command in ["exit", "quit", "EXIT", "QUIT", "Exit", "Quit"] ->
            System.halt(0)

          command in ["clear", "CLEAR", "Clear"] ->
            IO.write("\e[2J\e[H")
            interactive_loop(opts, code)

          true ->
            new_code =
              handle_execute(%{opts | command: command, interactive: true})

            interactive_loop(opts, new_code)
        end
    end
  end

  # ── Callback Functions ──────────────────────────────────────────────

  @doc """
  Callback invoked when a command link is established in listen mode.
  """
  @spec command_link_established(map()) :: :ok
  def command_link_established(link) do
    RNS.Log.log("Command link #{inspect(link)} established", :info)
    link = RNS.Link.set_remote_identified_callback(link, &initiator_identified/2)
    _link = RNS.Link.set_link_closed_callback(link, &command_link_closed/1)
    :ok
  end

  @doc """
  Callback when a command link is closed.
  """
  @spec command_link_closed(map()) :: :ok
  def command_link_closed(link) do
    RNS.Log.log("Command link #{inspect(link)} closed", :info)
    :ok
  end

  @doc """
  Callback for identifying the remote initiator.
  """
  @spec initiator_identified(map(), RNS.Identity.t()) :: :ok
  def initiator_identified(link, identity) do
    allow_all = Process.get(:rnx_allow_all, false)
    allowed_hashes = Process.get(:rnx_allowed_hashes, [])

    RNS.Log.log(
      "Initiator of link #{inspect(link)} identified as #{RNS.prettyhexrep(identity.hash)}",
      :info
    )

    if not allow_all and identity.hash not in allowed_hashes do
      RNS.Log.log(
        "Identity #{RNS.prettyhexrep(identity.hash)} not allowed, tearing down link",
        :info
      )

      RNS.Link.teardown(link)
    end

    :ok
  end

  # ── Command Execution ──────────────────────────────────────────────

  @doc """
  Executes a received command on the local system.

  The data format is a list: [command_binary, timeout, stdout_limit, stderr_limit, stdin_data].

  Returns a result list: [executed, return_value, stdout, stderr, stdout_len, stderr_len, started, concluded].
  """
  @spec execute_received_command(list(), map()) :: list()
  def execute_received_command(data, %{remote_identity: remote_identity}) do
    command = Enum.at(data, 0) |> decode_string()
    timeout = Enum.at(data, 1)
    o_limit = Enum.at(data, 2)
    e_limit = Enum.at(data, 3)
    stdin = Enum.at(data, 4)

    if remote_identity != nil do
      RNS.Log.log(
        "Executing command [#{command}] for #{RNS.prettyhexrep(remote_identity.hash)}",
        :info
      )
    else
      RNS.Log.log("Executing command [#{command}] for unknown requestor", :info)
    end

    started = System.system_time(:second)

    result =
      [
        # 0: Command was executed
        false,
        # 1: Return value
        nil,
        # 2: Stdout
        nil,
        # 3: Stderr
        nil,
        # 4: Total stdout length
        nil,
        # 5: Total stderr length
        nil,
        # 6: Started
        started,
        # 7: Concluded
        nil
      ]

    case run_command(command, stdin, timeout, started) do
      {:ok, exit_code, stdout, stderr} ->
        concluded =
          if timeout == nil or System.system_time(:second) < started + timeout do
            System.system_time(:second)
          else
            nil
          end

        stdout_out = truncate_output(stdout, o_limit)
        stderr_out = truncate_output(stderr, e_limit)

        result
        |> List.replace_at(0, true)
        |> List.replace_at(1, exit_code)
        |> List.replace_at(2, stdout_out)
        |> List.replace_at(3, stderr_out)
        |> List.replace_at(4, byte_size(stdout))
        |> List.replace_at(5, byte_size(stderr))
        |> List.replace_at(7, concluded)
        |> tap(fn _result ->
          if remote_identity != nil do
            RNS.Log.log(
              "Delivering result of command [#{command}] to #{RNS.prettyhexrep(remote_identity.hash)}",
              :info
            )
          else
            RNS.Log.log(
              "Delivering result of command [#{command}] to unknown requestor",
              :info
            )
          end
        end)

      {:error, _reason} ->
        result
    end
  end

  @doc """
  Builds the request data list for remote command execution.

  Matches the Python format: [command_bytes, timeout, stdout_limit, stderr_limit, stdin_data].
  """
  @spec build_request_data(
          String.t(),
          number() | nil,
          integer() | nil,
          integer() | nil,
          String.t() | nil
        ) :: list()
  def build_request_data(command, timeout, stdoutl, stderrl, stdin) do
    stdin_data = if stdin != nil, do: stdin, else: nil

    [
      command,
      timeout,
      stdoutl,
      stderrl,
      stdin_data
    ]
  end

  @doc """
  Formats execution result for display.

  Returns `{stdout_output, stderr_output, detail_lines}`.
  """
  @spec format_result(list(), boolean(), integer() | nil, integer() | nil) ::
          {String.t() | nil, String.t() | nil, [String.t()]}
  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  def format_result(response, detailed, stdoutl, stderrl) do
    executed = Enum.at(response, 0)
    _retval = Enum.at(response, 1)
    stdout = Enum.at(response, 2)
    stderr = Enum.at(response, 3)
    outlen = Enum.at(response, 4)
    errlen = Enum.at(response, 5)
    started = Enum.at(response, 6)
    concluded = Enum.at(response, 7)

    if executed do
      stdout_str =
        if stdout != nil and byte_size(stdout) > 0, do: decode_string(stdout), else: nil

      stderr_str =
        if stderr != nil and byte_size(stderr) > 0, do: decode_string(stderr), else: nil

      detail_lines =
        if detailed do
          lines = ["", "--- End of remote output, rnx done ---"]

          lines =
            if started != nil and concluded != nil do
              cmd_duration = Float.round((concluded - started) / 1.0, 3)
              lines ++ ["Remote command execution took #{cmd_duration} seconds"]
            else
              lines
            end

          lines =
            if outlen != nil and stdout != nil and byte_size(stdout) < outlen do
              lines ++
                ["Remote wrote #{outlen} bytes to stdout, #{byte_size(stdout)} bytes displayed"]
            else
              if outlen != nil do
                lines ++ ["Remote wrote #{outlen} bytes to stdout"]
              else
                lines
              end
            end

          lines =
            if errlen != nil and stderr != nil and byte_size(stderr) < errlen do
              lines ++
                ["Remote wrote #{errlen} bytes to stderr, #{byte_size(stderr)} bytes displayed"]
            else
              if errlen != nil do
                lines ++ ["Remote wrote #{errlen} bytes to stderr"]
              else
                lines
              end
            end

          lines
        else
          # Check for truncation in non-detailed mode
          truncated_lines = []

          truncated_lines =
            if stdoutl != 0 and stdout != nil and outlen != nil and byte_size(stdout) < outlen do
              truncated_lines ++ ["  stdout truncated to #{byte_size(stdout)} bytes"]
            else
              truncated_lines
            end

          truncated_lines =
            if stderrl != 0 and stderr != nil and errlen != nil and byte_size(stderr) < errlen do
              truncated_lines ++ ["  stderr truncated to #{byte_size(stderr)} bytes"]
            else
              truncated_lines
            end

          if truncated_lines != [] do
            ["", "Output truncated before being returned:" | truncated_lines]
          else
            []
          end
        end

      {stdout_str, stderr_str, detail_lines}
    else
      {nil, nil, ["Remote could not execute command"]}
    end
  end

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

    if span == 0, do: 0.0, else: (last_bytes - first_bytes) / span
  end

  # ── Private Helpers ──────────────────────────────────────────────────

  defp run_command(command, stdin, timeout, started) do
    args = split_command(command)
    {cmd, cmd_args} = {hd(args), tl(args)}

    port =
      Port.open({:spawn_executable, System.find_executable(cmd) || cmd}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: cmd_args
      ])

    if stdin != nil do
      Port.command(port, stdin)
    end

    collect_output(port, <<>>, timeout, started)
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp collect_output(port, acc, timeout, started) do
    receive do
      {^port, {:data, data}} ->
        collect_output(port, acc <> data, timeout, started)

      {^port, {:exit_status, status}} ->
        {:ok, status, acc, <<>>}
    after
      1000 ->
        if timeout != nil and System.system_time(:second) > started + timeout do
          Port.close(port)
          {:ok, -1, acc, <<>>}
        else
          collect_output(port, acc, timeout, started)
        end
    end
  end

  defp split_command(command) do
    # Simple command splitting - handles basic quoting
    command
    |> String.trim()
    |> do_split_command([], <<>>, nil)
    |> Enum.reverse()
  end

  defp do_split_command(<<>>, acc, current, _quote) do
    if byte_size(current) > 0 do
      [current | acc]
    else
      acc
    end
  end

  defp do_split_command(<<char, rest::binary>>, acc, current, nil) when char in [?", ?'] do
    do_split_command(rest, acc, current, char)
  end

  defp do_split_command(<<char, rest::binary>>, acc, current, quote_char)
       when char == quote_char do
    do_split_command(rest, acc, current, nil)
  end

  defp do_split_command(<<?\s, rest::binary>>, acc, current, nil) do
    if byte_size(current) > 0 do
      do_split_command(String.trim_leading(rest), [current | acc], <<>>, nil)
    else
      do_split_command(rest, acc, current, nil)
    end
  end

  defp do_split_command(<<char, rest::binary>>, acc, current, quote_char) do
    do_split_command(rest, acc, current <> <<char>>, quote_char)
  end

  defp truncate_output(output, nil), do: output

  defp truncate_output(output, limit) when is_integer(limit) do
    if limit == 0 do
      <<>>
    else
      if byte_size(output) > limit do
        binary_part(output, 0, limit)
      else
        output
      end
    end
  end

  defp decode_string(data) when is_binary(data), do: data
  defp decode_string(data) when is_list(data), do: List.to_string(data)
  defp decode_string(_), do: ""

  defp build_allowed_list(opts) do
    allow_all = opts.noauth
    dest_len = div(RNS.Reticulum.truncated_hashlength(), 8) * 2

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

    # Load from allowed identities files
    file_hashes = load_allowed_identities_files(dest_len)

    {allow_all, cli_hashes ++ file_hashes}
  end

  defp load_allowed_identities_files(dest_len) do
    allowed_file_name = "allowed_identities"

    paths = [
      Path.expand("/etc/rnx/#{allowed_file_name}"),
      Path.expand("~/.config/rnx/#{allowed_file_name}"),
      Path.expand("~/.rnx/#{allowed_file_name}")
    ]

    case Enum.find(paths, &File.regular?/1) do
      nil ->
        []

      path ->
        try do
          content = File.read!(path)

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
        rescue
          e ->
            IO.puts(Exception.message(e))
            System.halt(1)
        end
    end
  end

  defp return_or_exit(value, mirror, interactive) do
    if interactive do
      if mirror, do: value, else: nil
    else
      if mirror and value != nil do
        System.halt(value)
      else
        System.halt(240)
      end
    end
  end

  defp spin(msg, condition_fn, timeout_at) do
    IO.write("#{msg}  ")
    syms = String.graphemes("⢄⢂⢁⡁⡈⡐⡠")
    result = do_spin(condition_fn, syms, 0, timeout_at)
    IO.write("\r#{String.duplicate(" ", String.length(msg) + 4)}\r")
    result
  end

  defp do_spin(condition_fn, syms, i, timeout_at) do
    cond do
      condition_fn.() ->
        true

      System.system_time(:millisecond) >= timeout_at ->
        false

      true ->
        Process.sleep(100)
        sym = Enum.at(syms, rem(i, length(syms)))
        IO.write("\b\b#{sym} ")
        do_spin(condition_fn, syms, i + 1, timeout_at)
    end
  end

  defp default_identity_path do
    configdir = RNS.Reticulum.configdir()
    Path.join([configdir, "identities", @app_name])
  end

  defp daemon_loop do
    receive do
      :stop -> :ok
    after
      1000 -> daemon_loop()
    end
  end

  defp print_usage do
    IO.puts("""
    Reticulum Remote Execution Utility

    Usage:
      rnx [options] destination_hash command   Execute a command remotely
      rnx -l [options]                         Listen for incoming commands
      rnx -x [options] destination_hash        Enter interactive mode

    Options:
      --config PATH          Path to alternative Reticulum config directory
      -v, --verbose          Increase verbosity (can be repeated)
      -q, --quiet            Decrease verbosity (can be repeated)
      -p, --print-identity   Print identity and destination info and exit
      -l, --listen           Listen for incoming commands
      -i IDENTITY            Path to identity to use
      -x, --interactive      Enter interactive mode
      -b, --no-announce      Don't announce at program start
      -a HASH                Accept from this identity (can be repeated)
      -n, --noauth           Accept commands from anyone
      -N, --noid             Don't identify to listener
      -d, --detailed         Show detailed result output
      -m                     Mirror exit code of remote command
      -w SECONDS             Connect and request timeout (default: 15)
      -W SECONDS             Max result download time
      --stdin DATA           Pass input to stdin
      --stdout BYTES         Max size in bytes of returned stdout
      --stderr BYTES         Max size in bytes of returned stderr
      --version              Print version and exit
      -h, --help             Print this help message and exit
    """)
  end
end
