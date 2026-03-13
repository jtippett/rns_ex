defmodule RNS.Utilities.CLI do
  @moduledoc """
  Shared CLI startup logic for all RNS utilities.

  Replaces the per-utility `ensure_application_started/0` + `start_reticulum/1`
  pattern with a unified startup path that uses the OTP supervision tree.

  ## Usage

      CLI.start_for_cli(logdest: :stdout, configdir: opts.configdir, verbosity: 2)

  This stores the Reticulum options in the Application environment and then
  calls `Application.ensure_all_started(:rns_ex)`. The supervision tree reads
  these options when starting `RNS.Reticulum`.
  """

  @doc """
  Starts the RNS application with the given Reticulum options.

  Stores the options in Application env (filtering nil values) and calls
  `Application.ensure_all_started(:rns_ex)`. Does not swallow errors.

  Returns `:ok` on success. On failure, prints the error and calls `System.halt(1)`.
  """
  @spec start_for_cli(keyword()) :: :ok | no_return()
  def start_for_cli(opts \\ []) do
    reticulum_opts = build_reticulum_opts(opts)
    Application.put_env(:rns_ex, :reticulum_opts, reticulum_opts)
    ensure_started!()
  end

  @doc """
  Calls `Application.ensure_all_started(:rns_ex)` without swallowing errors.

  Returns `:ok` on success. On failure, prints the error to stderr and halts.
  """
  @spec ensure_started!() :: :ok | no_return()
  def ensure_started! do
    case Application.ensure_all_started(:rns_ex) do
      {:ok, _apps} ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Fatal: could not start RNS application: #{inspect(reason)}")
        System.halt(1)
    end
  end

  @doc """
  Builds a Reticulum options keyword list, filtering out nil values.
  """
  @spec build_reticulum_opts(keyword()) :: keyword()
  def build_reticulum_opts(opts) do
    Enum.reject(opts, fn {_k, v} -> is_nil(v) end)
  end

  @doc """
  Adds a key-value pair to a keyword list, skipping nil values.
  """
  @spec maybe_add_opt(keyword(), atom(), term()) :: keyword()
  def maybe_add_opt(opts, _key, nil), do: opts
  def maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
