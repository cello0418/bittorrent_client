defmodule BittorrentClient.Server.GenServerImpl do
  @moduledoc """
  BittorrentClient Server handles calls to add or remove new torrents to be handle,
  control to torrent handlers and database modules
  """
  @behaviour BittorrentClient.Server
  use GenServer
  require Logger
  alias BittorrentClient.Torrent.Supervisor, as: TorrentSupervisor
  alias BittorrentClient.Torrent.Data, as: TorrentData
  @torrent_impl Application.get_env(:bittorrent_client, :torrent_impl)

  # -------------------------------------------------------------------------------
  # GenServer Callbacks
  # -------------------------------------------------------------------------------
  def start_link(db_dir, name) do
    Logger.info("Starting BTC server for #{name}")

    GenServer.start_link(
      __MODULE__,
      {db_dir, name, Map.new()},
      name: {:global, {:btc_server, name}}
    )
  end

  def init({db_dir, name, torrent_map}) do
    # load from database into table
    {:ok, {db_dir, name, torrent_map}}
  end

  def handle_call({:list_current_torrents}, _from, {db, server_name, torrents}) do
    {:reply, {:ok, torrents}, {db, server_name, torrents}}
  end

  def handle_call({:get_info_by_id, id}, _from, {db, server_name, torrents}) do
    if Map.has_key?(torrents, id) do
      {_, d} = Map.fetch(torrents, id)
      {:reply, {:ok, d}, {db, server_name, torrents}}
    else
      {:reply, {:error, {403, "Bad ID was given\n"}},
       {db, server_name, torrents}}
    end
  end

  def handle_call(
        {:add_new_torrent, torrentFile},
        _from,
        {db, server_name, torrents}
      ) do
    # TODO: add some salt
    id =
      torrentFile
      |> (fn x -> :crypto.hash(:md5, x) end).()
      |> Base.encode32()

    Logger.debug(fn -> "add_new_torrent Generated #{id}" end)

    if not Map.has_key?(torrents, id) do
      {status, secondary} = TorrentSupervisor.start_child({id, torrentFile})
      Logger.debug(fn -> "add_new_torrent Status: #{status}" end)

      case status do
        :error ->
          Logger.error(fn ->
            "Failed to add torrent for #{torrentFile}: #{inspect(secondary)}\n"
          end)

          {:reply,
           {:error,
            {403,
             "Failed to add torrent for #{torrentFile}: #{inspect(secondary)}\n"}},
           {db, server_name, torrents}}

        _ ->
          {check, data} = @torrent_impl.get_torrent_data(id)

          case check do
            :error ->
              Logger.error("Failed to add new torrent for #{torrentFile}")

              {:reply,
               {:error,
                {500,
                 "Failed to add torrent for #{torrentFile}: could not retrive info from torrent layer\n"}},
               {db, server_name, torrents}}

            _ ->
              updated_torrents = Map.put(torrents, id, data)

              {:reply, {:ok, %{"torrent id" => id}},
               {db, server_name, updated_torrents}}
          end
      end
    else
      {:reply,
       {:error, {403, "That torrent already exist, Here's the ID: #{id}\n"}},
       {db, server_name, torrents}}
    end
  end

  def handle_call({:delete_by_id, id}, _from, {db, server_name, torrents}) do
    Logger.debug(fn -> "Entered delete_by_id" end)

    if Map.has_key?(torrents, id) do
      torrent_data = Map.get(torrents, id)
      data = Map.fetch!(torrent_data, "data")

      Logger.debug(fn -> "TorrentData: #{inspect(torrent_data)}" end)
      {stop_status, ret} = TorrentSupervisor.terminate_child(id)

      Logger.debug(fn -> "TorrentSupervisor.stop_child ret: #{inspect(ret)}" end)

      case stop_status do
        :error ->
          {:reply,
           {:error,
            {500, "could not delete #{id}", {db, server_name, torrents}}}}

        _ ->
          torrents = Map.delete(torrents, id)

          {:reply, {:ok, %{"torrent id" => id, "torrent data" => data}},
           {db, server_name, torrents}}
      end
    else
      Logger.debug(fn -> "Bad ID was given to delete" end)

      {:reply, {:error, {403, "Bad ID was given\n"}},
       {db, server_name, torrents}}
    end
  end

  def handle_call({:connect_to_tracker, id}, _from, {db, server_name, torrents}) do
    Logger.info("Entered callback of connect_to_tracker")

    if Map.has_key?(torrents, id) do
      {status, msg} = @torrent_impl.connect_to_tracker(id)

      case status do
        :error ->
          {:reply, {:error, {500, msg}}, {db, server_name, torrents}}

        _ ->
          {_, new_info} = @torrent_impl.get_torrent_data(id)
          updated_torrents = Map.put(torrents, id, new_info)

          {:reply, {:ok, "#{id} has connected to tracker\n"},
           {db, server_name, updated_torrents}}
      end
    else
      {:reply, {:error, "Bad ID was given\n"}, {db, server_name, torrents}}
    end
  end

  def handle_call({:update_by_id, id, data}, _from, {db, server_name, torrents}) do
    if Map.has_key?(torrents, id) do
      # TODO better way to do this
      torrents = Map.update!(torrents, id, fn _dataPoint -> data end)
      {:reply, {:ok, torrents}, {db, server_name, torrents}}
    else
      {:reply, {:error, {403, "Bad ID was given"}}, {db, server_name, torrents}}
    end
  end

  def handle_call(
        {:update_status_by_id, id, status},
        _from,
        {db, server_name, torrents}
      ) do
    if Map.has_key?(torrents, id) do
      torrent_info = Map.get(torrents, id)
      torrent_data = Map.get(torrent_info, "data")
      new_torrent_data = %TorrentData{torrent_data | status: status}
      new_torrent_info = Map.put(torrent_info, "data", new_torrent_data)
      updated_torrents = Map.put(torrents, id, new_torrent_info)
      {:reply, {:ok, updated_torrents}, {db, server_name, updated_torrents}}
    else
      {:reply, {:error, {403, "Bad ID was given"}}, {db, server_name, torrents}}
    end
  end

  def handle_call({:delete_all}, _from, {db, server_name, torrents}) do
    status_table =
      Enum.reduce(Map.keys(torrents), %{}, fn key, acc ->
        {status, _data} = TorrentSupervisor.terminate_child(key)

        case status do
          :error ->
            Logger.error("Could not kill #{key}")
            acc

          _ ->
            Map.put(acc, key, status)
        end
      end)

    torrents = Map.drop(torrents, Map.keys(status_table))

    case Map.equal?(torrents, %{}) do
      true ->
        {:reply, {:ok, torrents}, {db, server_name, torrents}}

      false ->
        {:reply, {:error, {500, torrents}}, {db, server_name, torrents}}
    end
  end

  def handle_call({:start_torrent, id}, _from, {db, server_name, torrents}) do
    if Map.has_key?(torrents, id) do
      case @torrent_impl.start_torrent(id) do
        {:error, msg} ->
          {:reply, {:error, msg}, {db, server_name, torrents}}

        _ ->
          {_, new_info} = @torrent_impl.get_torrent_data(id)
          updated_torrents = Map.put(torrents, id, new_info)

          {:reply, {:ok, "#{id} has started"},
           {db, server_name, updated_torrents}}
      end
    else
      {:reply, {:ok, {403, "bad input given"}}, {db, server_name, torrents}}
    end
  end

  def handle_cast({:start_torrent_async, id}, {db, server_name, torrents}) do
    if Map.has_key?(torrents, id) do
      case @torrent_impl.start_torrent(id) do
        {:error, _} ->
          {:noreply, {db, server_name, torrents}}

        {:ok, _msg, _connected} ->
          {_, new_info} = @torrent_impl.get_torrent_data(id)
          updated_torrents = Map.put(torrents, id, new_info)
          {:noreply, {db, server_name, updated_torrents}}
      end
    else
      {:noreply, {db, server_name, torrents}}
    end
  end

  def handle_cast({:connect_to_tracker_async, id}, {db, server_name, torrents}) do
    Logger.info("Entered callback of connect_to_tracker_async")

    if Map.has_key?(torrents, id) do
      {status, _} = @torrent_impl.connect_to_tracker(id)

      case status do
        :error ->
          {:noreply, {db, server_name, torrents}}

        _ ->
          {_, new_info} = @torrent_impl.get_torrent_data(id)
          updated_torrents = Map.put(torrents, id, new_info)
          Logger.info("connect_to_tracker_async #{id} completed")
          {:noreply, {db, server_name, updated_torrents}}
      end
    else
      Logger.error("Bad id was given #{id}")
      {:noreply, {db, server_name, torrents}}
    end
  end

  # -------------------------------------------------------------------------------
  # Api Functions
  # -------------------------------------------------------------------------------
  def whereis(name) do
    :global.whereis_name({:btc_server, name})
  end

  def list_current_torrents(server_name) do
    Logger.info("Entered list_current_torrents")

    GenServer.call(
      :global.whereis_name({:btc_server, server_name}),
      {:list_current_torrents}
    )
  end

  def add_new_torrent(server_name, torrentFile) do
    Logger.info("Entered add_new_torrent #{torrentFile}")

    GenServer.call(
      :global.whereis_name({:btc_server, server_name}),
      {:add_new_torrent, torrentFile}
    )
  end

  def connect_torrent_to_tracker(server_name, id) do
    Logger.info("Entered connect_torrent_to_tracker #{id}")

    GenServer.call(
      :global.whereis_name({:btc_server, server_name}),
      {:connect_to_tracker, id},
      :infinity
    )
  end

  def connect_torrent_to_tracker_async(server_name, id) do
    Logger.info("Entered connect_torrent_to_tracker #{id}")

    GenServer.cast(
      :global.whereis_name({:btc_server, server_name}),
      {:connect_to_tracker_async, id}
    )
  end

  def start_torrent(server_name, id) do
    Logger.info("Entered start_torrent #{id}")

    GenServer.call(
      :global.whereis_name({:btc_server, server_name}),
      {:start_torrent, id}
    )
  end

  def start_torrent_async(server_name, id) do
    Logger.info("Entered start_torrent #{id}")

    GenServer.cast(
      :global.whereis_name({:btc_server, server_name}),
      {:start_torrent_async, id}
    )
  end

  def get_torrent_info_by_id(server_name, id) do
    Logger.info("Entered get_torrent_info_by_id #{id}")

    GenServer.call(
      :global.whereis_name({:btc_server, server_name}),
      {:get_info_by_id, id}
    )
  end

  def delete_torrent_by_id(server_name, id) do
    Logger.info("Entered delete_torrent_by id #{id}")

    GenServer.call(
      :global.whereis_name({:btc_server, server_name}),
      {:delete_by_id, id}
    )
  end

  def update_torrent_status_by_id(server_name, id, status) do
    Logger.info("Entered update_torrent_status_by_id")

    GenServer.call(
      :global.whereis_name({:btc_server, server_name}),
      {:update_status_by_id, id, status}
    )
  end

  def update_torrent_by_id(server_name, id, data) do
    Logger.info("Entered update_torrent_by_id")

    GenServer.call(
      :global.whereis_name({:btc_server, server_name}),
      {:update_by_id, id, data}
    )
  end

  def delete_all_torrents(server_name) do
    Logger.info("Entered delete_all_torrents")

    GenServer.call(
      :global.whereis_name({:btc_server, server_name}),
      {:delete_all}
    )
  end
end
