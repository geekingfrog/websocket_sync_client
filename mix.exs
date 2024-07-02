defmodule WebsocketSyncClient.MixProject do
  use Mix.Project

  def project do
    [
      app: :websocket_sync_client,
      version: "0.1.0",
      description: "A synchronous library for websocket operations",
      elixir: "~> 1.12",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: false,
      package: package(),
      deps: deps(),

      # Docs
      source_url: "https://github.com/geekingfrog/websocket_sync_client",
      homepage_url: "https://github.com/geekingfrog/websocket_sync_client",
      docs: [
        # main: "websocket_sync_client",
        extras: ["README.md"]
      ]
    ]
  end

  def application do
    []
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {
        # the version currently in hex.pm is 0.4.3, which doesn't have a change regarding correct
        # handling of stack traces, so grab the commit at master where it's fixed
        :websockex,
        git: "https://github.com/Azolo/websockex.git",
        tag: "4a94f6870528f45d64cdd47bd4374faf52528466"
      },
      {:cowboy, "~> 2.9", only: :test},
      {:plug_cowboy, "~> 2.5", only: :test},
      {:plug, "~> 1.4", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.1", only: [:dev], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package() do
    %{
      licenses: ["MIT"],
      maintainers: ["Greg Charvet"],
      links: %{"GitHub" => "https://github.com/geekingfrog/websocket_sync_client"}
    }
  end
end
