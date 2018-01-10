defmodule BittorrentClient.Server.GenServerImpl do
  @moduledoc """
  BittorrentClient Server handles calls to add or remove new torrents to be handle,
  control to torrent handlers and database modules
  """
  @behaviour BittorrentClient.Server
  use GenServer
  alias BittorrentClient.Torrent.Supervisor, as: TorrentSupervisor
  alias BittorrentClient.Torrent.Data, as: TorrentData
  alias BittorrentClient.Logger.Factory, as: LoggerFactory
  alias BittorrentClient.Logger.JDLogger, as: JDLogger

  @logger LoggerFactory.create_logger(__MODULE__)
  @torrent_impl Application.get_env(:bittorrent_client, :torrent_impl)

  #-------------------------------------------------------------------------------
  # GenServer Callbacks
  #-------------------------------------------------------------------------------
  def start_link(db_dir, name) do
    JDLogger.info(@logger, "Starting BTC server for #{name}")
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

  def handle_call({:list_current_torrents}, _from, {db, serverName, torrents}) do
    {:reply, {:ok, torrents}, {db, serverName, torrents}}
  end

  def handle_call({:get_info_by_id, id}, _from, {db, serverName, torrents}) do
    if Map.has_key?(torrents, id) do
      {_, d} = Map.fetch(torrents, id)
      {:reply, {:ok, d}, {db, serverName, torrents}}
    else
      {:reply, {:error, {400, "Bad ID was given\n"}}, {db, serverName, torrents}}
    end
  end

  def handle_call({:add_new_torrent, torrentFile}, _from, {db, serverName, torrents}) do
    # TODO: add some salt
    id = torrentFile
    |> fn x -> :crypto.hash(:md5, x) end.()
    |> Base.encode32
    JDLogger.debug(@logger, "add_new_torrent Generated #{id}")
    if not Map.has_key?(torrents, id) do
      {status, _} = TorrentSupervisor.start_child({id, torrentFile})
      JDLogger.debug(@logger, "add_new_torrent Status: #{status}")
      case status do
        :error ->
          {:reply, {:error, "Failed to add torrent for #{torrentFile}\n"},
           {db, serverName, torrents}}
      	_ ->
          {check, data} = @torrent_impl.get_torrent_data(id)
          case check do
          	:error ->
              JDLogger.error(@logger, "Failed to add new torrent for #{torrentFile}")
              {:reply, {:error, "Failed to add torrent\n"}, {db, serverName, torrents}}
          	_ ->
              updated_torrents = Map.put(torrents, id, data)
              {:reply, {:ok, id}, {db, serverName, updated_torrents}}
          end
      end
    else
        {:reply, {:error, "That torrent already exist, Here's the ID: #{id}\n"},
         {db, serverName, torrents}}
    end
  end

  def handle_call({:delete_by_id, id}, _from, {db, serverName, torrents}) do
    JDLogger.debug(@logger, "Entered delete_by_id")
    if Map.has_key?(torrents, id) do
      torrent_data = Map.get(torrents, id)
      JDLogger.debug(@logger, "TorrentData: #{inspect torrent_data}")
      TorrentSupervisor.terminate_child(torrent_data.pid)
      torrents = Map.delete(torrents, id)
      {:reply, {:ok, id}, {db, serverName, torrents}}
    else
      {:reply, {:error, "Bad ID was given\n"}, {db, serverName, torrents}}
    end
  end

  def handle_call({:connect_to_tracker, id}, _from, {db, serverName, torrents}) do
    JDLogger.info(@logger, "Entered callback of connect_to_tracker")
    if Map.has_key?(torrents, id) do
      {status, msg} = @torrent_impl.connect_to_tracker(id)
      case status do
        :error ->
          {:reply, {:error, msg}, {db, serverName, torrents}}
        _ ->
          {_, new_info} = @torrent_impl.get_torrent_data(id)
          updated_torrents = Map.put(torrents, id, new_info)
          {:reply, {:ok, "#{id} has connected to tracker\n"}, {db, serverName, updated_torrents}}
      end
   else
      {:reply, {:error, "Bad ID was given\n"}, {db, serverName, torrents}}
    end
  end

  def handle_call({:update_by_id, id, data}, _from, {db, serverName, torrents}) do
    if Map.has_key?(torrents, id) do
      # TODO better way to do this
      torrents = Map.update!(torrents, id, fn _dataPoint -> data end)
      {:reply, {:ok, torrents}, {db, serverName, torrents}}
    else
      {:reply, {:error, "Bad ID was given"}, {db, serverName, torrents}}
    end
  end

 def handle_call({:update_status_by_id, id, status}, _from, {db, serverName, torrents}) do
    if Map.has_key?(torrents, id) do
      torrents = Map.update!(torrents, id,
        fn dataPoint -> %TorrentData{dataPoint | status: status} end)
      {:reply, {:ok, torrents}, {db, serverName, torrents}}
    else
      {:reply, {:error, "Bad ID was given"}, {db, serverName, torrents}}
    end
  end

  def handle_call({:delete_all}, _from, {db, serverName, torrents}) do
    torrents = Map.drop(torrents, Map.keys(torrents))
    {:reply, {:ok, torrents}, {db, serverName, torrents}}
  end

  def handle_call({:start_torrent, id}, _from, {db, serverName, torrents}) do
    if Map.has_key?(torrents, id) do
      {status, msg} = @torrent_impl.start_torrent(id)
      case status do
        :error ->
          {:reply, {:error, msg}, {db, serverName, torrents}}
        _ ->
          {_, new_info} = @torrent_impl.get_torrent_data(id)
          updated_torrents = Map.put(torrents, id, new_info)
          {:reply, {:ok, "#{id} has started"}, {db, serverName, updated_torrents}}
      end
    else
      {:reply, {:ok, {403, "bad input given"}}, {db, serverName, torrents}}
    end
  end

  def handle_cast({:start_torrent_async, id}, {db, serverName, torrents}) do
    if Map.has_key?(torrents, id) do
      {status, _} = @torrent_impl.start_torrent(id)
      case status do
        :error ->
          {:noreply, {db, serverName, torrents}}
        _ ->
          {_, new_info} = @torrent_impl.get_torrent_data(id)
          updated_torrents = Map.put(torrents, id, new_info)
          {:noreply, {db, serverName, updated_torrents}}
      end
    else
      {:noreply, {db, serverName, torrents}}
    end
  end

  def handle_cast({:connect_to_tracker_async, id}, {db, serverName, torrents}) do
    JDLogger.info(@logger, "Entered callback of connect_to_tracker_async")
    if Map.has_key?(torrents, id) do
      {status, _} = @torrent_impl.connect_to_tracker(id)
      case status do
        :error ->
          {:noreply, {db, serverName, torrents}}
        _ ->
          {_, new_info} = @torrent_impl.get_torrent_data(id)
          updated_torrents = Map.put(torrents, id, new_info)
          JDLogger.info(@logger, "connect_to_tracker_async #{id} completed")
          {:noreply, {db, serverName, updated_torrents}}
      end
    else
      JDLogger.error(@logger, "Bad id was given #{id}")
      {:noreply, {db, serverName, torrents}}
    end
  end

  #-------------------------------------------------------------------------------
  # Api Functions
  #-------------------------------------------------------------------------------
  def whereis(name) do
    :global.whereis_name({:btc_server, name})
  end

  def list_current_torrents(serverName) do
    JDLogger.info(@logger, "Entered list_current_torrents")
    GenServer.call(:global.whereis_name({:btc_server, serverName}),
      {:list_current_torrents})
  end

  def add_new_torrent(serverName, torrentFile) do
    JDLogger.info(@logger, "Entered add_new_torrent #{torrentFile}")
    GenServer.call(:global.whereis_name({:btc_server, serverName}),
      {:add_new_torrent, torrentFile})
  end

  def connect_torrent_to_tracker(serverName, id) do
    JDLogger.info(@logger, "Entered connect_torrent_to_tracker #{id}")
    GenServer.call(:global.whereis_name({:btc_server, serverName}),
      {:connect_to_tracker, id}, :infinity)
  end

  def connect_torrent_to_tracker_async(serverName, id) do
    JDLogger.info(@logger, "Entered connect_torrent_to_tracker #{id}")
    GenServer.cast(:global.whereis_name({:btc_server, serverName}),
      {:connect_to_tracker_async, id})
  end

  def start_torrent(serverName, id) do
    JDLogger.info(@logger, "Entered start_torrent #{id}")
    GenServer.call(:global.whereis_name({:btc_server, serverName}),
      {:start_torrent, id})
  end

  def start_torrent_async(serverName, id) do
    JDLogger.info(@logger, "Entered start_torrent #{id}")
    GenServer.cast(:global.whereis_name({:btc_server, serverName}),
      {:start_torrent_async, id})
  end

  def get_torrent_info_by_id(serverName, id) do
    JDLogger.info(@logger, "Entered get_torrent_info_by_id #{id}")
    GenServer.call(:global.whereis_name({:btc_server, serverName}),
      {:get_info_by_id, id})
  end

  def delete_torrent_by_id(serverName, id) do
    JDLogger.info(@logger, "Entered delete_torrent_by id #{id}")
    GenServer.call(:global.whereis_name({:btc_server, serverName}),
      {:delete_by_id, id})
  end

  def update_torrent_status_by_id(serverName, id, status) do
    JDLogger.info(@logger, "Entered update_torrent_status_by_id")
    GenServer.call(:global.whereis_name({:btc_server, serverName}),
      {:update_status_by_id, id, status})
  end

  def update_torrent_by_id(serverName, id, data) do
    JDLogger.info(@logger, "Entered update_torrent_by_id")
    GenServer.call(:global.whereis_name({:btc_server, serverName}),
     {:update_by_id, id, data})
  end

  def delete_all_torrents(serverName) do
    JDLogger.info(@logger, "Entered delete_all_torrents")
    GenServer.call(:global.whereis_name({:btc_server, serverName}),
      {:delete_all})
  end
end