using UnderwaterAcoustics

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
end

"""
Simulation task information.
"""
mutable struct SimTask
  t0::Float64                   # start time for the simulation (epoch time)
  t::Int                        # simulation time index (ADC samples)
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
  task::SimTask = SimTask(0.0, 0, nothing)
  timers::Vector{Tuple{Int,Any}} = Tuple{Int,Any}[]
end

################################################################################
### Simulation methods

"""
    Simulation(model, frequency; kwargs...)

Create a simulation based on a propagation `model` with a nomimal `frequency`
(in Hz). The `model` is an 2½D or 3D acoustic propagation model compatible
with `UnderwaterAcoustics.jl`.

Optional parameters:
- `irate`: ADC frame rate for sampling acoustic signal (samples/s)
- `iblksize`: ADC block size for streaming acoustic signal (samples, 0 for auto)
- `orate`: DAC frame rate for transmitting acoustic signal (samples/s)
- `txref`: Conversion between DAC input and acoustic source level (dB re µPa @ 1m)
- `rxref`: Conversion between acoustic receive level and ADC output (dB re 1/µPa)
- `noise`: Noise model for the simulation (default: RedGaussianNoise(1e6))
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
  node = Node{protocol}(nodepos, relpos, ochannels, 0.0, 0.0, false, 0, tapes, nothing)
  node.conn = protocol((sim, node), args...)
  push!(sim.nodes, node)
  length(sim.nodes)
end

"""
    run(sim::Simulation)

Start simulation.
"""
function Base.run(sim::Simulation)
  sim.task.task === nothing || error("Simulation already running")
  mod(sim.orate, sim.irate) == 0 || error("orate must be an integer multiple of irate")
  sim.task.t0 = time()
  sim.task.t = 0
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
    Δt = task.t0 + (task.t / sim.irate) - time()
    Δt > 0 && sleep(Δt)
    for node ∈ sim.nodes
      x = Matrix{Float32}(undef, iblksize, length(node.tapes))
      for i ∈ eachindex(node.tapes)
        x[:,i] .= read(node.tapes[i], task.t, iblksize)
        x[:,i] .+= sf * rand(sim.noise, iblksize; fs=sim.irate)
      end
      stream(sim, node, task.t, x)
    end
    task.t += iblksize
    while !isempty(sim.timers) && sim.timers[1][1] ≤ task.t
      _, callback = popfirst!(sim.timers)
      @invokelatest callback(task.t)
    end
  end
end

# choose a block size that allows a data block to fit within an MTU of 1430 bytes or so
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
  sim.task.t = 0
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
half duplex and does not recieve its own transmission.
"""
function UnderwaterAcoustics.transmit(sim::Simulation, node::Node, t, x)
  node.mute && return
  fs = sim.irate
  if sim.orate != fs
    n = round(Int, sim.orate/sim.irate)
    x = x[1:n:end,:]
  end
  txpos = [node.pos .+ p for p ∈ node.relpos]
  tx = [AcousticSource(txpos[ch]..., sim.frequency) for ch ∈ 1:size(x,2)]
  rxnodes = filter(n -> n != node, sim.nodes)
  rx = mapreduce(n -> [AcousticReceiver((n.pos .+ p)...) for p ∈ n.relpos], vcat, rxnodes)
  #arr = [arrivals(sim.model, tx1, rx1) for tx1 ∈ tx, rx1 ∈ rx]
  sf = 10 ^ ((sim.txref + node.ogain) / 20)
  ch = channel(sim.model, tx, rx, fs)
  y = transmit(ch, sf * x; fs, abstime=true)
  #y = UnderwaterAcoustics.Recorder(nothing, tx, rx, arr)(sf * x; fs, reltime=false)
  j = 1
  for node ∈ rxnodes
    sf = 10 ^ ((sim.rxref + node.igain) / 20)
    for tape ∈ node.tapes
      push!(tape, t, sf * y[:,j])
      j += 1
    end
  end
  nothing
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
  ti_start = max(ti_start, sim.task.t)
  ti_end = ti_start + round(Int, size(x,1) / sim.orate * sim.irate)
  transmit(sim, node, ti_start, x)
  schedule(sim, ti_start, t -> node.conn === nothing || event(node.conn, time_µs(sim, t), "ostart", id))
  schedule(sim, ti_end, t -> node.conn === nothing || event(node.conn, time_µs(sim, t), "ostop", id))
end

"""
    Base.get(client, k::Symbol)

Get parameter `k`. Returns `nothing` is parameter is unknown.
"""
function Base.get((sim, node)::Tuple{Simulation,Node}, k::Symbol)
  k === :time && return round(Int, sim.task.t / sim.irate)
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
