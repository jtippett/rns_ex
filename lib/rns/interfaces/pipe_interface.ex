defmodule RNS.Interfaces.PipeInterface do
  @moduledoc """
  Pipe interface for RNS.

  Communicates with external programs via `Port.open/2` using stdin/stdout
  pipes with HDLC framing. The subprocess is spawned on start and
  automatically respawned after `respawn_delay` if it exits.

  Matches `python/RNS/Interfaces/PipeInterface.py`.
  """

  use GenServer
  use RNS.Interfaces.Interface

  require Logger

  alias RNS.Interfaces.Interface.HDLC

  @max_chunk 32_768
  @bitrate_guess 1_000_000
  @default_ifac_size 8
  @hw_mtu 1064
  @default_respawn_delay 5_000

  defstruct default_fields() ++
              [
                # Pipe config
                command: nil,
                respawn_delay: @default_respawn_delay,

                # Runtime state
                port_ref: nil,
                pipe_is_open: false,
                frame_buffer: <<>>,

                # Owner (Transport or callback)
                owner: nil
              ]

  @type t :: %__MODULE__{}

  # ── Public API ──────────────────────────────────────────────────

  @doc "Returns the maximum chunk size for pipe reads."
  @spec max_chunk() :: pos_integer()
  def max_chunk, do: @max_chunk

  @doc "Returns the guessed bitrate for pipe interfaces."
  @spec bitrate_guess() :: pos_integer()
  def bitrate_guess, do: @bitrate_guess

  @doc "Returns the default IFAC size for pipe interfaces."
  @spec default_ifac_size() :: pos_integer()
  def default_ifac_size, do: @default_ifac_size

  @doc "Returns the hardware MTU for pipe interfaces."
  @spec hw_mtu() :: pos_integer()
  def hw_mtu, do: @hw_mtu

  @doc "Returns the default respawn delay in milliseconds."
  @spec default_respawn_delay() :: pos_integer()
  def default_respawn_delay, do: @default_respawn_delay

  @doc """
  Starts a Pipe interface GenServer.

  ## Options

    * `:name` — interface name (required)
    * `:command` — shell command to spawn (required)
    * `:respawn_delay` — delay before respawning subprocess in ms (default: 5000)
    * `:owner` — owner process or callback for inbound data
    * `:server_name` — GenServer registration name (optional)

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    server_opts =
      case Keyword.get(opts, :server_name) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc "Sends data out through this pipe interface."
  @spec send_data(GenServer.server(), binary()) :: :ok | {:error, term()}
  def send_data(server, data) do
    GenServer.call(server, {:send_data, data})
  end

  @doc "Returns the current state of the interface."
  @spec get_state(GenServer.server()) :: t()
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  @doc "Detaches and stops the interface."
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  # ── Behaviour callbacks ──────────────────────────────────────────

  @impl RNS.Interfaces.Interface
  def process_outgoing(state, data) do
    if state.online and state.pipe_is_open do
      framed = HDLC.frame(data)

      case do_write(state, framed) do
        :ok ->
          {:ok, %{state | txb: state.txb + byte_size(framed)}}

        {:error, reason} ->
          Logger.error("Pipe interface #{state.name} write error: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:error, :offline}
    end
  end

  @impl RNS.Interfaces.Interface
  def process_incoming(state, data) do
    updated = %{state | rxb: state.rxb + byte_size(data)}

    if state.owner do
      notify_owner(state.owner, data, updated)
    end

    {:ok, updated}
  end

  @impl RNS.Interfaces.Interface
  def detach(%__MODULE__{} = state) do
    close_pipe(state)
    :ok
  end

  # ── GenServer callbacks ──────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    command = Keyword.get(opts, :command)
    respawn_delay = Keyword.get(opts, :respawn_delay, @default_respawn_delay)
    owner = Keyword.get(opts, :owner)

    if command == nil do
      {:stop, {:error, :no_command_specified}}
    else
      state = %__MODULE__{
        name: name,
        command: command,
        respawn_delay: respawn_delay,
        owner: owner,
        in: true,
        out: true,
        online: false,
        bitrate: @bitrate_guess,
        hw_mtu: @hw_mtu,
        ifac_size: @default_ifac_size,
        created: System.system_time(:second)
      }

      state = %{state | hash: RNS.Interfaces.Interface.get_hash(state)}

      case open_pipe(state) do
        {:ok, new_state} ->
          if new_state.pipe_is_open do
            {:ok, configure_pipe(new_state)}
          else
            {:stop, {:error, :could_not_connect_pipe}}
          end

        {:error, reason} ->
          {:stop, {:error, reason}}
      end
    end
  end

  @impl GenServer
  def handle_call({:send_data, data}, _from, state) do
    case process_outgoing(state, data) do
      {:ok, updated} -> {:reply, :ok, updated}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl GenServer
  def handle_info({port_ref, {:data, data}}, %{port_ref: port_ref} = state)
      when is_port(port_ref) do
    state = handle_pipe_data(state, data)
    {:noreply, state}
  end

  def handle_info({port_ref, {:exit_status, _status}}, %{port_ref: port_ref} = state) do
    Logger.info("Subprocess terminated on #{state.name}")
    handle_subprocess_exit(state)
  end

  def handle_info({:EXIT, port_ref, _reason}, %{port_ref: port_ref} = state) do
    Logger.info("Subprocess exited on #{state.name}")
    handle_subprocess_exit(state)
  end

  def handle_info(:respawn, state) do
    if not state.online and not state.detached do
      Logger.info("Attempting to respawn subprocess for #{state.name}...")

      case open_pipe(state) do
        {:ok, new_state} ->
          if new_state.pipe_is_open do
            {:noreply, configure_pipe(new_state)}
          else
            schedule_respawn(state.respawn_delay)
            {:noreply, state}
          end

        {:error, _reason} ->
          schedule_respawn(state.respawn_delay)
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({_port, {:data, data}}, state) when is_binary(data) do
    # Data from a port that might not match our current port_ref (during respawn)
    state = handle_pipe_data(state, data)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    close_pipe(state)
    :ok
  end

  # ── should_ingress_limit (always false, matching Python) ─────────

  @doc """
  Pipe interfaces never limit ingress.
  Matches Python's behaviour.
  """
  @spec should_ingress_limit(t()) :: {false, t()}
  def should_ingress_limit(%__MODULE__{} = state), do: {false, state}

  # ── Private helpers ──────────────────────────────────────────────

  defp open_pipe(state) do
    Logger.info("Connecting subprocess pipe for #{state.name}...")

    try do
      port_ref =
        Port.open(
          {:spawn, state.command},
          [:binary, :stream, :exit_status, :use_stdio]
        )

      {:ok, %{state | port_ref: port_ref, pipe_is_open: true}}
    rescue
      e ->
        Logger.error("Could not connect pipe for #{state.name}: #{inspect(e)}")
        {:error, e}
    end
  end

  defp configure_pipe(state) do
    Logger.info("Subprocess pipe for #{state.name} is now connected")
    %{state | online: true}
  end

  defp do_write(%{port_ref: ref}, data) when is_port(ref) do
    try do
      Port.command(ref, data)
      :ok
    rescue
      _ -> {:error, :write_failed}
    end
  end

  defp do_write(_, _data), do: {:error, :no_pipe}

  defp close_pipe(%{port_ref: ref}) when is_port(ref) do
    try do
      Port.close(ref)
    rescue
      _ -> :ok
    end
  end

  defp close_pipe(_), do: :ok

  defp handle_pipe_data(state, data) do
    buffer = state.frame_buffer <> data

    {frames, remaining} = HDLC.deframe(buffer)

    state = %{state | frame_buffer: remaining}

    Enum.reduce(frames, state, fn frame, acc ->
      if byte_size(frame) > 0 and byte_size(frame) <= acc.hw_mtu do
        {:ok, updated} = process_incoming(acc, frame)
        updated
      else
        acc
      end
    end)
  end

  defp handle_subprocess_exit(state) do
    close_pipe(state)
    updated = %{state | online: false, pipe_is_open: false, port_ref: nil, frame_buffer: <<>>}

    if not state.detached do
      Logger.error("Interface #{state.name} subprocess exited. Will attempt respawn.")
      schedule_respawn(state.respawn_delay)
    end

    {:noreply, updated}
  end

  defp schedule_respawn(delay) do
    Process.send_after(self(), :respawn, delay)
  end

  defp notify_owner(owner, data, interface) when is_pid(owner) do
    send(owner, {:pipe_interface_data, data, interface})
  end

  defp notify_owner({module, fun}, data, interface) when is_atom(module) and is_atom(fun) do
    apply(module, fun, [data, interface])
  end

  defp notify_owner(fun, data, interface) when is_function(fun, 2) do
    fun.(data, interface)
  end

  defp notify_owner(_, _data, _interface), do: :ok

  # ── String.Chars protocol ────────────────────────────────────────

  defimpl String.Chars, for: __MODULE__ do
    def to_string(%{name: name}) do
      "PipeInterface[#{name}]"
    end
  end
end
