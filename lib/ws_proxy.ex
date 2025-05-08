defmodule WebsocketSyncClient.WsProxy do
  @moduledoc """
  Internal genserver to proxy requests between the underlying connection
  and the client.
  This is to avoid late messages polluting the inbox of the process using
  the sync client.
  """

  use GenServer
  @impl true
  def init(opts \\ []) do
    Process.flag(:trap_exit, true)
    url = Keyword.fetch!(opts, :url)

    case WebsocketSyncClient.WsConn.connect(url, self(),
           ping_interval: opts[:ping_interval],
           connection_options: opts[:connection_options]
         ) do
      {:ok, pid} ->
        state = %{
          received_messages: :queue.new(),
          awaiting_reply: nil,
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
  def handle_call({:send_message, msg}, _from, %{conn: conn} = state) do
    try do
      case WebSockex.send_frame(conn, msg) do
        :ok ->
          {:reply, :ok, state}

        {:error, %WebSockex.NotConnectedError{}} ->
          reply_disconnected(state)
      end
    catch
      # consider any error fatal and disconnect
      _, _ ->
        Process.exit(conn, :shutdown)
        reply_disconnected(state)
    end
  end

  @impl true
  def handle_call(:connected?, _from, %{conn_state: conn_state} = state) do
    {:reply, conn_state != :disconnected, state}
  end

  @impl true
  def handle_call(
        :receive_message,
        _from,
        %{conn_state: :disconnected, received_messages: buf} = state
      ) do
    case :queue.out(buf) do
      {:empty, _} ->
        {:reply, {:error, :disconnected}, state}

      {{:value, msg}, new_buf} ->
        {:reply, {:ok, msg}, %{state | received_messages: new_buf}}
    end
  end

  @impl true
  def handle_call(
        :receive_message,
        from,
        %{received_messages: buf} = state
      ) do
    case :queue.out(buf) do
      {:empty, _} ->
        {:noreply, %{state | awaiting_reply: from}}

      {{:value, msg}, new_buf} ->
        {:reply, {:ok, msg}, %{state | received_messages: new_buf}}
    end
  end

  @impl true
  def handle_info(
        {:received_message, msg},
        %{received_messages: q, awaiting_reply: awaiting} = state
      ) do
    case awaiting do
      nil ->
        {:noreply, %{state | received_messages: :queue.in(msg, q)}}

      from ->
        GenServer.reply(from, {:ok, msg})
        {:noreply, %{state | awaiting_reply: nil}}
    end
  end

  def handle_info({:EXIT, conn_pid, _reason}, %{conn: conn, awaiting_reply: awaiting} = state)
      when conn == conn_pid do
    # immediately send a response to any waiting client
    if awaiting != nil, do: GenServer.reply(awaiting, {:error, :disconnected})

    {:noreply, %{state | conn_state: :disconnected}}
  end

  @impl true
  def handle_cast(:disconnect, state) do
    GenServer.cast(state.conn, :close)

    final_state = %{
      state
      | conn_state: :disconnected,
        received_messages: :queue.new(),
        awaiting_reply: nil
    }

    {:stop, :normal, final_state}
  end

  defp reply_disconnected(state) do
    {:reply, {:error, :disconnected}, %{state | conn_state: :disconnected}}
  end
end
