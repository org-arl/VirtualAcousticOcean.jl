using Sockets
using JSON

################################################################################
### types and constants

const OBUFSIZE = 1920000        # DAC samples

struct GroguDaemon{T}
  client::T                     # opaque client handle
  csock::UDPSocket              # UDP command socket
  dsock::UDPSocket              # UDP data socket
  obuf::Vector{Float32}         # output signal buffer (DAC)
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

Start Grogu daemon on UDP ports `baseport` and `baseport+1`. If IP address is
not specified, daemon only binds to localhost. The `client` must support the
protocol interface methods (see `Node` for details).
"""
function GroguDaemon(client, baseport::Int, ipaddr::IPAddr=Sockets.localhost)
  csock = UDPSocket()
  bind(csock, ipaddr, baseport) || error("Unable to bind to $ipaddr:$baseport")
  dsock = UDPSocket()
  bind(dsock, ipaddr, baseport+1) || error("Unable to bind to $ipaddr:$(baseport+1)")
  proto = GroguDaemon(client, csock, dsock, Float32[])
  @async begin
    try
      while isopen(csock)
        from, bytes = recvfrom(csock)
        s = strip(String(bytes))
        length(s) == 0 && continue
        try
          json = JSON.parse(s)
          _command(proto, from, json)
        catch ex
          @warn "Bad command: $s" ex
        end
      end
    catch ex
      ex isa EOFError || @warn "$ex"
      close(csock)
      close(dsock)
    end
  end
  @async begin
    try
      while isopen(dsock)
        _odata(proto, recv(dsock))
      end
    catch ex
      ex isa EOFError || @warn "$ex"
      close(csock)
      close(dsock)
    end
  end
  proto
end

"""
    close(proto::GroguDaemon)

Close grogu daemon.
"""
function Base.close(proto::GroguDaemon)
  close(proto.csock)
  close(proto.dsock)
  nothing
end

# called when we receive a command
function _command(proto::GroguDaemon, from, cmd)
  action = cmd["action"]
  id = "id" ∈ keys(cmd) ? ", id: \"$(cmd["id"])\"" : ""
  if action == "version"
    ver = pkgversion(@__MODULE__)
    send(proto.csock, from.host, from.port, """{"name": "VirtualAcousticOcean", "version": "$ver", "protocol": "0.1.0" $id}\n""")
  elseif action == "ireset"
    set!(proto.client, :iseqno, 0)
  elseif action == "istart"
    port = cmd["port"]
    istart(proto.client, (t, seqno, data) -> _idata(proto, from.host, port, t, seqno, data), get(cmd, "blocks", 0))
  elseif action == "istop"
    istop(proto.client)
  elseif action == "oclear"
    empty!(proto.obuf)
  elseif action == "ostart"
    # TODO: support events
    ostart(proto.client, proto.obuf, get(cmd, "time", 0))
  elseif action == "ostop"
    # TODO: support events
    ostop(proto.client)
  elseif action == "get"
    k = Symbol(cmd["param"])
    v = k === :obufsize ? OBUFSIZE : get(proto.client, k)
    v === nothing || send(proto.csock, from.host, from.port, """{"param": "$(cmd["param"])", "value": $v $id}\n""")
  elseif action == "set"
    set!(proto.client, Symbol(cmd["param"]), cmd["value"])
  elseif action == "quit"
    # don't quit
  end
end

# called when we receive data
function _odata(proto::GroguDaemon, data)
  try
    # skip 16 byte header and convert the rest to floats
    push!(proto.obuf, reinterpret(Float32, data[17:end]))
  catch ex
    @warn ex
  end
end

# called to send data
function _idata(proto::GroguDaemon, host, port, t, seqno, data::Matrix{Float32})
  hdr = GroguDataHeader(hton(UInt64(t)), hton(UInt32(seqno)), hton(UInt16(size(data,1))), hton(UInt16(size(data,2))))
  bytes = vcat(reinterpret(UInt8, [hdr]), reinterpret(UInt8, data))
  send(proto.dsock, host, port, bytes)
end
