defmodule RNS.Log do
  @moduledoc """
  Logging system for RNS, wrapping Elixir's Logger with RNS-specific log levels.

  RNS defines 8 log levels (0-7) plus a special LOG_NONE (-1) to suppress all output.
  These map to Elixir Logger levels as follows:

    - LOG_CRITICAL (0) -> :emergency
    - LOG_ERROR (1)    -> :error
    - LOG_WARNING (2)  -> :warning
    - LOG_NOTICE (3)   -> :notice
    - LOG_INFO (4)     -> :info
    - LOG_VERBOSE (5)  -> :debug
    - LOG_DEBUG (6)    -> :debug
    - LOG_EXTREME (7)  -> :debug
  """

  require Logger

  @log_none -1
  @log_critical 0
  @log_error 1
  @log_warning 2
  @log_notice 3
  @log_info 4
  @log_verbose 5
  @log_debug 6
  @log_extreme 7

  @log_stdout 0x91
  @log_file 0x92
  @log_callback 0x93

  @log_maxsize 5 * 1024 * 1024

  # Module attributes for external use
  def log_none, do: @log_none
  def log_critical, do: @log_critical
  def log_error, do: @log_error
  def log_warning, do: @log_warning
  def log_notice, do: @log_notice
  def log_info, do: @log_info
  def log_verbose, do: @log_verbose
  def log_debug, do: @log_debug
  def log_extreme, do: @log_extreme

  def log_stdout, do: @log_stdout
  def log_file, do: @log_file
  def log_callback, do: @log_callback

  def log_maxsize, do: @log_maxsize

  @doc """
  Returns the human-readable name for a log level.
  """
  @spec loglevelname(integer()) :: String.t()
  def loglevelname(@log_critical), do: "[Critical]"
  def loglevelname(@log_error), do: "[Error]   "
  def loglevelname(@log_warning), do: "[Warning] "
  def loglevelname(@log_notice), do: "[Notice]  "
  def loglevelname(@log_info), do: "[Info]    "
  def loglevelname(@log_verbose), do: "[Verbose] "
  def loglevelname(@log_debug), do: "[Debug]   "
  def loglevelname(@log_extreme), do: "[Extra]   "
  def loglevelname(_), do: "Unknown"

  @doc """
  Logs a message at the given RNS log level.

  The message is forwarded to Elixir's Logger at the appropriate level.
  The `loglevel` parameter controls the maximum verbosity — messages with
  a level higher than `loglevel` are suppressed.

  ## Options

    * `:loglevel` - current log verbosity threshold (default: LOG_NOTICE)
    * `:override_destination` - if true, always log to stdout (default: false)

  """
  @spec log(String.t(), integer(), keyword()) :: :ok
  def log(msg, level \\ @log_notice, opts \\ []) do
    loglevel = Keyword.get(opts, :loglevel, @log_notice)

    if loglevel != @log_none and loglevel >= level do
      logger_level = to_logger_level(level)
      levelname = loglevelname(level)
      Logger.log(logger_level, "#{levelname} #{msg}")
    end

    :ok
  end

  @doc """
  Maps an RNS log level to an Elixir Logger level.
  """
  @spec to_logger_level(integer()) :: Logger.level()
  def to_logger_level(@log_critical), do: :emergency
  def to_logger_level(@log_error), do: :error
  def to_logger_level(@log_warning), do: :warning
  def to_logger_level(@log_notice), do: :notice
  def to_logger_level(@log_info), do: :info
  def to_logger_level(@log_verbose), do: :debug
  def to_logger_level(@log_debug), do: :debug
  def to_logger_level(@log_extreme), do: :debug
  def to_logger_level(_), do: :debug
end
