defmodule RNS.Utilities.RNIR do
  @moduledoc """
  Reticulum Distributed Identity Resolver.

  Initializes a Reticulum instance for identity resolution and exits.
  This is the Elixir equivalent of the Python `rnir` utility.

  Can be called programmatically via `RNS.Utilities.RNIR.main/1`.

  ## Usage

      rnir [options]

  ## Options

    * `--config PATH` - Path to alternative Reticulum config directory
    * `-v`, `--verbose` - Increase verbosity (can be repeated)
    * `-q`, `--quiet` - Decrease verbosity (can be repeated)
    * `--version` - Print version and exit
  """

  @doc """
  Entry point for the rnir utility.
  """
  @spec main([String.t()]) :: :ok | no_return()
  def main(args) do
    case parse_args(args) do
      {:ok, opts} ->
        if opts.version do
          IO.puts("rnir #{RNS.Version.version()}")
        else
          program_setup(opts)
        end

      {:error, message} ->
        IO.puts(:stderr, "error: #{message}")
        IO.puts(:stderr, "")
        print_usage()
        System.halt(1)
    end
  end

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
          version: :boolean,
          help: :boolean
        ],
        aliases: [
          v: :verbose,
          q: :quiet,
          h: :help
        ]
      )

    cond do
      invalid != [] ->
        {key, _} = hd(invalid)
        {:error, "unknown option: #{key}"}

      rest != [] ->
        {:error, "unexpected argument: #{hd(rest)}"}

      Keyword.get(parsed, :help, false) ->
        print_usage()
        System.halt(0)

      true ->
        {:ok,
         %{
           configdir: Keyword.get(parsed, :config),
           verbosity: Keyword.get(parsed, :verbose, 0),
           quietness: Keyword.get(parsed, :quiet, 0),
           version: Keyword.get(parsed, :version, false)
         }}
    end
  end

  @doc """
  Initializes Reticulum for identity resolution and exits.
  """
  @spec program_setup(map()) :: :ok | no_return()
  def program_setup(opts) do
    target_verbosity = opts.verbosity - opts.quietness

    RNS.Utilities.CLI.start_for_cli(
      logdest: :stdout,
      configdir: opts.configdir,
      verbosity: target_verbosity
    )

    :ok
  end

  # ── Private Helpers ────────────────────────────────────────────────────

  defp print_usage do
    IO.puts("""
    Reticulum Distributed Identity Resolver

    Usage: rnir [options]

    Options:
      --config PATH      Path to alternative Reticulum config directory
      -v, --verbose      Increase verbosity (can be repeated)
      -q, --quiet        Decrease verbosity (can be repeated)
      --version          Print version and exit
      -h, --help         Print this help message and exit
    """)
  end
end
