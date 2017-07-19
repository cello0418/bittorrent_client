defmodule BittorrentClient.Torrent.Peer.Data do
  @moduledoc """
  Peer data struct to contain information about peer connection
  """
  @derive {Poison.Encoder, except: [:torrent_id, :socket, :metainfo, :timer, :state]}
  defstruct [:torrent_id,
             :peer_id,
             :filename,
             :peer_ip,
             :peer_port,
             :socket,
             :interval,
             :info_hash,
             :am_choking,
             :am_interested,
             :peer_choking,
             :peer_interested,
             :handshake_check,
             :metainfo,
             :timer,
             :state,
             :name
            ]
end
