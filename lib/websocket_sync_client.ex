defmodule WebsocketSyncClient do
  @moduledoc """
  Wrapper client to provide a synchronous interface to send and receive
  messages through websocket.
  """

  use GenServer

  @enforce_keys [:pid, :default_timeout]
  defstruct [:pid, :default_timeout]

  @opaque client :: %__MODULE__{pid: pid, default_timeout: timeout()}

  @doc """
  Connect to the given url.
  Options:
    * :ping_interval to send a ping frame every `ping_interval` ms
    * :default_timeout how long receive_message should wait before any timeout
  """
  @spec connect(String.t(), ping_interval: timeout() | nil, default_timeout: timeout() | nil) ::
          {:ok, client}
  def connect(url, opts \\ []) do
    with {:ok, pid} <- GenServer.start(__MODULE__, [url: url] ++ opts) do
      Process.monitor(pid)
      client = %__MODULE__{pid: pid, default_timeout: Keyword.get(opts, :default_timeout, 10_000)}
      {:ok, client}
    end
  end

  @doc """
  Send a message to the peer
  """
  @spec send_message(client, String.t(), :text | :binary | nil) :: :ok | {:error, reason :: term}
  def send_message(client, msg, type \\ :text) do
    try do
      GenServer.call(client.pid, {:send_message, msg, type})
    catch
      :exit, _ ->
        {:error, :disconnected}
    end
  end

  @doc """
  Receive a text message coming from the peer.
  Returns immediately if a message has been buffered, otherwise, wait up to :timeout or the
  default timeout configured for the client.
  to disable timeout: set to :infinity

  In case of a late message, a message of the form {:received, String.t()} will be
  in the calling process' mailbox.
  """
  @spec recv(client, timeout: timeout()) ::
          {:ok, String.t()} | {:error, reason :: term}
  def recv(client, opts \\ []) do
    # As of OTP24 GenServer.call will drop late messages that arrive after a
    # timeout. So I need to recreate a similar machinery to GenServer.call
    # to avoid dropping messages. The downside is that they'll polute the
    # mailbox of the calling process
    receive do
      {:received, resp} -> resp
    after
      0 -> do_recv(client, opts)
    end
  end

  defp do_recv(client, opts) do
    timeout = Keyword.get(opts, :timeout, client.default_timeout)

    mon_ref = Process.monitor(client.pid)
    GenServer.cast(client.pid, {:receive_message, self()})

    receive do
      {:received, resp} ->
        Process.demonitor(mon_ref, [:flush])
        resp

      {:DOWN, ^mon_ref, :process, _pid, _reason} ->
        {:error, :disconnected}
    after
      timeout ->
        Process.demonitor(mon_ref, [:flush])
        {:error, :timeout}
    end
  end

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
  def init(opts \\ []) do
    # def connect(url, opts \\ []) do
    Process.flag(:trap_exit, true)
    url = Keyword.fetch!(opts, :url)

    case WebsocketSyncClient.WsConn.connect(url, self(), ping_interval: opts[:ping_interval]) do
      {:ok, pid} ->
        state = %{
          received_messages: :queue.new(),
          awaiting_replies: :queue.new(),
          conn: pid,
          conn_state: :connected
        }

        {:ok, state}

      {:error, err} ->
        {:stop, err}
    end
  end

  @impl true
  def handle_call({:send_message, _}, _from, %{conn_state: :disconnected} = state) do
    {:reply, {:error, :disconnected}, state}
  end

  @impl true
  def handle_call({:send_message, msg, type}, _from, %{conn: conn} = state) do
    try do
      case WebSockex.send_frame(conn, {type, msg}) do
        :ok ->
          {:reply, :ok, state}

        {:error, %WebSockex.NotConnectedError{}} ->
          reply_disconnected(state)
      end
    catch
      # consider any error fatal and disconnect
      _, _ ->
        Process.exit(conn, :normal)
        reply_disconnected(state)
    end
  end

  @impl true
  def handle_call(:connected?, _from, %{conn_state: conn_state} = state) do
    {:reply, conn_state != :disconnected, state}
  end

  @impl true
  def handle_info(
        {:received_message, msg},
        %{received_messages: q, awaiting_replies: awaiting} = state
      ) do
    case :queue.out(awaiting) do
      {:empty, _} ->
        {:noreply, %{state | received_messages: :queue.in(msg, q)}}

      {{:value, from}, awaiting} ->
        send(from, {:received, {:ok, msg}})
        {:noreply, %{state | awaiting_replies: awaiting}}
    end
  end

  def handle_info({:EXIT, conn_pid, _reason}, %{conn: conn, awaiting_replies: awaiting} = state)
      when conn == conn_pid do
    # immediately send a response to any waiting client
    :queue.fold(
      fn from, _acc ->
        send(from, {:received, {:error, :disconnected}})
        nil
      end,
      nil,
      awaiting
    )

    {:noreply,
     %{
       state
       | conn_state: :disconnected,
         awaiting_replies: :queue.new()
     }}
  end

  @impl true
  def handle_cast(:disconnect, state) do
    final_state = %{
      state
      | conn_state: :disconnected,
        received_messages: :queue.new(),
        awaiting_replies: :queue.new()
    }

    {:stop, :normal, final_state}
  end

  @impl true
  def handle_cast(
        {:receive_message, from},
        %{conn_state: :disconnected, received_messages: buf} = state
      ) do
    case :queue.out(buf) do
      {:empty, _} ->
        send(from, {:received, {:error, :disconnected}})
        {:noreply, state}

      {{:value, msg}, new_buf} ->
        send(from, {:received, {:ok, msg}})
        {:noreply, %{state | received_messages: new_buf}}
    end
  end

  @impl true
  def handle_cast(
        {:receive_message, from},
        %{received_messages: buf, awaiting_replies: awaiting} = state
      ) do
    case :queue.out(buf) do
      {:empty, _} ->
        {:noreply, %{state | awaiting_replies: :queue.in(from, awaiting)}}

      {{:value, msg}, new_buf} ->
        send(from, {:received, {:ok, msg}})
        {:noreply, %{state | received_messages: new_buf}}
    end
  end

  defp reply_disconnected(state) do
    {:reply, {:error, :disconnected}, %{state | conn_state: :disconnected}}
  end
end
