using Sockets
using JSON

################################################################################
### types and constants

const OBUFSIZE = 1920000          # DAC samples

mutable struct GroguDaemon
  const client::Any               # opaque client handle
  const csock::UDPSocket          # UDP command socket
  const dsock::UDPSocket          # UDP data socket
  const baseport::Int             # UDP base port number
  const ipaddr::IPAddr            # IP address to bind to
  const obuf::Vector{Float32}     # output signal buffer (DAC)
  chost::Union{IPAddr,Nothing}    # IP address for peer sending commands
  cport::Int                      # peer's command port
  dhost::Union{IPAddr,Nothing}    # IP address to stream data to
  dport::Int                      # port number to stream data to
end

struct GroguDataHeader
  timestamp::UInt64
  seqno::UInt32
  nsamples::UInt16
  nchannels::UInt16
end

################################################################################
### GroguDaemon methods

"""
    GroguDaemon(client, baseport)
    GroguDaemon(client, baseport, ipaddr)

Create Grogu daemon to run on UDP ports `baseport` and `baseport+1`. If IP address is
not specified, daemon only binds to localhost. The `client` must support the
protocol interface methods (see `Node` for details).
"""
function GroguDaemon(client, baseport::Int, ipaddr::IPAddr=Sockets.localhost)
  GroguDaemon(client, UDPSocket(), UDPSocket(), baseport, ipaddr, Float32[], nothing, 0, nothing, 0)
end

"""
    run(conn::GroguDaemon)

Start Grogu daemon.
"""
function Base.run(conn::GroguDaemon)
  bind(conn.csock, conn.ipaddr, conn.baseport) || error("Unable to bind to $(conn.ipaddr):$(conn.baseport)")
  bind(conn.dsock, conn.ipaddr, conn.baseport+1) || error("Unable to bind to $(conn.ipaddr):$(conn.baseport+1)")
  @async begin
    try
      while isopen(conn.csock)
        from, bytes = recvfrom(conn.csock)
        s = strip(String(bytes))
        length(s) == 0 && continue
        try
          json = JSON.parse(s)
          _command(conn, from, json)
        catch ex
          @warn "Bad command: $s" exception=(ex, catch_backtrace())
        end
      end
    catch ex
      ex isa EOFError || @warn "$ex"
      close(conn.csock)
      close(conn.dsock)
    end
  end
  @async begin
    try
      while isopen(conn.dsock)
        _odata(conn, recv(conn.dsock))
      end
    catch ex
      ex isa EOFError || @warn "$ex"
      close(conn.csock)
      close(conn.dsock)
    end
  end
end

"""
    close(conn::GroguDaemon)

Close grogu daemon.
"""
function Base.close(conn::GroguDaemon)
  close(conn.csock)
  close(conn.dsock)
  nothing
end

"""
    stream(conn::GroguDaemon, t, seqno, data)

Stream data over connection. `t` is the time (in µs) of the first sample in the
`data` buffer, and `seqno` is the frame number in the data stream.
"""
function stream(conn::GroguDaemon, t, seqno, data)
  if conn.dport > 0
    hdr = GroguDataHeader(hton(UInt64(t)), hton(UInt32(seqno)), hton(UInt16(size(data,1))), hton(UInt16(size(data,2))))
    bytes = vcat(reinterpret(UInt8, [hdr]), reinterpret(UInt8, hton.(vec(data'))))
    send(conn.dsock, conn.dhost, conn.dport, bytes)
  end
end

"""
    event(conn::GroguDaemon, t, ev, id)

Send event `ev` at time `t`  (in µs) with optional `id` over connection.
"""
function event(conn::GroguDaemon, t, ev, id)
  conn.chost === nothing && return
  ntf = Dict{String,Any}()
  ntf["event"] = ev
  ntf["time"] = t
  id === nothing || (ntf["id"] = id)
  @debug JSON.json(ntf)
  send(conn.csock, conn.chost, conn.cport, Vector{UInt8}(JSON.json(ntf) * "\n"))
end

# called when we receive a command
function _command(conn::GroguDaemon, from, cmd)
  @debug cmd
  action = cmd["action"]
  if action == "version"
    ver = pkgversion(@__MODULE__)
    rsp = Dict{String,Any}()
    rsp["name"] = "VirtualAcousticOcean"
    rsp["version"] = "$ver"
    rsp["protocol"] = "0.1.0"
    "id" ∈ keys(cmd) && (rsp["id"] = cmd["id"])
    @debug JSON.json(rsp)
    send(conn.csock, from.host, from.port, JSON.json(rsp) * "\n")
  elseif action == "ireset"
    set!(conn.client, :iseqno, 0)
  elseif action == "istart"
    conn.dhost = from.host
    conn.dport = cmd["port"]
  elseif action == "istop"
    conn.dport = 0
    conn.dhost = nothing
  elseif action == "oclear"
    empty!(conn.obuf)
  elseif action == "ostart"
    conn.chost = from.host
    conn.cport = from.port
    och = get(conn.client, :ochannels)
    x = reshape(copy(conn.obuf), och, :)'
    empty!(conn.obuf)
    transmit(conn.client, get(cmd, "time", 0), x, get(cmd, "id", nothing))
  elseif action == "ostop"
    # do nothing, as simulator does not support stopping output half way through
  elseif action == "get"
    k = Symbol(cmd["param"])
    v = k === :obufsize ? OBUFSIZE : get(conn.client, k)
    if v !== nothing
      rsp = Dict{String,Any}()
      rsp["param"] = cmd["param"]
      rsp["value"] = v
      "id" ∈ keys(cmd) && (rsp["id"] = cmd["id"])
      @debug JSON.json(rsp)
      send(conn.csock, from.host, from.port, JSON.json(rsp) * "\n")
    end
  elseif action == "set"
    set!(conn.client, Symbol(cmd["param"]), cmd["value"])
  elseif action == "quit"
    # don't quit
  end
end

# called when we receive data
function _odata(conn::GroguDaemon, data)
  try
    # skip 16 byte header and convert the rest to floats
    append!(conn.obuf, ntoh.(reinterpret(Float32, @view data[17:end])))
  catch ex
    @warn ex
  end
end
