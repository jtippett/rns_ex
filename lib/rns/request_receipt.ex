defmodule RNS.RequestReceipt.Callbacks do
  @moduledoc "Holds callback functions for request receipt events."

  defstruct [
    :response,
    :failed,
    :progress
  ]

  @type t :: %__MODULE__{
          response: function() | nil,
          failed: function() | nil,
          progress: function() | nil
        }
end

defmodule RNS.RequestReceipt do
  @moduledoc """
  Tracks the state and result of a request sent over a Link.

  Returned by the `request` method of `RNS.Link`. Provides methods to
  check status, response time, and response data when the request concludes.
  """

  require Logger

  # ── Status constants ──────────────────────────────────────────

  @failed 0x00
  @sent 0x01
  @delivered 0x02
  @receiving 0x03
  @ready 0x04

  defstruct [
    :hash,
    :request_id,
    :link,
    :packet_receipt,
    :resource,
    :request_size,
    :response,
    :response_transfer_size,
    :response_size,
    :metadata,
    :concluded_at,
    :response_concluded_at,
    :started_at,
    :sent_at,
    :timeout,
    status: @sent,
    progress: 0.0,
    callbacks: nil
  ]

  @type t :: %__MODULE__{}

  # ── Constant accessors ─────────────────────────────────────────

  @spec failed() :: non_neg_integer()
  def failed, do: @failed

  @spec sent() :: non_neg_integer()
  def sent, do: @sent

  @spec delivered() :: non_neg_integer()
  def delivered, do: @delivered

  @spec receiving() :: non_neg_integer()
  def receiving, do: @receiving

  @spec ready() :: non_neg_integer()
  def ready, do: @ready

  # ── Constructor ────────────────────────────────────────────────

  @doc """
  Creates a new RequestReceipt.

  Options:
  - `:link` — the link this request was sent over (required)
  - `:packet_receipt` — the packet receipt from sending
  - `:resource` — the resource if sent as resource
  - `:response_callback` — called when response is received
  - `:failed_callback` — called when request fails
  - `:progress_callback` — called when response progress updates
  - `:timeout` — timeout in seconds (required)
  - `:request_size` — size of the request in bytes
  """
  @spec new(keyword()) :: t()
  def new(opts) do
    link = Keyword.fetch!(opts, :link)
    timeout = Keyword.fetch!(opts, :timeout)
    packet_receipt = Keyword.get(opts, :packet_receipt)
    resource = Keyword.get(opts, :resource)
    request_size = Keyword.get(opts, :request_size)

    now = System.system_time(:second)

    {hash, started_at} =
      cond do
        packet_receipt != nil ->
          {Map.get(packet_receipt, :truncated_hash), now}

        resource != nil ->
          {Map.get(resource, :request_id), nil}

        true ->
          {nil, now}
      end

    callbacks = %__MODULE__.Callbacks{
      response: Keyword.get(opts, :response_callback),
      failed: Keyword.get(opts, :failed_callback),
      progress: Keyword.get(opts, :progress_callback)
    }

    %__MODULE__{
      hash: hash,
      request_id: hash,
      link: link,
      packet_receipt: packet_receipt,
      resource: resource,
      request_size: request_size,
      timeout: timeout,
      status: @sent,
      progress: 0.0,
      started_at: started_at,
      sent_at: now,
      callbacks: callbacks
    }
  end

  # ── Status queries ─────────────────────────────────────────────

  @doc "Returns the request ID as bytes."
  @spec request_id(t()) :: binary() | nil
  def request_id(%__MODULE__{request_id: id}), do: id

  @doc "Returns the current status of the request."
  @spec status(t()) :: non_neg_integer()
  def status(%__MODULE__{status: status}), do: status

  @doc "Returns the progress as a float between 0.0 and 1.0."
  @spec progress(t()) :: float()
  def progress(%__MODULE__{progress: progress}), do: progress

  @doc "Returns the response if ready, otherwise nil."
  @spec response(t()) :: term() | nil
  def response(%__MODULE__{status: @ready, response: response}), do: response
  def response(%__MODULE__{}), do: nil

  @doc "Returns the response time in seconds, or nil if not ready."
  @spec response_time(t()) :: number() | nil
  def response_time(%__MODULE__{
        status: @ready,
        response_concluded_at: concluded,
        started_at: started
      })
      when concluded != nil and started != nil do
    concluded - started
  end

  def response_time(%__MODULE__{}), do: nil

  @doc "Returns true if the request has concluded (successfully or with failure)."
  @spec concluded?(t()) :: boolean()
  def concluded?(%__MODULE__{status: @ready}), do: true
  def concluded?(%__MODULE__{status: @failed}), do: true
  def concluded?(%__MODULE__{}), do: false

  # ── Request timed out ──────────────────────────────────────────

  @doc "Marks the request as timed out/failed."
  @spec request_timed_out(t()) :: t()
  def request_timed_out(%__MODULE__{status: @delivered} = receipt) do
    updated = %{receipt | status: @failed, concluded_at: System.system_time(:second)}

    if updated.callbacks && updated.callbacks.failed do
      try do
        updated.callbacks.failed.(updated)
      rescue
        e ->
          Logger.warning("Request receipt failed callback raised: #{inspect(e)}")
          :ok
      end
    end

    updated
  end

  def request_timed_out(%__MODULE__{} = receipt), do: receipt

  # ── Response received ──────────────────────────────────────────

  @doc "Records that a response was received."
  @spec response_received(t(), term(), term()) :: t()
  def response_received(receipt, response, metadata \\ nil)

  def response_received(%__MODULE__{status: status} = receipt, response, metadata)
      when status != @failed do
    updated = %{
      receipt
      | progress: 1.0,
        response: response,
        metadata: metadata,
        status: @ready,
        response_concluded_at: System.system_time(:second)
    }

    if updated.callbacks && updated.callbacks.progress do
      try do
        updated.callbacks.progress.(updated)
      rescue
        e ->
          Logger.warning("Request receipt progress callback raised: #{inspect(e)}")
          :ok
      end
    end

    if updated.callbacks && updated.callbacks.response do
      try do
        updated.callbacks.response.(updated)
      rescue
        e ->
          Logger.warning("Request receipt response callback raised: #{inspect(e)}")
          :ok
      end
    end

    updated
  end

  def response_received(%__MODULE__{} = receipt, _response, _metadata), do: receipt

  # ── Response resource progress ─────────────────────────────────

  @doc "Updates progress from a response resource transfer."
  @spec response_resource_progress(t(), term()) :: t()
  def response_resource_progress(%__MODULE__{status: @failed} = receipt, _resource) do
    receipt
  end

  def response_resource_progress(%__MODULE__{} = receipt, resource) when resource != nil do
    updated = %{receipt | status: @receiving, progress: Map.get(resource, :progress, 0.0)}

    if updated.callbacks && updated.callbacks.progress do
      try do
        updated.callbacks.progress.(updated)
      rescue
        e ->
          Logger.warning("Request receipt resource progress callback raised: #{inspect(e)}")
          :ok
      end
    end

    updated
  end

  def response_resource_progress(%__MODULE__{} = receipt, _resource), do: receipt

  # ── Check timeout ──────────────────────────────────────────────

  @doc "Checks if the request has timed out and marks it as failed if so."
  @spec check_timeout(t()) :: t()
  def check_timeout(%__MODULE__{status: @delivered, timeout: timeout} = receipt)
      when timeout != nil do
    if receipt.sent_at && System.system_time(:second) > receipt.sent_at + timeout do
      request_timed_out(receipt)
    else
      receipt
    end
  end

  def check_timeout(%__MODULE__{} = receipt), do: receipt
end
