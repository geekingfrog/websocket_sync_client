defmodule WebsocketSyncClientTest do
  use ExUnit.Case
  doctest WebsocketSyncClient

  setup do
    {:ok, {ref, url}} = WebsocketSyncClient.TestServer.start(self())
    on_exit(fn -> WebsocketSyncClient.TestServer.shutdown(ref) end)
    %{ref: ref, url: url}
  end

  test "send and receive frames", %{url: url} do
    {:ok, client} = WebsocketSyncClient.connect(url)
    :ok = WebsocketSyncClient.send_message(client, {:text, "echo blahblah"})
    {:ok, {:text, "blahblah"}} = WebsocketSyncClient.recv(client)
  end

  test "receive with timeout", %{url: url} do
    {:ok, client} = WebsocketSyncClient.connect(url)
    {:error, :timeout} = WebsocketSyncClient.recv(client, timeout: 10)
  end

  test "honor default timeout", %{url: url} do
    {:ok, client} = WebsocketSyncClient.connect(url, default_timeout: 5)
    :ok = WebsocketSyncClient.send_message(client, {:text, "delayed-echo late"})
    {:error, :timeout} = WebsocketSyncClient.recv(client)
    {:ok, {:text, "late"}} = WebsocketSyncClient.recv(client, timeout: 20)
  end

  test "returns :disconnected if client dies while waiting for message", %{url: url} do
    {:ok, client} = WebsocketSyncClient.connect(url)

    spawn_link(fn ->
      :timer.sleep(1)
      Process.exit(client.pid, :kill)
    end)

    {:error, :disconnected} = WebsocketSyncClient.recv(client, timeout: 10)
  end

  test "receive a message sent later", %{url: url} do
    {:ok, client} = WebsocketSyncClient.connect(url)
    :ok = WebsocketSyncClient.send_message(client, {:text, "delayed-echo late"})
    {:ok, {:text, "late"}} = WebsocketSyncClient.recv(client)
  end

  test "messages arriving late are buffered", %{url: url} do
    {:ok, client} = WebsocketSyncClient.connect(url)
    {:error, :timeout} = WebsocketSyncClient.recv(client, timeout: 10)
    :ok = WebsocketSyncClient.send_message(client, {:text, "echo late"})
    {:ok, {:text, "late"}} = WebsocketSyncClient.recv(client, timeout: 40)
  end

  test "handle disconnection", %{url: url} do
    {:ok, client} = WebsocketSyncClient.connect(url)
    :ok = WebsocketSyncClient.send_message(client, {:text, "count 2"})
    {:ok, {:text, "coucou 1"}} = WebsocketSyncClient.recv(client)
    {:ok, {:text, "coucou 2"}} = WebsocketSyncClient.recv(client)
    {:error, :disconnected} = WebsocketSyncClient.recv(client, timeout: 10)

    {:error, :disconnected} =
      WebsocketSyncClient.send_message(client, {:text, "echo new message"})

    {:error, :disconnected} = WebsocketSyncClient.recv(client, timeout: 10)
    refute WebsocketSyncClient.connected?(client)
  end

  test "manual disconnect", %{url: url} do
    {:ok, client} = WebsocketSyncClient.connect(url)
    :ok = WebsocketSyncClient.send_message(client, {:text, "echo hello"})
    :ok = WebsocketSyncClient.disconnect(client)
    {:error, :disconnected} = WebsocketSyncClient.recv(client)
    refute WebsocketSyncClient.connected?(client)
  end

  test "can still get buffered messages after server disconnects client", %{url: url} do
    {:ok, client} = WebsocketSyncClient.connect(url)
    :ok = WebsocketSyncClient.send_message(client, {:text, "echo hello"})
    :ok = WebsocketSyncClient.send_message(client, {:text, "disconnect"})
    {:ok, {:text, "hello"}} = WebsocketSyncClient.recv(client)
    {:error, :disconnected} = WebsocketSyncClient.recv(client)
  end

  test "pass custom headers", %{url: url} do
    {:ok, client} =
      WebsocketSyncClient.connect(url,
        connection_options: [
          extra_headers: [
            {
              "Sec-WebSocket-Protocol",
              "custom-proto"
            }
          ]
        ]
      )

    :ok = WebsocketSyncClient.send_message(client, {:text, "echostate"})
    {:ok, {:binary, conn_state}} = WebsocketSyncClient.recv(client)
    state = :erlang.binary_to_term(conn_state)
    assert %{"sec-websocket-protocol" => "custom-proto"} = state[:request][:headers]
    WebsocketSyncClient.disconnect(client)
  end
end
