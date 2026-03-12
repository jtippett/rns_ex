defmodule RNS do
  @moduledoc """
  Elixir port of the Reticulum Network Stack.

  RNS provides encrypted, self-configuring mesh networking with zero infrastructure
  requirements. This module serves as the main entry point and public API.
  """

  @version RNS.Version.version()

  # Re-export log level constants
  defdelegate log_none(), to: RNS.Log
  defdelegate log_critical(), to: RNS.Log
  defdelegate log_error(), to: RNS.Log
  defdelegate log_warning(), to: RNS.Log
  defdelegate log_notice(), to: RNS.Log
  defdelegate log_info(), to: RNS.Log
  defdelegate log_verbose(), to: RNS.Log
  defdelegate log_debug(), to: RNS.Log
  defdelegate log_extreme(), to: RNS.Log

  @doc """
  Returns the current RNS version string.
  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Returns the host operating system identifier.
  """
  @spec host_os() :: String.t()
  def host_os, do: RNS.Vendor.PlatformUtils.get_platform()

  @doc """
  Logs a message at the given RNS log level.
  Delegates to `RNS.Log.log/3`.
  """
  @spec log(String.t(), integer()) :: :ok
  def log(msg, level \\ 3), do: RNS.Log.log(msg, level)

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
          # Exhausted all units, use last_unit
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
          # Exhausted all units, divide and use last_unit
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
      label = if verbose, do: "#{format_num(value)} #{suffix}", else: "#{format_num(value)}#{suffix}"
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

  @doc """
  Terminates the BEAM VM immediately with exit code 255.
  Equivalent to Python's `os._exit(255)`.
  """
  @spec panic() :: no_return()
  def panic do
    System.halt(255)
  end
end
