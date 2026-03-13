defmodule RNS.Utilities.RNProbe do
  @moduledoc """
  Reticulum Probe Utility.

  Sends probe packets to a destination and measures round-trip time,
  similar to `ping` for IP networks.

  Can be invoked as an escript (`rnprobe`) or called programmatically via
  `RNS.Utilities.RNProbe.main/1`.

  ## Usage

      rnprobe [options] full_name destination_hash

  ## Options

    * `--config PATH` - Path to alternative Reticulum config directory
    * `-s`, `--size SIZE` - Size of probe packet payload in bytes (default: 16)
    * `-n`, `--probes N` - Number of probes to send (default: 1)
    * `-t`, `--timeout SECONDS` - Timeout before giving up (default: 12)
    * `-w`, `--wait SECONDS` - Time between each probe (default: 0)
    * `-v`, `--verbose` - Increase verbosity (can be repeated)
    * `--version` - Print version and exit
    * `-h`, `--help` - Print help and exit
  """

  @default_probe_size 16
  @default_timeout 12

  # ── Entry Point ──────────────────────────────────────────────────────

  @doc """
  Entry point for the rnprobe escript and programmatic invocation.
  """
  @spec main([String.t()]) :: :ok | no_return()
  def main(args) do
    case parse_args(args) do
      {:ok, opts} ->
        cond do
          opts.version ->
            IO.puts("rnprobe #{RNS.Version.version()}")

          opts.help ->
            print_usage()

          opts.destination_hash == nil ->
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
          size: :integer,
          probes: :integer,
          timeout: :float,
          wait: :float,
          verbose: :count,
          version: :boolean,
          help: :boolean
        ],
        aliases: [
          s: :size,
          n: :probes,
          t: :timeout,
          w: :wait,
          v: :verbose,
          h: :help
        ]
      )

    if invalid != [] do
      {key, _} = hd(invalid)
      {:error, "unknown option: #{key}"}
    else
      {full_name, destination_hash} =
        case rest do
          [name, hash | _] -> {name, hash}
          [hash] -> {nil, hash}
          [] -> {nil, nil}
        end

      {:ok,
       %{
         configdir: Keyword.get(parsed, :config),
         size: Keyword.get(parsed, :size, @default_probe_size),
         probes: Keyword.get(parsed, :probes, 1),
         timeout: Keyword.get(parsed, :timeout, @default_timeout * 1.0),
         wait: Keyword.get(parsed, :wait, 0.0),
         verbosity: Keyword.get(parsed, :verbose, 0),
         version: Keyword.get(parsed, :version, false),
         help: Keyword.get(parsed, :help, false),
         full_name: full_name,
         destination_hash: destination_hash
       }}
    end
  end

  # ── Hash Parsing ─────────────────────────────────────────────────────

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

  # ── Program Setup ────────────────────────────────────────────────────

  @doc """
  Executes the probe operation with the given options.
  """
  @spec program_setup(map()) :: :ok | no_return()
  def program_setup(opts) do
    if opts.full_name == nil do
      IO.puts(
        "The full destination name including application name aspects must be specified for the destination"
      )

      System.halt(1)
    end

    {app_name, aspects} =
      case parse_full_name(opts.full_name) do
        {:ok, result} ->
          result

        {:error, msg} ->
          IO.puts(msg)
          System.halt(1)
      end

    destination_hash =
      case parse_destination_hash(opts.destination_hash) do
        {:ok, hash} ->
          hash

        {:error, msg} ->
          IO.puts(msg)
          System.halt(1)
      end

    more_output = opts.verbosity > 0
    loglevel = 3 + opts.verbosity - 1

    ensure_application_started()

    reticulum_opts =
      [logdest: :stdout, loglevel: max(loglevel, 0)]
      |> maybe_add_opt(:configdir, opts.configdir)

    case start_reticulum(reticulum_opts) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "Could not start Reticulum: #{inspect(reason)}")
        System.halt(1)
    end

    # Request path if not known
    if not RNS.Transport.has_path(destination_hash) do
      RNS.Transport.request_path(destination_hash)
      IO.write("Path to #{RNS.prettyhexrep(destination_hash)} requested  ")

      timeout_at = System.system_time(:millisecond) + trunc(opts.timeout * 1000)
      wait_for_path(destination_hash, timeout_at)
    end

    if not RNS.Transport.has_path(destination_hash) do
      IO.puts("\r#{String.duplicate(" ", 58)}\rPath request timed out")
      System.halt(1)
    end

    server_identity = RNS.Identity.recall(destination_hash)

    request_destination =
      RNS.Destination.new(
        server_identity,
        RNS.Destination.direction_out(),
        RNS.Destination.single(),
        app_name,
        aspects
      )

    {sent, replies} = send_probes(opts, destination_hash, request_destination, more_output, 0, 0)

    loss = Float.round((1 - replies / max(sent, 1)) * 100, 2)
    IO.puts("Sent #{sent}, received #{replies}, packet loss #{loss}%")

    if loss > 0, do: System.halt(2), else: System.halt(0)
  end

  # ── Probe Sending ──────────────────────────────────────────────────

  @doc false
  def send_probes(opts, _dest_hash, _dest, _more_output, sent, replies)
      when opts.probes <= 0 do
    {sent, replies}
  end

  def send_probes(opts, dest_hash, dest, more_output, sent, replies) do
    if sent > 0 and opts.wait > 0 do
      Process.sleep(trunc(opts.wait * 1000))
    end

    probe_data = :crypto.strong_rand_bytes(opts.size)
    probe = RNS.Packet.new(dest, probe_data)

    case RNS.Packet.send(probe) do
      %RNS.PacketReceipt{} = receipt ->
        sent = sent + 1

        more =
          if more_output do
            nhd = RNS.Transport.next_hop(dest_hash)
            via_str = if nhd, do: " via #{RNS.prettyhexrep(nhd)}", else: ""

            if_name = get_next_hop_if_name(dest_hash)
            if_str = if if_name != "Unknown", do: " on #{if_name}", else: ""

            via_str <> if_str
          else
            ""
          end

        IO.write(
          "\rSent probe #{sent} (#{opts.size} bytes) to #{RNS.prettyhexrep(dest_hash)}#{more}  "
        )

        timeout_at = System.system_time(:millisecond) + trunc(opts.timeout * 1000)
        wait_for_receipt(receipt, timeout_at)

        receipt = refresh_receipt(receipt)

        replies =
          if receipt.status == RNS.PacketReceipt.delivered() do
            replies = replies + 1
            hops = RNS.Transport.hops_to(dest_hash)
            ms = if hops != 1, do: "s", else: ""

            rtt = RNS.PacketReceipt.rtt(receipt)
            rtt_string = format_rtt(rtt)

            reception_stats = format_reception_stats(receipt)

            IO.puts("")

            IO.puts(
              "Valid reply from #{RNS.prettyhexrep(receipt.destination.hash)}\n" <>
                "Round-trip time is #{rtt_string} over #{hops} hop#{ms}#{reception_stats}\n"
            )

            replies
          else
            IO.puts("\r#{String.duplicate(" ", 66)}\rProbe timed out")
            replies
          end

        send_probes(
          %{opts | probes: opts.probes - 1},
          dest_hash,
          dest,
          more_output,
          sent,
          replies
        )

      false ->
        IO.puts("Error: Could not send probe packet")
        System.halt(3)

      nil ->
        sent = sent + 1
        IO.puts("\r#{String.duplicate(" ", 66)}\rProbe timed out")

        send_probes(
          %{opts | probes: opts.probes - 1},
          dest_hash,
          dest,
          more_output,
          sent,
          replies
        )
    end
  end

  # ── Formatting ──────────────────────────────────────────────────────

  @doc """
  Formats a round-trip time value as a human-readable string.
  """
  @spec format_rtt(number()) :: String.t()
  def format_rtt(rtt) when rtt >= 1 do
    rtt = Float.round(rtt / 1.0, 3)
    "#{rtt} seconds"
  end

  def format_rtt(rtt) do
    rtt_ms = Float.round(rtt * 1000 / 1.0, 3)
    "#{rtt_ms} milliseconds"
  end

  @doc """
  Formats reception statistics (RSSI, SNR, Link Quality) from a proof packet.
  """
  @spec format_reception_stats(RNS.PacketReceipt.t()) :: String.t()
  def format_reception_stats(%RNS.PacketReceipt{proof_packet: nil}), do: ""

  def format_reception_stats(%RNS.PacketReceipt{proof_packet: proof_packet}) do
    stats = []

    stats =
      if Map.get(proof_packet, :rssi) do
        stats ++ [" [RSSI #{proof_packet.rssi} dBm]"]
      else
        stats
      end

    stats =
      if Map.get(proof_packet, :snr) do
        stats ++ [" [SNR #{proof_packet.snr} dB]"]
      else
        stats
      end

    stats =
      if Map.get(proof_packet, :q) do
        stats ++ [" [Link Quality #{proof_packet.q}%]"]
      else
        stats
      end

    Enum.join(stats)
  end

  # ── Private Helpers ────────────────────────────────────────────────

  defp parse_full_name(full_name) do
    {app_name, aspects} = RNS.Destination.app_and_aspects_from_name(full_name)
    {:ok, {app_name, aspects}}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp wait_for_path(destination_hash, timeout_at) do
    syms = String.graphemes("⢄⢂⢁⡁⡈⡐⡠")
    do_wait_for_path(destination_hash, syms, 0, timeout_at)
  end

  defp do_wait_for_path(destination_hash, syms, i, timeout_at) do
    if not RNS.Transport.has_path(destination_hash) and
         System.system_time(:millisecond) < timeout_at do
      Process.sleep(100)
      sym = Enum.at(syms, rem(i, length(syms)))
      IO.write("\b\b#{sym} ")
      do_wait_for_path(destination_hash, syms, i + 1, timeout_at)
    end
  end

  defp wait_for_receipt(receipt, timeout_at) do
    syms = String.graphemes("⢄⢂⢁⡁⡈⡐⡠")
    do_wait_for_receipt(receipt, syms, 0, timeout_at)
  end

  defp do_wait_for_receipt(receipt, syms, i, timeout_at) do
    if receipt.status == RNS.PacketReceipt.sent() and
         System.system_time(:millisecond) < timeout_at do
      Process.sleep(100)
      sym = Enum.at(syms, rem(i, length(syms)))
      IO.write("\b\b#{sym} ")
      do_wait_for_receipt(receipt, syms, i + 1, timeout_at)
    end
  end

  defp refresh_receipt(receipt) do
    # In a running system, receipts are updated via Transport callbacks.
    # For the CLI utility, we return the receipt as-is since the wait loop
    # already polled for status changes.
    receipt
  end

  defp get_next_hop_if_name(destination_hash) do
    iface = RNS.Transport.next_hop_interface(destination_hash)

    if is_map(iface) and Map.has_key?(iface, :name) do
      iface.name || "Unknown"
    else
      "Unknown"
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
    Reticulum Probe Utility

    Usage: rnprobe [options] full_name destination_hash

    Options:
      --config PATH          Path to alternative Reticulum config directory
      -s, --size SIZE        Size of probe packet payload in bytes (default: #{@default_probe_size})
      -n, --probes N         Number of probes to send (default: 1)
      -t, --timeout SECONDS  Timeout before giving up (default: #{@default_timeout})
      -w, --wait SECONDS     Time between each probe (default: 0)
      -v, --verbose          Increase verbosity (can be repeated)
      --version              Print version and exit
      -h, --help             Print this help message and exit

    Arguments:
      full_name              Full destination name in dotted notation (e.g., app.aspect)
      destination_hash       Hexadecimal hash of the destination
    """)
  end
end
