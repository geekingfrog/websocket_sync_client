defmodule WebsocketSyncClient.TestServer do
  @moduledoc false
  Module.register_attribute(__MODULE__, :dialyzer, persist: true)
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  match _ do
    send_resp(conn, 200, "Hello from plug")
  end

  def start(pid) when is_pid(pid) do
    ref = make_ref()
    port = get_port()
    {:ok, agent_pid} = Agent.start_link(fn -> :ok end)
    url = "ws://localhost:#{port}/ws"

    opts = [dispatch: dispatch({pid, agent_pid}), port: port, ref: ref]

    case Plug.Cowboy.http(__MODULE__, [], opts) do
      {:ok, _} ->
        {:ok, {ref, url}}

      {:error, :eaddrinuse} ->
        start(pid)
    end
  end

  def shutdown(ref) do
    Plug.Cowboy.shutdown(ref)
  end

  defp dispatch(tuple) do
    [{:_, [{"/ws", WebsocketSyncClient.TestSocket, [tuple]}]}]
  end

  defp get_port do
    unless Process.whereis(__MODULE__), do: start_ports_agent()

    Agent.get_and_update(__MODULE__, fn port -> {port, port + 1} end)
  end

  defp start_ports_agent do
    Agent.start(fn -> Enum.random(50_000..63_000) end, name: __MODULE__)
  end
end

defmodule WebsocketSyncClient.TestSocket do
  @behaviour :cowboy_websocket

  @impl true
  def init(request, _state) do
    {:cowboy_websocket, request, %{request: request}}
  end

  @impl true
  def websocket_handle({:text, "echo " <> stuff}, state) do
    {:reply, {:text, stuff}, state}
  end

  @impl true
  def websocket_handle({:text, "delayed-echo " <> stuff}, state) do
    :timer.send_after(20, {:delayed_echo, stuff})
    {:ok, state}
  end

  @impl true
  def websocket_handle({:text, "disconnect"}, _state) do
    {:stop, :disconnected}
  end

  @impl true
  def websocket_handle({:text, "count " <> n}, _state) do
    {n, ""} = Integer.parse(n)
    resp = for i <- 1..n, do: {:text, "coucou #{i}"}
    send(self(), :disconnect)
    {:reply, resp, :disconnected}
  end

  @impl true
  def websocket_handle({:text, "echostate"}, state) do
    {:reply, {:binary, :erlang.term_to_binary(state)}, state}
  end

  @impl true
  def websocket_handle(_stuff, state) do
    {:ok, state}
  end

  @impl true
  def websocket_info({:delayed_echo, msg}, state) do
    {:reply, {:text, msg}, state}
  end

  @impl true
  def websocket_info(:disconnect, state) do
    {:stop, state}
  end

  @impl true
  def websocket_info(_stuff, state) do
    {:ok, state}
  end
end
