defmodule BittorrentClient.Web.Supervisor do
  @moduledoc """
  WebSupervisor supervises the Web module of BittorrentClient
  """
  require Logger
  alias Plug.Adapters.Cowboy, as: Cowboy
  alias BittorrentClient.Web.Router, as: Router

  def start_link do
    Logger.info fn -> "Starting Web Supervisor" end
    children = [
      Cowboy.child_spec(:http, Router, [], [port: 8080])
    ]

    opts = [strategy: :one_for_one, name: __MODULE__]
    Supervisor.start_link(children, opts)
  end
end