defmodule RNS.ProofDestination do
  @moduledoc """
  A special destination that allows Reticulum to direct proofs back
  to the proved packet's sender.
  """

  @truncated_hashlength 128
  @dest_single 0x00

  defstruct [:hash, :type]

  @type t :: %__MODULE__{
          hash: binary(),
          type: non_neg_integer()
        }

  @doc """
  Creates a ProofDestination from a packed packet.

  The hash is the truncated hash of the packet's full hash.
  """
  @spec new(RNS.Packet.t()) :: t()
  def new(%RNS.Packet{} = packet) do
    full_hash = RNS.Packet.hash(packet)
    hash_len = div(@truncated_hashlength, 8)
    <<truncated::binary-size(hash_len), _::binary>> = full_hash

    %__MODULE__{
      hash: truncated,
      type: @dest_single
    }
  end

  @doc """
  Encrypts plaintext — for ProofDestination, returns plaintext unchanged.
  """
  @spec encrypt(t(), binary()) :: binary()
  def encrypt(%__MODULE__{}, plaintext), do: plaintext
end
