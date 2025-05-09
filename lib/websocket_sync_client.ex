defmodule WebsocketSyncClient do
  @moduledoc """
  Wrapper client to provide a synchronous interface to send and receive
  messages through websocket.
  """

  use GenServer
  require Logger

  @enforce_keys [:pid]
  defstruct [:pid]

  @opaque client :: %__MODULE__{pid: pid}
  @type message :: {:text, String.t()} | {:binary, binary()}

  @doc """
  Connect to the given url.
  Options:
    * `:ping_interval` to send a ping frame every `ping_interval` ms.
    * `:default_timeout` how long `recv/2` should wait before any timeout.
  """
  @spec connect(String.t(),
          ping_interval: timeout() | nil,
          default_timeout: timeout() | nil,
          connection_options: [WebSockex.Conn.connection_option()] | nil
        ) ::
          {:ok, client}
  def connect(url, opts \\ []) do
    with {:ok, pid} <- GenServer.start(__MODULE__, [url: url] ++ opts) do
      client = %__MODULE__{pid: pid}
      {:ok, client}
    end
  end

  @doc """
  Send a message to the peer.
  """
  @spec send_message(client, message) :: :ok | {:error, reason :: term}
  def send_message(client, msg) do
    try do
      GenServer.call(client.pid, {:send_message, msg})
    catch
      :exit, _ ->
        {:error, :disconnected}
    end
  end

  @doc """
  Receive a websocket message coming from the peer.
  Returns immediately if a message has been buffered, otherwise, wait up to `:timeout` or the
  default timeout configured for the client.
  to disable timeout: set to `:infinity`.
  """
  @spec recv(client, timeout: timeout()) ::
          {:ok, message} | {:error, reason :: term}
  def recv(client, opts \\ []) do
    # the timeout is handled by the proxy itself to avoid request cancellation
    # leading to lost messages
    GenServer.call(client.pid, {:receive_message, opts}, :infinity)
  catch
    :exit, _ -> {:error, :disconnected}
  end

  @doc """
  Is the client still connected?
  """
  @spec connected?(client) :: boolean
  def connected?(client) do
    try do
      GenServer.call(client.pid, :connected?)
    catch
      :exit, _ -> false
    end
  end

  @doc """
  Disconnect the socket, and empty any buffers.
  After this, the client should not be used anymore.
  """
  @spec disconnect(client) :: :ok
  def disconnect(client) do
    GenServer.cast(client.pid, :disconnect)
  end

  @impl true
  def init(opts) do
    timeout = Keyword.get(opts, :default_timeout, 10_000)
    {:ok, pid} = GenServer.start_link(WebsocketSyncClient.WsProxy, opts)
    {:ok, %{proxy: pid, pending: nil, timeout: timeout, msg_buf: :queue.new()}}
  end

  @impl true
  def handle_call({:send_message, msg}, _from, state) do
    resp = GenServer.call(state.proxy, {:send_message, msg})
    {:reply, resp, state}
  end

  @impl true
  def handle_call(:connected?, _from, state) do
    {:reply, GenServer.call(state.proxy, :connected?), state}
  end

  @impl true
  def handle_call({:receive_message, opts}, _from, state) do
    case :queue.out(state.msg_buf) do
      {{:value, msg}, q} ->
        {:reply, msg, %{state | msg_buf: q}}

      _ ->
        do_recv(opts, state)
    end
  end

  @impl true
  def handle_cast(:disconnect, state) do
    GenServer.cast(state.proxy, :disconnect)
    {:noreply, state}
  end

  # I do not know why, when running the test, this genserver gets this message
  # There doesn't seem to be any monitor setup or trap.
  # So silence the warning by implementing the handler
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, :normal}, state)
      when state.proxy == pid,
      do: {:noreply, state}

  # handle late responses
  def handle_info(msg, state) when state.pending != nil do
    state =
      case :gen_server.check_response(msg, state.pending) do
        {:reply, resp} ->
          state
          |> Map.update!(:msg_buf, &:queue.in(resp, &1))
          |> Map.replace!(:pending, nil)

        _ ->
          state
      end

    {:noreply, state}
  end

  defp do_recv(opts, state) do
    req =
      case state.pending do
        nil -> :gen_server.send_request(state.proxy, :receive_message)
        req -> req
      end

    timeout = Keyword.get(opts, :timeout, state.timeout)

    case :gen_server.wait_response(req, timeout) do
      :timeout ->
        {:reply, {:error, :timeout}, %{state | pending: req}}

      {:error, {:normal, _pid}} ->
        {:stop, :normal, {:error, :disconnected}, %{state | pending: req}}

      {:error, {:noproc, _pid}} ->
        {:stop, :normal, {:error, :disconnected}, %{state | pending: req}}

      {:error, err} ->
        Logger.info("ws waiting response error: #{inspect(err)}")
        {:stop, :error, {:error, :disconnected}, %{state | pending: req}}

      {:reply, resp} ->
        {:reply, resp, %{state | pending: nil}}
    end
  end
end
