defmodule RNS.Log do
  @moduledoc """
  Thin wrapper over Elixir's Logger with RNS-specific metadata.

  Maps RNS log levels to Logger levels:
    - critical -> :emergency
    - error    -> :error
    - warning  -> :warning
    - notice   -> :notice
    - info     -> :info
    - verbose/debug/extreme -> :debug

  The RNS-specific level name is included as Logger metadata under `:rns_level`.
  """

  require Logger

  @type rns_level ::
          :critical | :error | :warning | :notice | :info | :verbose | :debug | :extreme

  # RNS level -> Logger level mapping
  @level_map %{
    critical: :emergency,
    error: :error,
    warning: :warning,
    notice: :notice,
    info: :info,
    verbose: :debug,
    debug: :debug,
    extreme: :debug
  }

  # Legacy integer -> atom mapping for backward compatibility during migration
  @int_to_atom %{
    -1 => :none,
    0 => :critical,
    1 => :error,
    2 => :warning,
    3 => :notice,
    4 => :info,
    5 => :verbose,
    6 => :debug,
    7 => :extreme
  }

  @doc """
  Log a message at the given RNS level.

  Accepts both atom levels (`:notice`, `:debug`) and legacy integer levels (3, 6).
  """
  @spec log(String.t(), rns_level() | integer()) :: :ok
  def log(msg, level \\ :notice)

  def log(msg, level) when is_integer(level) do
    case Map.get(@int_to_atom, level) do
      :none -> :ok
      nil -> :ok
      atom_level -> log(msg, atom_level)
    end
  end

  def log(msg, level) when is_atom(level) do
    logger_level = Map.get(@level_map, level, :debug)
    # credo:disable-for-next-line Credo.Check.Warning.MissedMetadataKeyInLoggerConfig
    Logger.log(logger_level, msg, rns_level: level)
    :ok
  end

  @doc """
  Log a trace-level message for malformed packets, failed crypto operations,
  and other noisy but expected events. Only emits when
  `config :rns_ex, verbose_logging: true` is set.

  Use this for messages that are routine in normal operation (adversarial
  packets, invalid signatures, match errors on corrupt data) but useful
  when diagnosing specific issues.
  """
  @spec trace(String.t()) :: :ok
  if Application.compile_env(:rns_ex, :verbose_logging, false) do
    def trace(msg) do
      Logger.debug(msg, rns_level: :extreme)
      :ok
    end
  else
    def trace(_msg), do: :ok
  end
end
