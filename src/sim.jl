using UnderwaterAcoustics
using Memoization

export Simulation, addnode!

################################################################################
### types

"""
Simulated acoustic node.
"""
mutable struct Node{T}
  pos::Pos3D                    # nominal (x, y, z) position of node
  relpos::Vector{Pos3D}         # relative position of transducers/hydrophones wrt node
  ochannels::Int                # number of output channels
  igain::Float64                # dB re rxref
  ogain::Float64                # dB re txref
  mute::Bool                    # is node muted?
  seqno::UInt64                 # input (ADC) stream block sequence number
  tapes::Vector{SignalTape}     # signal tape for each hydrophone
  conn::Union{Nothing,T}        # streaming protocol connector
  lock::ReentrantLock           # lock to protect tapes
end

"""
Simulation task information.
"""
mutable struct SimTask
  t0::Float64                   # start time for the simulation (epoch time)
  @atomic t::Int                # simulation time index (ADC samples)
  task::Union{Task,Nothing}     # Julia task handle
end

"""
Virtual acoustic ocean simulation.
"""
Base.@kwdef struct Simulation{T1,T2}
  model::T1
  nodes::Vector{Node} = Node[]
  frequency::Float64                    # nominal frequency (Hz)
  noise::T2 = RedGaussianNoise(1e6)     # noise model
  irate::Float64 = 4 * frequency        # ADC samples/s
  iblksize::Int = 0                     # ADC samples
  orate::Float64 = 8 * frequency        # DAC samples/s
  txref::Float64 = 185.0                # dB re µPa @ 1m
  rxref::Float64 = -190.0               # dB re 1/µPa
  txdelay::Float64 = 0.1                # min time to transmit from ostart (s)
  mobility::Bool = false                # can node positions change?
  task::SimTask = SimTask(0.0, 0, nothing)
  timers::Vector{Tuple{Int,Any}} = Tuple{Int,Any}[]
end

################################################################################
### Simulation methods

"""
    Simulation(model, frequency; kwargs...)

Create a simulation based on a propagation `model` with a nominal `frequency`
(in Hz). The `model` is an 2½D or 3D acoustic propagation model compatible
with `UnderwaterAcoustics.jl`.

Optional parameters:
- `irate`: ADC frame rate for sampling acoustic signal (samples/s)
- `iblksize`: ADC block size for streaming acoustic signal (samples, 0 for auto)
- `orate`: DAC frame rate for transmitting acoustic signal (samples/s)
- `txref`: Conversion between DAC input and acoustic source level (dB re µPa @ 1m)
- `rxref`: Conversion between acoustic receive level and ADC output (dB re 1/µPa)
- `noise`: Noise model for the simulation (default: RedGaussianNoise(1e6))
- `mobility`: `true` if node are mobile (default: `false`)

If `irate` is not specified, it defaults to 4 × `frequency`. If `orate` is not
specified, it defaults to 8 × `frequency`.

Static simulations (`mobility=false`) may cache computations to improve performance.
"""
Simulation(model, frequency; kwargs...) = Simulation(; model, frequency, kwargs...)

"""
    addnode!(sim::Simulation, nodepos::Pos3D, protocol, args...; relpos=[(0,0,0)], ochannels=1)

Add simulated node at location `nodepos`, accessible over the specified `protocol`.
`args` are protocol arguments, passed to the constructor of the protocol.
If the node supports multiple transducers/hydrophones, their relative positions
(wrt `nodepos`) should be provided as a vector of positions in `relpos`.
`ochannels` is the number of transmitters supported by the node. Channels
`1:ochannels` are assumed to be able to transmit and receive, whereas channels
`ochannels+1:length(relpos)` are assumed to be receive-only channels.
"""
function addnode!(sim::Simulation, nodepos::Pos3D, protocol, args...; relpos=[(0.0, 0.0, 0.0)], ochannels=1)
  sim.task.task === nothing || error("Cannot add node to running simulation")
  tapes = [SignalTape() for _ ∈ 1:length(relpos)]
  node = Node{protocol}(nodepos, relpos, ochannels, 0.0, 0.0, false, 0, tapes, nothing, ReentrantLock())
  node.conn = protocol((sim, node), args...)
  push!(sim.nodes, node)
  length(sim.nodes)
end

"""
    run(sim::Simulation)

Start simulation.
"""
function Base.run(sim::Simulation)
  Threads.nthreads() == 1 && @warn "Running in single threaded mode...\nStart Julia with `-t auto` to run multithreaded"
  sim.task.task === nothing || error("Simulation already running")
  mod(sim.orate, sim.irate) == 0 || error("orate must be an integer multiple of irate")
  sim.task.t0 = time()
  @atomic sim.task.t = 0
  for n ∈ sim.nodes
    run(sim, n)
  end
  sim.task.task = errormonitor(@async _run(sim, sim.task))
  nothing
end

function _run(sim::Simulation, task::SimTask)
  sf = 10 ^ (sim.rxref / 20)
  iblksize = _iblksize(sim)
  while task.t0 > 0
    t = @atomic task.t
    Δt = task.t0 + (t / sim.irate) - time()
    Δt > 0 && sleep(Δt)
    for node ∈ sim.nodes
      x = Matrix{Float32}(undef, iblksize, length(node.tapes))
      for i ∈ eachindex(node.tapes)
        lock(node.lock) do
          x[:,i] .= read(node.tapes[i], t, iblksize)
        end
        x[:,i] .+= sf * rand(sim.noise, iblksize; fs=sim.irate)
      end
      stream(sim, node, t, x)
    end
    t += iblksize
    @atomic task.t = t
    while !isempty(sim.timers) && sim.timers[1][1] ≤ t
      _, callback = popfirst!(sim.timers)
      @invokelatest callback(t)
    end
  end
end

function _iblksize(sim::Simulation)
  sim.iblksize > 0 && return sim.iblksize
  maxch = maximum(node -> length(node.tapes), sim.nodes)
  min(353 ÷ maxch, 256)
end

"""
    close(sim::Simulation)

Stop simulation and remove all nodes.
"""
function Base.close(sim::Simulation)
  sim.task.t0 = 0.0
  @atomic sim.task.t = 0
  sim.task.task = nothing
  for node ∈ sim.nodes
    close(sim, node)
  end
  empty!(sim.nodes)
  nothing
end

"""
    schedule(sim::Simulation, t, callback)

Schedule a `callback` to be triggered at simulation time index `t`. Returns the
number of scheduled callbacks.
"""
function Base.schedule(sim::Simulation, t, callback)
  push!(sim.timers, (t, callback))
  sort!(sim.timers; by=x->x[1])
  length(sim.timers)
end

"""
    time_µs(sim::Simulation, t)

Convert time from samples to microseconds.
"""
time_µs(sim::Simulation, t) = round(Int, t / sim.irate * 1000000)

"""
    time_samples(sim::Simulation, t)

Convert time from microseconds to samples.
"""
time_samples(sim::Simulation, t) = round(Int, t / 1000000 * sim.irate)

################################################################################
### Node methods

"""
    run(sim::Simulation, node::Node)

Start listening for UDP commands/data for `node`.
"""
function Base.run(sim::Simulation, node::Node)
  run(node.conn)
end

"""
    close(sim::Simulation, node::Node)

Stop listening for UDP commands/data for `node`.
"""
function Base.close(sim::Simulation, node::Node)
  if node.conn !== nothing
    close(node.conn)
    node.conn = nothing
  end
end

"""
    stream(sim::Simulation, node::Node, t, x)

Stream signal `x` at time index `t` to node `node`. Signal `x` must be a multichannel
signal (`Float32` matrix) with `sim.iblksize` samples and `length(node.relpos)`
channels.
"""
function stream(sim::Simulation, node::Node, t, x)
   if node.conn !== nothing
    stream(node.conn, time_µs(sim, t), node.seqno, x)
    node.seqno += 1
   end
end

"""
    transmit(sim::Simulation, node::Node, t, x)

Transmit signal `x` from `node` at time index `t`. The transmitter is assumed to be
half duplex and does not receive its own transmission.
"""
function UnderwaterAcoustics.transmit(sim::Simulation, node::Node, t, x)
  t_now = @atomic sim.task.t
  node.mute && return t_now
  fs = sim.irate
  if sim.orate != fs
    n = round(Int, sim.orate/sim.irate)
    x = x[1:n:end,:]
  end
  txpos = [node.pos .+ p for p ∈ node.relpos]
  tx = [AcousticSource(txpos[ch]..., sim.frequency) for ch ∈ 1:size(x,2)]
  rxnodes = filter(n -> n != node, sim.nodes)
  rx = mapreduce(n -> [AcousticReceiver((n.pos .+ p)...) for p ∈ n.relpos], vcat, rxnodes)
  tx_sf = 10 ^ ((sim.txref + node.ogain) / 20)
  rx_sfs = [10 ^ ((sim.rxref + node.igain) / 20) for node ∈ rxnodes]
  t = max(t, t_now + time_samples(sim, sim.txdelay * 1e6))
  errormonitor(Threads.@spawn _transmit(sim, tx, rx, fs, tx_sf * x, rx_sfs, t, rxnodes))
  t
end

function _transmit(sim, tx, rx, fs, x, rx_sfs, t, rxnodes)
  ch = sim.mobility ? channel(sim.model, tx, rx, fs) : @memoize Dict channel(sim.model, tx, rx, fs)
  y = samples(transmit(ch, x; fs, abstime=true))
  j = 1
  t_now = @atomic sim.task.t
  for (i, node) ∈ enumerate(rxnodes)
    for tape ∈ node.tapes
      lock(node.lock) do
        push!(tape, t, Float32.(rx_sfs[i] * y[:,j]))
      end
      @debug "delivered signal to node $i"
      j += 1
    end
  end
  if length(rxnodes) > 0 && t_now > t
    @warn "Computation took too long: RX delayed by $(round(Int, (t_now - t) * 1000 / sim.irate)) ms"
  end
end

################################################################################
### Node protocol interface methods

"""
    transmit(client, t, x::Matrix{Float32}, id)

Start DAC output. If time `t` (in µs) is in the past, output starts immediately. `id`
is an opaque identifier for the transmission to be passed back during transmission
start/stop events.
"""
function UnderwaterAcoustics.transmit((sim, node)::Tuple{Simulation,Node}, t, x, id)
  ti_start = time_samples(sim, t)
  ti_start = transmit(sim, node, ti_start, x)
  ti_end = ti_start + round(Int, size(x,1) / sim.orate * sim.irate)
  schedule(sim, ti_start, t -> node.conn === nothing || event(node.conn, time_µs(sim, t), "ostart", id))
  schedule(sim, ti_end, t -> node.conn === nothing || event(node.conn, time_µs(sim, t), "ostop", id))
end

"""
    Base.get(client, k::Symbol)

Get parameter `k`. Returns `nothing` is parameter is unknown.
"""
function Base.get((sim, node)::Tuple{Simulation,Node}, k::Symbol)
  k === :time && return round(Int, @atomic(sim.task.t) / sim.irate)
  k === :iseqno && return node.seqno
  k === :iblksize && return _iblksize(sim)
  k === :irate && return sim.irate
  k === :irates && return [sim.irate]
  k === :ichannels && return length(node.relpos)
  k === :igain && return node.igain
  k === :orate && return sim.orate
  k === :orates && return [sim.orate]
  k === :ochannels && return node.ochannels
  k === :ogain && return node.ogain
  k === :omute && return node.mute
  nothing
end

"""
    set!(client, k::Symbol, v)

Set parameter `k` to value `v`. Unknown parameters are silently ignored.
"""
function set!((sim, node)::Tuple{Simulation,Node}, k::Symbol, v)
  if k === :igain
    node.igain = v
  elseif k === :ogain
    node.ogain = v
  elseif k === :omute
    node.mute = v
  elseif k === :iseqno
    node.seqno = 0
  end
end
