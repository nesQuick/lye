defmodule Lye.Connection do

  require Logger

  @behaviour :ranch_protocol

  alias Lye.Parser

  def start_link(ref, socket, transport, opts) do
    pid = spawn_link(__MODULE__, :init, [ref, socket, transport, opts])
    {:ok, pid}
  end

  def init(ref, socket, transport, _opts \\ []) do
    :ok = :ranch.accept_ack(ref)
    :ok = Parser.handshake(fn(len) -> transport.recv(socket, len, 10) end)
    {:ok, events} = GenEvent.start_link([])

    GenEvent.add_handler(events, Lye.Frames.Headers, [4096])
    GenEvent.add_handler(events, Lye.Frames.Priority, [])
    GenEvent.add_handler(events, Lye.Frames.Settings, [])

    {:ok, sender} = Task.start_link(__MODULE__, :send_loop, [socket, transport])
    {:ok, receiver} = Task.start_link(__MODULE__, :recv_loop, [socket, transport, events, self()])

    # TODO: replace with GenServer
    loop(%Lye.Connection.Settings{}, sender)
  end

  def loop(settings, sender) do
    receive do
      {:frame, frame} -> send sender, {:frame, frame}
    end
    loop(settings, sender)
  end

  # +-----------------------------------------------+
  # |                 Length (24)                   |
  # +---------------+---------------+---------------+
  # |   Type (8)    |   Flags (8)   |
  # +-+-------------+---------------+-------------------------------+
  # |R|                 Stream Identifier (31)                      |
  # +=+=============================================================+
  # |                   Frame Payload (0...)                      ...
  # +---------------------------------------------------------------+
  # Figure 1: Frame Layout
  def send_frame(pid, {type, sid, flags, body}) do
    send pid, {:frame, << byte_size(body)::24, type::8, flags::8, 0::1, sid::31, body::binary >> }
  end

  def recv_loop(socket, transport, event_bus, connection) do
    {:ok, type, flags, sid, body} = Parser.parse_frame(fn(len) -> transport.recv(socket, len, :infinity) end)

    GenEvent.notify(event_bus, {:frame, type, sid, flags, body, connection})
    # case transport.recv(socket, 0, 5000) do
    #   {:ok, data} ->
    #     transport.send(socket, data)
    #     recv_loop(socket, transport);
    #   _ ->
    #     :ok = transport.close(socket)
    # end
    recv_loop(socket, transport, event_bus, connection)
  end

  def send_loop(socket, transport) do
    receive do
      {:frame, frame} ->
        transport.send(socket, frame)
        send_loop(socket, transport)
      # {:world, msg} -> "won't match"
    end
  end
end
