defmodule RNS.PacketReceipt do
  @moduledoc """
  Tracks delivery status of sent packets.

  PacketReceipt instances are created automatically when a packet is sent
  with `create_receipt: true`. They track whether a packet was delivered,
  timed out, or failed.

  Matches `python/RNS/Packet.py` PacketReceipt class.
  """

  # ── Status constants ─────────────────────────────────────────────

  @failed 0x00
  @sent 0x01
  @delivered 0x02
  @culled 0xFF

  # Identity constants for proof lengths
  @hashlength 256
  @siglength 512

  @expl_length div(@hashlength, 8) + div(@siglength, 8)
  @impl_length div(@siglength, 8)

  defmodule Callbacks do
    @moduledoc false
    defstruct [:delivery, :timeout]

    @type t :: %__MODULE__{
            delivery: (RNS.PacketReceipt.t() -> any()) | nil,
            timeout: (RNS.PacketReceipt.t() -> any()) | nil
          }
  end

  defstruct [
    :hash,
    :truncated_hash,
    :sent,
    :sent_at,
    :proved,
    :status,
    :destination,
    :callbacks,
    :concluded_at,
    :proof_packet,
    :timeout
  ]

  @type t :: %__MODULE__{
          hash: binary(),
          truncated_hash: binary(),
          sent: boolean(),
          sent_at: integer(),
          proved: boolean(),
          status: non_neg_integer(),
          destination: map(),
          callbacks: Callbacks.t(),
          concluded_at: integer() | nil,
          proof_packet: any(),
          timeout: number()
        }

  # ── Constant accessors ──────────────────────────────────────────

  @doc "Receipt status: FAILED (0x00)"
  @spec failed() :: non_neg_integer()
  def failed, do: @failed

  @doc "Receipt status: SENT (0x01)"
  @spec sent() :: non_neg_integer()
  def sent, do: @sent

  @doc "Receipt status: DELIVERED (0x02)"
  @spec delivered() :: non_neg_integer()
  def delivered, do: @delivered

  @doc "Receipt status: CULLED (0xFF)"
  @spec culled() :: non_neg_integer()
  def culled, do: @culled

  @doc "Explicit proof length in bytes (hash + signature = 96)."
  @spec expl_length() :: non_neg_integer()
  def expl_length, do: @expl_length

  @doc "Implicit proof length in bytes (signature only = 64)."
  @spec impl_length() :: non_neg_integer()
  def impl_length, do: @impl_length

  # ── Creation ─────────────────────────────────────────────────────

  @doc """
  Creates a new PacketReceipt from a sent packet.
  """
  @spec new(RNS.Packet.t()) :: t()
  def new(%RNS.Packet{} = packet) do
    now = System.system_time(:second)

    %__MODULE__{
      hash: RNS.Packet.get_hash(packet),
      truncated_hash: RNS.Packet.get_truncated_hash(packet),
      sent: true,
      sent_at: now,
      proved: false,
      status: @sent,
      destination: packet.destination,
      callbacks: %Callbacks{},
      concluded_at: nil,
      proof_packet: nil,
      timeout: default_timeout(packet)
    }
  end

  defp default_timeout(%RNS.Packet{} = packet) do
    dest_type = Map.get(packet.destination, :type)

    if dest_type == 0x03 do
      # LINK destination — use link RTT-based timeout
      rtt = Map.get(packet.destination, :rtt, 1.0)
      factor = Map.get(packet.destination, :traffic_timeout_factor, 5.0)
      max(rtt * factor, 5.0 / 1000.0)
    else
      # Default timeout based on hops
      RNS.Packet.timeout_per_hop() * 2
    end
  end

  # ── Status ───────────────────────────────────────────────────────

  @doc "Returns the current receipt status."
  @spec get_status(t()) :: non_neg_integer()
  def get_status(%__MODULE__{status: status}), do: status

  @doc "Returns the round-trip time in seconds."
  @spec get_rtt(t()) :: number()
  def get_rtt(%__MODULE__{concluded_at: concluded_at, sent_at: sent_at}) do
    concluded_at - sent_at
  end

  @doc "Returns true if the receipt has timed out."
  @spec is_timed_out(t()) :: boolean()
  def is_timed_out(%__MODULE__{sent_at: sent_at, timeout: timeout}) do
    sent_at + timeout < System.system_time(:second)
  end

  @doc """
  Checks if the receipt has timed out and updates status accordingly.

  If timed out with timeout > 0, status becomes FAILED.
  If timed out with timeout == -1, status becomes CULLED.
  Invokes the timeout callback if set.
  """
  @spec check_timeout(t()) :: t()
  def check_timeout(%__MODULE__{status: @sent} = receipt) do
    if is_timed_out(receipt) do
      new_status = if receipt.timeout == -1, do: @culled, else: @failed
      now = System.system_time(:second)

      receipt = %{receipt | status: new_status, concluded_at: now}

      if receipt.callbacks.timeout do
        Task.start(fn -> receipt.callbacks.timeout.(receipt) end)
      end

      receipt
    else
      receipt
    end
  end

  def check_timeout(%__MODULE__{} = receipt), do: receipt

  # ── Timeout and callbacks ────────────────────────────────────────

  @doc "Sets the timeout in seconds."
  @spec set_timeout(t(), number()) :: t()
  def set_timeout(%__MODULE__{} = receipt, timeout) do
    %{receipt | timeout: timeout * 1.0}
  end

  @doc "Sets the delivery success callback."
  @spec set_delivery_callback(t(), function()) :: t()
  def set_delivery_callback(%__MODULE__{} = receipt, callback) do
    %{receipt | callbacks: %{receipt.callbacks | delivery: callback}}
  end

  @doc "Sets the timeout callback."
  @spec set_timeout_callback(t(), function()) :: t()
  def set_timeout_callback(%__MODULE__{} = receipt, callback) do
    %{receipt | callbacks: %{receipt.callbacks | timeout: callback}}
  end

  # ── Proof validation ─────────────────────────────────────────────

  @doc """
  Validates a proof packet against this receipt.
  """
  @spec validate_proof_packet(t(), RNS.Packet.t()) :: boolean()
  def validate_proof_packet(%__MODULE__{} = receipt, proof_packet) do
    if Map.get(proof_packet, :link) do
      validate_link_proof(receipt, proof_packet.data, proof_packet.link, proof_packet)
    else
      validate_proof(receipt, proof_packet.data, proof_packet)
    end
  end

  @doc """
  Validates a raw proof (hash + signature) against this receipt.
  """
  @spec validate_proof(t(), binary(), any()) :: boolean()
  def validate_proof(%__MODULE__{} = receipt, proof, proof_packet \\ nil) do
    hash_len = div(@hashlength, 8)
    sig_len = div(@siglength, 8)

    cond do
      byte_size(proof) == @expl_length ->
        <<proof_hash::binary-size(hash_len), signature::binary-size(sig_len)>> = proof

        identity = get_in_map(receipt.destination, [:identity])

        if proof_hash == receipt.hash and identity != nil do
          if RNS.Identity.validate(identity, signature, receipt.hash) do
            conclude_delivery(receipt, proof_packet)
          else
            false
          end
        else
          false
        end

      byte_size(proof) == @impl_length ->
        identity = get_in_map(receipt.destination, [:identity])

        if identity == nil do
          false
        else
          signature = binary_part(proof, 0, sig_len)

          if RNS.Identity.validate(identity, signature, receipt.hash) do
            conclude_delivery(receipt, proof_packet)
          else
            false
          end
        end

      true ->
        false
    end
  end

  @doc """
  Validates a link proof against this receipt.
  """
  @spec validate_link_proof(t(), binary(), map(), any()) :: boolean()
  def validate_link_proof(%__MODULE__{} = receipt, proof, link, proof_packet \\ nil) do
    hash_len = div(@hashlength, 8)
    sig_len = div(@siglength, 8)

    if byte_size(proof) >= hash_len + sig_len do
      <<proof_hash::binary-size(hash_len), signature::binary-size(sig_len)>> =
        binary_part(proof, 0, hash_len + sig_len)

      if proof_hash == receipt.hash do
        validate_fn = Map.get(link, :validate)

        proof_valid =
          if is_function(validate_fn, 2) do
            validate_fn.(signature, receipt.hash)
          else
            false
          end

        if proof_valid do
          conclude_delivery(receipt, proof_packet)
        else
          false
        end
      else
        false
      end
    else
      false
    end
  end

  defp conclude_delivery(%__MODULE__{} = receipt, proof_packet) do
    now = System.system_time(:second)

    receipt = %{receipt |
      status: @delivered,
      proved: true,
      concluded_at: now,
      proof_packet: proof_packet
    }

    if receipt.callbacks.delivery do
      try do
        receipt.callbacks.delivery.(receipt)
      rescue
        e ->
          RNS.log("Error while executing proof validated callback. The contained exception was: #{inspect(e)}", RNS.log_error())
      end
    end

    true
  end

  defp get_in_map(map, keys) when is_map(map) do
    Enum.reduce_while(keys, map, fn key, acc ->
      case Map.get(acc, key) do
        nil -> {:halt, nil}
        val -> {:cont, val}
      end
    end)
  end

  defp get_in_map(_, _), do: nil
end
