using Sockets
using JSON
using Base64: base64decode

export UASP2

################################################################################
### types and constants

const OBUFSIZE = 1920000          # DAC samples

"""
UnetStack acoustic streaming protocol v2.
"""
mutable struct UASP2
  const client::Any                       # opaque client handle
  const csvr::Sockets.TCPServer           # TCP command server
  csock::Union{TCPSocket,Nothing}         # TCP command socket
  const dsock::UDPSocket                  # UDP socket to send data
  const port::Int                         # TCP port number
  const ipaddr::IPAddr                    # IP address to bind to
  const obuf::Vector{Float32}             # output signal buffer (DAC)
  dhost::Union{IPAddr,Nothing}            # IP address to stream data to
  dport::Int                              # port number to stream data to
end

################################################################################
### UASP v2 methods

"""
    UASP2(client, port)
    UASP2(client, port, ipaddr)

Create UASP v2 daemon to run on TCP `port`. If IP address is not specified,
daemon only binds to localhost. The `client` must support the protocol interface
methods (see `Node` for details).
"""
function UASP2(client, port::Int, ipaddr::IPAddr=Sockets.localhost)
  UASP2(client, listen(ipaddr, port), nothing, UDPSocket(), port, ipaddr, Float32[], nothing, 0)
end

"""
    run(conn::UASP2)

Start UASP v2 daemon.
"""
function Base.run(conn::UASP2)
  @async begin
    while isopen(conn.csvr)
      try
        conn.csock = accept(conn.csvr)
        while isopen(conn.csock)
          s = readline(conn.csock) |> strip
          length(s) == 0 && break
          try
            json = JSON.parse(s)
            _command(conn, json)
          catch ex
            @warn "Bad command: $s" exception=(ex, catch_backtrace())
          end
        end
      catch ex
        isopen(conn.csvr) && (ex isa EOFError || @warn "$ex")
      end
      close(conn.csock)
      conn.csock = nothing
    end
  end
end

"""
    close(conn::UASP2)

Close UASP v2 daemon.
"""
function Base.close(conn::UASP2)
  close(conn.dsock)
  close(conn.csvr)
  conn.csock === nothing || close(conn.csock)
  nothing
end

"""
    stream(conn::UASP2, t, seqno, data)

Stream data over connection. `t` is the time (in µs) of the first sample in the
`data` buffer, and `seqno` is the frame number in the data stream.
"""
function stream(conn::UASP2, t, seqno, data)
  if conn.dport > 0
    hdr = UASP_DataHeader(hton(UInt64(t)), hton(UInt32(seqno)), hton(UInt16(size(data,1))), hton(UInt16(size(data,2))))
    bytes = vcat(reinterpret(UInt8, [hdr]), reinterpret(UInt8, hton.(vec(data'))))
    send(conn.dsock, conn.dhost, conn.dport, bytes)
  end
end

"""
    event(conn::UASP2, t, ev, id)

Send event `ev` at time `t`  (in µs) with optional `id` over connection.
"""
function event(conn::UASP2, t, ev, id)
  ntf = Dict{String,Any}()
  ntf["event"] = ev
  ntf["time"] = t
  id === nothing || (ntf["id"] = id)
  @debug JSON.json(ntf)
  try
    write(conn.csock, JSON.json(ntf) * '\n')
  catch
    # ignore write errors
  end
end

# called when we receive a command
function _command(conn::UASP2, cmd)
  @debug cmd
  action = cmd["action"]
  if action == "version"
    ver = pkgversion(@__MODULE__)
    rsp = Dict{String,Any}()
    rsp["name"] = "VirtualAcousticOcean"
    rsp["version"] = "$ver"
    rsp["protocol"] = "0.2.0"
    "id" ∈ keys(cmd) && (rsp["id"] = cmd["id"])
    @debug JSON.json(rsp)
    write(conn.csock, JSON.json(rsp) * '\n')
  elseif action == "ireset"
    set!(conn.client, :iseqno, 0)
  elseif action == "istart"
    conn.dhost = getpeername(conn.csock)[1]
    conn.dport = cmd["port"]
  elseif action == "istop"
    conn.dport = 0
    conn.dhost = nothing
  elseif action == "oclear"
    empty!(conn.obuf)
  elseif action == "odata"
    _odata(conn, base64decode(cmd["data"]))
  elseif action == "ostart"
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
      write(conn.csock, JSON.json(rsp) * '\n')
    end
  elseif action == "set"
    set!(conn.client, Symbol(cmd["param"]), cmd["value"])
  elseif action == "quit"
    # don't quit
  end
end

# called when we receive data
function _odata(conn::UASP2, data)
  try
    # skip 16 byte header and convert the rest to floats
    append!(conn.obuf, ntoh.(reinterpret(Float32, @view data[17:end])))
  catch ex
    @warn ex
  end
end
