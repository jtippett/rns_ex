defmodule RNS.Transport.Announce do
  @moduledoc """
  Represents an announce notification delivered to pub/sub subscribers.

  Subscribers receive `{:rns_announce, %Announce{}}` messages after
  calling `RNS.Transport.subscribe(:announces)`.
  """

  @type t :: %__MODULE__{
          dest_hash: binary() | nil,
          identity: map() | nil,
          app_data: binary() | nil,
          name_hash: binary() | nil
        }

  defstruct [:dest_hash, :identity, :app_data, :name_hash]
end
