defmodule WebsocketSyncClient.WsConn do
  @moduledoc false

  use WebSockex
  require Logger

  @doc """
  Connect to the given url.
  Can provide :ping_interval to send a ping frame every `ping_interval` ms
  """
  @spec connect(String.t(), pid,
          ping_interval: timeout() | nil,
          connection_options: [WebSockex.Conn.connection_option()] | nil
        ) :: GenServer.on_start()
  def connect(url, parent, opts \\ []) do
    state = %{
      parent: parent
    }

    conn_opts = Keyword.get(opts, :connection_options)

    case WebSockex.start_link(url, __MODULE__, state, conn_opts || []) do
      {:ok, pid} ->
        if opts[:ping_interval] do
          :timer.send_interval(opts[:ping_interval], :ping)
        end

        {:ok, pid}

      err ->
        err
    end
  end

  def handle_frame(msg, %{parent: parent} = state) do
    send(parent, {:received_message, msg})
    {:ok, state}
  end

  def handle_cast({:send, msg}, state) do
    {:reply, {:text, msg}, state}
  end

  def handle_info(:ping, state) do
    {:reply, :ping, state}
  end

  def handle_info(:close, state) do
    {:close, state}
  end
end
