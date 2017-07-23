defmodule BittorrentClient.Torrent.Data do
  @moduledoc """
  Torrent data defines struct which will represent relavent torrent worker information to be passed between processes
  """
  @derive {Poison.Encoder, except: [:pid, :tracker_info, :info_hash]}
  defstruct [:id,
             :pid,
             :file,
             :status,
             :info_hash,
             :peer_id,
             :port,
             :uploaded,
             :downloaded,
             :left,
             :compact,
             :no_peer_id,
             :event,
             :ip,
             :numwant,
             :key,
             :trackerid,
             :tracker_info
            ]

  def get_peers(data) do
    data |> Map.get(:tracker_info) |> Map.get(:peers)
  end
end
