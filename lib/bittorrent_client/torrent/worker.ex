defmodule BittorrentClient.Torrent.Worker do
  @moduledoc """
  TorrentWorker handles on particular torrent magnet, manages the connections allowed and other settings.
  """
  use GenServer
  require HTTPoison
  require Logger
  alias BittorrentClient.Torrent.Data, as: TorrentData
  alias BittorrentClient.Torrent.TrackerInfo, as: TrackerInfo
  alias BittorrentClient.Torrent.Peer.Supervisor, as: PeerSupervisor

  def start_link({id, filename}) do
    Logger.info fn -> "Starting Torrent worker for #{filename}" end
    torrent_metadata = filename
    |> File.read!()
    |> Bento.torrent!()
    Logger.debug fn -> "Metadata: #{inspect torrent_metadata}" end
    torrent_data = create_initial_data(id, filename, torrent_metadata)
    Logger.debug fn -> "Data: #{inspect torrent_data}" end
    GenServer.start_link(
      __MODULE__,
      {torrent_metadata, torrent_data},
      name: {:global, {:btc_torrentworker, id}}
    )
  end

  def init(torrent_metadata, torrent_data) do
    {:ok, {torrent_metadata, torrent_data}}
  end

  def whereis(id) do
    :global.whereis_name({:btc_torrentworker, id})
  end

  def get_torrent_data(id) do
    Logger.info fn -> "Getting torrent data for #{id}" end
    GenServer.call(:global.whereis_name({:btc_torrentworker, id}),
      {:get_data})
  end

  def connect_to_tracker(id) do
    Logger.debug fn -> "Torrent #{id} attempting to connect tracker" end
    GenServer.call(:global.whereis_name({:btc_torrentworker, id}),
      {:connect_to_tracker}, :infinity)
  end

  def connect_to_tracker_async(id) do
    Logger.debug fn -> "Torrent #{id} attempting to connect tracker" end
    GenServer.cast(:global.whereis_name({:btc_torrentworker, id}),
      {:connect_to_tracker_async})
  end

  def get_peers(id) do
    Logger.debug fn -> "Getting peer list of #{id}" end
    GenServer.call(:global.whereis_name({:btc_torrentworker, id}),
      {:get_peers})
  end

  def start_single_peer(id, {ip, port}) do
    Logger.debug fn -> "Starting a single peer for #{id} with #{inspect ip}:#{inspect port}" end
    GenServer.call(:global.whereis_name({:btc_torrentworker, id}),
      {:start_single_peer, {ip, port}})
  end

  def get_next_piece_index(id) do
    Logger.debug fn -> "#{id} is retrieving next_piece_index" end
    GenServer.call(:global.whereis_name({:btc_torrentworker, id}),
      {:get_next_piece_index})
  end

  def mark_piece_index_done(id, index) do
    Logger.debug fn -> "#{id}'s peerworker has marked #{index} as done!" end
    GenServer.call(:global.whereis_name({:btc_torrentworker, id}),
      {:mark_piece_index_done, index})
  end

  def handle_call({:get_data}, _from, {metadata, data}) do
    ret = %{
      "metadata" => metadata,
      "data" => data
    }
    {:reply, {:ok, ret}, {metadata, data}}
  end

  def handle_call({:connect_to_tracker}, _from, {metadata, data}) do
    connect_to_tracker_helper({metadata, data})
  end

  def handle_call({:get_peers}, _from, {metadata, data}) do
    {:reply, {:ok, TorrentData.get_peers(data)}, {metadata, data}}
  end

  def handle_call({:start_single_peer, {ip, port}}, _from, {metadata, data}) do
    {s, peer_data} = PeerSupervisor.start_child({
      metadata,
      Map.get(data, :id),
      Map.get(data, :info_hash),
      Map.get(data, :filename),
      Application.get_env(:bittorrent_client, :trackerid),
      data |> Map.get(:tracker_info) |> Map.get(:interval),
      ip,
      port})
    case s do
      :error ->
        Logger.error fn -> "#{inspect peer_data}" end
        {:reply, {:error, "Failed to start peer connection for #{inspect ip}:#{inspect port}: #{inspect peer_data}"},  {metadata, data}}
      :ok -> {:reply, {:ok, peer_data}, {metadata, data}}
    end
  end

  def handle_call({:get_next_piece_index}, _from, {metadata, data}) do
     ret_piece_index = data.next_piece_index
     new_piece_index = ret_piece_index + 1 # +1 for now, next logic will be diff
     # The way the table will update will change with dying peers and etc.
     new_piece_table = Map.merge(data.pieces, %{ret_piece_index => "started"})
     {:reply, {:ok, ret_piece_index},
     {metadata, %TorrentData{ data | pieces: new_piece_table, next_piece_index: new_piece_index}}}
  end

  def handle_call({:mark_piece_index_done, index}, _from, {metadata, data}) do
    piece_table = data.piece
    if Map.has_key?(piece_table, index) do
      new_piece_table = %{piece_table | index => "done"}
      {:reply, {:ok, index}, {metadata, %TorrentData{data | pieces: new_piece_table}}}
    else
      {:reply, {:error, "invalid index given: #{index}"}, {metadata, data}}
    end
  end

  def handle_cast({:connect_to_tracker_async}, {metadata, data}) do
    {_, _, {new_metadata, new_data}} = connect_to_tracker_helper({metadata, data})
    {:no_reply, {new_metadata, new_data}}
  end

  # UTILITY
  defp create_tracker_request(url, params) do
   	url_params = for key <- Map.keys(params), do: "#{key}" <> "=" <> "#{Map.get(params, key)}"
    URI.encode(url <> "?" <> Enum.join(url_params, "&"))
  end

  defp parse_tracker_response(body) do
    {status, track_resp} = Bento.decode(body)
    Logger.debug fn -> "tracker response decode -> #{inspect track_resp}" end
    case status do
      :error -> {:error, %TrackerInfo{}}
      _ ->
        {:ok, %TrackerInfo{
            interval: track_resp["interval"],
            peers: track_resp["peers"],
            peers6: track_resp["peers6"]
         }}
    end
  end

  defp connect_to_tracker_helper({metadata, data}) do
    # These either dont relate to tracker req or are not implemented yet
    Logger.debug fn -> "connect_to_tracker_helper" end
    unwanted_params = [:status,
                       :id,
                       :pid,
                       :file,
                       :trackerid,
                       :tracker_info,
                       :key,
                       :ip,
                       :pieces,
                       :no_peer_id,
                       :__struct__]
    params = List.foldl(unwanted_params, data,
      fn elem, acc -> Map.delete(acc, elem) end)
    url = create_tracker_request(metadata.announce, params)
    # connect to tracker, respond based on what the http response is
    {status, resp} = HTTPoison.get(url, [],
      [{:timeout, 10_000}, {:recv_timeout, 10_000}])
    Logger.debug fn -> "Response from tracker: #{inspect resp}" end
    case status do
      :error ->
        Logger.error fn -> "Failed to fetch #{url}" end
        Logger.error fn -> "Resp: #{inspect resp}" end
        {:reply, {:error, {504, "failed to fetch #{url}"}}, {metadata, data}}
      _ ->
        # response returns a text/plain object
        {status, tracker_info} = parse_tracker_response(resp.body)
        case status do
          :error -> {:reply, {:error, {500, "Failed to connect to tracker"}},
                    {metadata, Map.put(data, :status, "failed")}}
          _ ->
          # update data
            updated_data =  data
            |> Map.put(:tracker_info, tracker_info)
            |> Map.put(:status, "started")
            {:reply, {:ok, {metadata, updated_data}}, {metadata, updated_data}}
        end
    end
  end

  defp create_initial_data(id, file, metadata) do
    {check, info} = metadata.info
    |> Map.from_struct()
    |> Map.delete(:md5sum)
    |> Map.delete(:private)
    |> Bento.encode()
    if check == :error do
      Logger.debug fn -> "Failed to extract info from metadata" end
      raise "Failed to extract info from metadata"
    else
      hash = :crypto.hash(:sha, info)
      %TorrentData{
        id: id,
        pid: self(),
        file: file,
        event: "started",
        peer_id: Application.fetch_env!(:bittorrent_client, :peer_id),
        compact: Application.fetch_env!(:bittorrent_client, :compact),
        port: Application.fetch_env!(:bittorrent_client, :port),
        uploaded: 0,
        downloaded: 0,
        left: metadata.info.length,
        info_hash: hash,
        no_peer_id: Application.fetch_env!(:bittorrent_client, :no_peer_id),
        ip: Application.fetch_env!(:bittorrent_client, :ip),
        numwant: Application.fetch_env!(:bittorrent_client, :numwant),
        key: Application.fetch_env!(:bittorrent_client, :key),
        trackerid: Application.fetch_env!(:bittorrent_client, :trackerid),
        tracker_info: %TrackerInfo{},
        # empty for now, will keep track of what this client will have
        # for uploading
        # OR add a key for each possible piece marking as "NOT STARTED"
        pieces: %{},
        # This would be none zero if continueing, for now 0
        next_piece_index: 0,
        connected_peers: []
      }
    end
  end

  def parse_peers_binary(binary) do
    parse_peers_binary(binary, [])
  end

  def parse_peers_binary(<<a, b, c, d, fp, sp, rest::bytes>>, acc) do
    port = fp * 256 + sp
    parse_peers_binary(rest, [{{a, b, c, d}, port} | acc])
  end

  def parse_peers_binary(_, acc) do
    acc
  end

  def get_peer_list(id) do
    {_, tab} = BittorrentClient.Torrent.Worker.get_peers(id)
    parse_peers_binary(tab)
  end

  def scratch(id) do
    peer_list = BittorrentClient.Torrent.Worker.get_peer_list(id)
    Enum.map(peer_list, fn tp -> start_single_peer(id, tp) end)
  end
end
