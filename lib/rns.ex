defmodule RNS do
  @moduledoc """
  Elixir port of the Reticulum Network Stack.

  RNS provides encrypted, self-configuring mesh networking with zero infrastructure
  requirements. This module serves as the main entry point and public API, re-exporting
  all core modules and providing top-level utility functions matching the Python RNS API.

  ## Core Modules

    * `RNS.Reticulum` — Main system coordinator, configuration, startup
    * `RNS.Identity` — Cryptographic identity management (X25519 + Ed25519)
    * `RNS.Destination` — Named endpoints for communication
    * `RNS.Transport` — Routing tables, announce handling, packet forwarding
    * `RNS.Packet` — Wire-format packet encoding/decoding
    * `RNS.PacketReceipt` — Delivery tracking for sent packets
    * `RNS.Link` — Encrypted bidirectional communication channels
    * `RNS.Channel` — Ordered message delivery over Links
    * `RNS.Buffer` — Stream-oriented I/O over Channels
    * `RNS.Resource` — Large data transfer over Links
    * `RNS.Resolver` — Name resolution (stub for future expansion)
    * `RNS.Discovery` — Interface announce and peer discovery

  ## Cryptography

    * `RNS.Cryptography.Hashes` — SHA-256/512, truncated hashes
    * `RNS.Cryptography.HKDF` — HMAC-based Key Derivation Function
    * `RNS.Cryptography.HMAC` — HMAC-SHA256/512
    * `RNS.Cryptography.AES` — AES-256-CBC encryption
    * `RNS.Cryptography.X25519` — Elliptic-curve Diffie-Hellman
    * `RNS.Cryptography.Ed25519` — Digital signatures
    * `RNS.Cryptography.Token` — Fernet-like authenticated encryption

  ## Quick Start

      # Start the application (happens automatically via mix)
      # Create an identity
      identity = RNS.Identity.new()

      # Create a destination
      destination = RNS.Destination.new(identity, :out, :single, "myapp", "service")

      # Get the destination hash
      hash = RNS.Destination.hash(destination)
      RNS.log("Destination hash: \#{RNS.hexrep(hash)}")

  ## Logging

  RNS wraps Elixir's Logger with RNS-specific metadata:

      RNS.log("Something happened", :notice)   # default level
      RNS.log("Debug info", :debug)
  """

  @version RNS.Version.version()

  # ── Log level atoms ──────────────────────────────────────────────
  # Use atom-based levels directly: :critical, :error, :warning,
  # :notice, :info, :verbose, :debug, :extreme

  # ── Version and system info ──────────────────────────────────────

  @doc """
  Returns the current RNS version string.

  ## Examples

      iex> is_binary(RNS.version())
      true

  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Returns the host operating system identifier.

  ## Examples

      iex> os = RNS.host_os()
      iex> os in ["darwin", "linux", "windows", "unknown"]
      true

  """
  @spec host_os() :: String.t()
  def host_os, do: RNS.Vendor.PlatformUtils.get_platform()

  # ── Logging ──────────────────────────────────────────────────────

  @doc """
  Logs a message at the given RNS log level.

  Accepts both atom levels (`:notice`, `:debug`) and legacy integer levels (3, 6).

  ## Examples

      RNS.log("Hello from RNS")                        # :notice (default)
      RNS.log("Debug details", :debug)

  """
  @spec log(String.t(), RNS.Log.rns_level() | integer()) :: :ok
  def log(msg, level \\ :notice), do: RNS.Log.log(msg, level)

  @doc """
  Formats an epoch timestamp as a human-readable string.

  Uses the format `"%Y-%m-%d %H:%M:%S"` matching Python's `RNS.timestamp_str()`.

  ## Examples

      iex> is_binary(RNS.timestamp_str(1_700_000_000))
      true

  """
  @spec timestamp_str(number()) :: String.t()
  def timestamp_str(time_s) do
    time_s
    |> trunc()
    |> DateTime.from_unix!()
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%Y-%m-%d %H:%M:%S")
  end

  @doc """
  Returns a precise timestamp string with millisecond resolution.

  Uses the format `"%H:%M:%S.fff"` matching Python's `RNS.precise_timestamp_str()`.

  ## Examples

      iex> str = RNS.precise_timestamp_str(0)
      iex> String.match?(str, ~r/^\\d{2}:\\d{2}:\\d{2}\\.\\d{3}$/)
      true

  """
  @spec precise_timestamp_str(number()) :: String.t()
  def precise_timestamp_str(_time_s) do
    now = NaiveDateTime.utc_now()
    ms = div(now.microsecond |> elem(0), 1000)

    Calendar.strftime(now, "%H:%M:%S") <>
      "." <> String.pad_leading(Integer.to_string(ms), 3, "0")
  end

  @doc """
  Logs an exception with its message and type at LOG_ERROR level.

  Matches Python's `RNS.trace_exception(e)`.

  ## Examples

      try do
        raise "something broke"
      rescue
        e -> RNS.trace_exception(e)
      end

  """
  @spec trace_exception(Exception.t(), list()) :: :ok
  def trace_exception(exception, stacktrace \\ []) do
    type = exception.__struct__ |> Module.split() |> Enum.join(".")
    message = Exception.message(exception)

    RNS.Log.log("An unhandled #{type} exception occurred: #{message}", :error)

    if stacktrace != [] do
      formatted = Exception.format(:error, exception, stacktrace)
      RNS.Log.log(formatted, :error)
    end

    :ok
  end

  # ── Randomness ───────────────────────────────────────────────────

  @doc """
  Returns a random float in [0.0, 1.0).

  Matches Python's `RNS.rand()` which uses a seeded Random instance.

  ## Examples

      iex> r = RNS.rand()
      iex> r >= 0.0 and r < 1.0
      true

  """
  @spec rand() :: float()
  def rand do
    :rand.uniform()
  end

  # ── Data formatting ──────────────────────────────────────────────

  @doc """
  Returns a hex representation of binary data.

  ## Options

    * `delimit` - if true (default), separate bytes with `:`

  ## Examples

      iex> RNS.hexrep(<<0xDE, 0xAD, 0xBE, 0xEF>>)
      "de:ad:be:ef"

      iex> RNS.hexrep(<<0xDE, 0xAD>>, false)
      "dead"

  """
  @spec hexrep(binary(), boolean()) :: String.t()
  def hexrep(data, delimit \\ true)

  def hexrep(data, true) when is_binary(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.map_join(":", &Base.encode16(<<&1>>, case: :lower))
  end

  def hexrep(data, false) when is_binary(data) do
    Base.encode16(data, case: :lower)
  end

  @doc """
  Returns a pretty hex representation wrapped in angle brackets.

  ## Examples

      iex> RNS.prettyhexrep(<<0xDE, 0xAD>>)
      "<dead>"

  """
  @spec prettyhexrep(binary()) :: String.t()
  def prettyhexrep(data) when is_binary(data) do
    "<" <> Base.encode16(data, case: :lower) <> ">"
  end

  @doc """
  Formats a byte count as a human-readable size string.

  ## Options

    * `suffix` - unit suffix, `"B"` for bytes (default), `"b"` for bits

  ## Examples

      iex> RNS.prettysize(1000)
      "1.00 KB"

      iex> RNS.prettysize(500)
      "500 B"

  """
  @spec prettysize(number(), String.t()) :: String.t()
  def prettysize(num, suffix \\ "B") do
    num = if suffix == "b", do: num * 8.0, else: num * 1.0
    units = ["", "K", "M", "G", "T", "P", "E", "Z"]
    last_unit = "Y"
    format_units(num, units, last_unit, suffix, &size_formatter/3)
  end

  defp size_formatter(num, "", suffix), do: format_float(num, 0) <> " " <> suffix
  defp size_formatter(num, unit, suffix), do: format_float(num, 2) <> " " <> unit <> suffix

  @doc """
  Formats a speed value as a human-readable string.

  ## Examples

      iex> RNS.prettyspeed(8000)
      "1.00 KBps"

  """
  @spec prettyspeed(number(), String.t()) :: String.t()
  def prettyspeed(num, suffix \\ "b") do
    prettysize(num / 8, suffix) <> "ps"
  end

  @doc """
  Formats a frequency in Hz as a human-readable string.

  The input is in Hz. Internally multiplied by 1e6 to start from µHz
  and scaled up through SI prefixes.

  ## Examples

      iex> RNS.prettyfrequency(868_000_000)
      "868.00 MHz"

  """
  @spec prettyfrequency(number(), String.t()) :: String.t()
  def prettyfrequency(hz, suffix \\ "Hz") do
    num = hz * 1.0e6
    units = ["µ", "m", "", "K", "M", "G", "T", "P", "E", "Z"]
    last_unit = "Y"
    format_units(num, units, last_unit, suffix, &default_formatter/3)
  end

  @doc """
  Formats a distance in meters as a human-readable string.

  ## Examples

      iex> RNS.prettydistance(1500.0)
      "1.50 Km"

  """
  @spec prettydistance(number(), String.t()) :: String.t()
  def prettydistance(m, suffix \\ "m") do
    num = m * 1.0e6

    units_with_divisors = [
      {"µ", 1000.0},
      {"m", 10.0},
      {"c", 100.0},
      {"", 1000.0}
    ]

    format_distance(num, units_with_divisors, "K", suffix)
  end

  # Generic unit formatter — iterates through SI prefix list dividing by 1000
  defp format_units(num, [unit | rest], last_unit, suffix, formatter) do
    if abs(num) < 1000.0 do
      formatter.(num, unit, suffix)
    else
      case rest do
        [] ->
          formatter.(num / 1000.0, last_unit, suffix)

        _ ->
          format_units(num / 1000.0, rest, last_unit, suffix, formatter)
      end
    end
  end

  defp default_formatter(num, unit, suffix) do
    format_float(num, 2) <> " " <> unit <> suffix
  end

  # Distance formatter — each unit has its own divisor
  defp format_distance(num, [{unit, divisor} | rest], last_unit, suffix) do
    if abs(num) < divisor do
      format_float(num, 2) <> " " <> unit <> suffix
    else
      case rest do
        [] ->
          format_float(num / divisor, 2) <> " " <> last_unit <> suffix

        _ ->
          format_distance(num / divisor, rest, last_unit, suffix)
      end
    end
  end

  # Float formatting helper
  defp format_float(num, 0) do
    num |> Float.round(0) |> trunc() |> Integer.to_string()
  end

  defp format_float(num, decimals) do
    :erlang.float_to_binary(num * 1.0, [{:decimals, decimals}])
  end

  @doc """
  Formats a duration in seconds as a human-readable string.

  ## Options

    * `verbose` - if true, use full words ("1 day" vs "1d"). Default: false
    * `compact` - if true, show at most 2 components and truncate seconds. Default: false

  ## Examples

      iex> RNS.prettytime(3661.5)
      "1h, 1m and 1.5s"

      iex> RNS.prettytime(90061, verbose: true)
      "1 day, 1 hour, 1 minute and 1 second"

      iex> RNS.prettytime(0)
      "0s"

  """
  @spec prettytime(number(), keyword()) :: String.t()
  def prettytime(time_s, opts \\ []) do
    verbose = Keyword.get(opts, :verbose, false)
    compact = Keyword.get(opts, :compact, false)

    {neg, time_s} =
      if time_s < 0, do: {true, abs(time_s)}, else: {false, time_s * 1.0}

    days = trunc(time_s / (24 * 3600))
    time_s = time_s - days * 24 * 3600
    hours = trunc(time_s / 3600)
    time_s = time_s - hours * 3600
    minutes = trunc(time_s / 60)
    time_s = time_s - minutes * 60
    seconds = if compact, do: trunc(time_s), else: round_number(time_s, 2)

    components =
      []
      |> maybe_add_time_component(days, "day", "d", verbose, compact, 0)
      |> maybe_add_time_component(hours, "hour", "h", verbose, compact, -1)
      |> maybe_add_time_component(minutes, "minute", "m", verbose, compact, -1)
      |> maybe_add_time_component(seconds, "second", "s", verbose, compact, -1)
      |> Enum.reverse()

    tstr = join_components(components)

    cond do
      tstr == "" -> "0s"
      neg -> "-#{tstr}"
      true -> tstr
    end
  end

  @doc """
  Formats a short duration in seconds as a human-readable string with
  sub-second precision (milliseconds, microseconds).

  ## Examples

      iex> RNS.prettyshorttime(0.0015)
      "1ms and 500µs"

      iex> RNS.prettyshorttime(1.5)
      "1s and 500ms"

  """
  @spec prettyshorttime(number(), keyword()) :: String.t()
  def prettyshorttime(time_s, opts \\ []) do
    verbose = Keyword.get(opts, :verbose, false)
    compact = Keyword.get(opts, :compact, false)

    {neg, time_us} =
      if time_s < 0, do: {true, abs(time_s) * 1.0e6}, else: {false, time_s * 1.0e6}

    seconds = trunc(time_us / 1.0e6)
    time_us = time_us - seconds * 1.0e6
    milliseconds = trunc(time_us / 1.0e3)
    time_us = time_us - milliseconds * 1.0e3
    microseconds = if compact, do: trunc(time_us), else: round_number(time_us, 2)

    components =
      []
      |> maybe_add_time_component(seconds, "second", "s", verbose, compact, 0)
      |> maybe_add_time_component(milliseconds, "millisecond", "ms", verbose, compact, -1)
      |> maybe_add_time_component(microseconds, "microsecond", "µs", verbose, compact, -1)
      |> Enum.reverse()

    tstr = join_components(components)

    cond do
      tstr == "" -> "0us"
      neg -> "-#{tstr}"
      true -> tstr
    end
  end

  defp maybe_add_time_component(acc, value, long_name, short_name, verbose, compact, displayed) do
    displayed = if displayed == -1, do: length(acc), else: displayed

    if value > 0 and (not compact or displayed < 2) do
      suffix = if verbose, do: pluralize(value, long_name), else: short_name

      label =
        if verbose, do: "#{format_num(value)} #{suffix}", else: "#{format_num(value)}#{suffix}"

      [label | acc]
    else
      acc
    end
  end

  defp pluralize(1, name), do: name
  defp pluralize(1.0, name), do: name
  defp pluralize(_, name), do: name <> "s"

  defp format_num(n) when is_integer(n), do: Integer.to_string(n)

  defp format_num(n) when is_float(n) do
    if n == Float.floor(n) do
      n |> trunc() |> Integer.to_string()
    else
      :erlang.float_to_binary(n, [{:decimals, 2}, :compact])
    end
  end

  defp round_number(n, decimals) do
    Float.round(n * 1.0, decimals)
  end

  defp join_components([]), do: ""
  defp join_components([single]), do: single

  defp join_components(components) do
    {last, rest} = List.pop_at(components, -1)
    Enum.join(rest, ", ") <> " and " <> last
  end

  # ── Physical layer info ──────────────────────────────────────────

  @doc """
  Prints physical layer parameters to stdout.

  Matches Python's `RNS.phyparams()`. Displays MTU, MDU values,
  link curve, and key sizes.
  """
  @spec phyparams() :: :ok
  def phyparams do
    IO.puts("Required Physical Layer MTU : #{RNS.Reticulum.mtu()} bytes")
    IO.puts("Plaintext Packet MDU        : #{RNS.Packet.plain_mdu()} bytes")
    IO.puts("Encrypted Packet MDU        : #{RNS.Packet.encrypted_mdu()} bytes")
    IO.puts("Link Curve                  : #{RNS.Identity.curve()}")
    IO.puts("Link Packet MDU             : #{RNS.Link.mdu()} bytes")
    IO.puts("Link Public Key Size        : #{RNS.Link.ecpubsize() * 8} bits")
    IO.puts("Link Private Key Size       : #{RNS.Link.keysize() * 8} bits")
    :ok
  end

  # ── System control ───────────────────────────────────────────────

  @doc """
  Terminates the BEAM VM immediately with exit code 255.
  Equivalent to Python's `RNS.panic()` / `os._exit(255)`.
  """
  @spec panic() :: no_return()
  def panic do
    System.halt(255)
  end

  @doc """
  Gracefully exits the RNS system.

  Stops the `:rns_ex` application (which triggers `terminate/2` callbacks
  in Reticulum, Transport, etc. to persist state), then halts the VM
  with the given exit code.

  Matches Python's `RNS.exit(code)`.
  """
  @dialyzer {:nowarn_function, [{:rns_exit, 0}, {:rns_exit, 1}]}
  @spec rns_exit(non_neg_integer()) :: no_return()
  def rns_exit(code \\ 0) do
    try do
      Application.stop(:rns_ex)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    System.halt(code)
  end
end
