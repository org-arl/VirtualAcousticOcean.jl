using UnderwaterAcoustics
import UnderwaterAcoustics: environment

export Simulation, addnode!, transmit, record, stop

################################################################################
### types

"""
Simulated acoustic node.
"""
mutable struct Node
  pos::Pos3D                    # nominal (x, y, z) position of node
  relpos::Vector{Pos3D}         # relative position of transducers/hydrophones wrt node
  ochannels::Int                # number of output channels
  baseport::Int                 # base UDP port number
  igain::Float64                # dB re rxref
  ogain::Float64                # dB re txref
  mute::Bool                    # is node muted?
  seqno::UInt64                 # input (ADC) stream block sequence number
  obuf::Matrix{Float32}         # output signal buffer (DAC)
  tapes::Vector{SignalTape}     # signal tape for each hydrophone
  observer::Any                 # vector to store signal or streaming callback
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
Base.@kwdef struct Simulation{T}
  model::T
  nodes::Vector{Node} = Node[]
  frequency::Float64                    # nominal frequency (Hz)
  irate::Float64 = 96000.0              # ADC samples/s
  iblksize::Int = 256                   # ADC samples
  orate::Float64 = 192000.0             # DAC samples/s
  obufsize::Int = 1920000               # DAC samples
  txref::Float64 = 185.0                # dB re µPa @ 1m
  rxref::Float64 = -190.0               # dB re 1/µPa
  task::SimTask = SimTask(0.0, 0, nothing)
end

################################################################################
### Simulation methods

"""
    Simulation(model, frequency; irate, iblksize, orate, obufsize, txref, rxref)

Create a simulation based on a propagation `model` with a nomimal `frequency`
(in Hz). The `model` is an 2½D or 3D acoustic propagation model compatible
with `UnderwaterAcoustics.jl`.

Optional parameters:
- `irate`: ADC frame rate for sampling aoustic signal (samples/s)
- `iblksize`: ADC block size for streaming acoustic signal (samples)
- `orate`: DAC frame rate for transmitting acoustic signal (samples/s)
- `obufsize`: DAC buffer size to store signal to transmit (samples)
- `txref`: Conversion between DAC input and acoustic source level (dB re µPa @ 1m)
- `rxref`: Conversion between acoustic receive level and ADC output (dB re 1/µPa)
"""
Simulation(model, frequency; kwargs...) = Simulation(; model, frequency, kwargs...)

"""
    addnode!(sim::Simulation, nodepos::Pos3D, baseport; relpos=[(0,0,0)], ochannels=1)

Add simulated node at location `nodepos`, accessible at UDP ports `baseport`
(command port) and `baseport+1` (data port). If the node supports multiple
transducers/hydrophones, their relative positions (wrt `nodepos`) should be
provided as a vector of positions in `relpos`. `ochannels` is the number of
transmitters supported by the node. Channels `1:ochannels` are assumed to be
able to transmit and receive, whereas channels `ochannels+1:length(relpos)`
are assumed to be receive-only channels.
"""
function addnode!(sim::Simulation, nodepos::Pos3D, baseport; relpos=[(0.0, 0.0, 0.0)], ochannels=1)
  sim.task.task === nothing || error("Cannot add node to running simulation")
  obuf = Matrix{Float32}(undef, 0, ochannels)
  tapes = [SignalTape() for _ ∈ 1:length(relpos)]
  node = Node(nodepos, relpos, ochannels, baseport, 0.0, 0.0, false, 0, obuf, tapes, nothing)
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
  while task.t0 > 0
    Δt = task.t0 + (task.t / sim.irate) - time()
    Δt > 0 && sleep(Δt)
    for node ∈ sim.nodes
      x = Matrix{Float32}(undef, sim.iblksize, length(node.tapes))
      for i ∈ eachindex(node.tapes)
        x[:,i] .= read(node.tapes[i], task.t, sim.iblksize)
        x[:,i] .+= sf * real(record(noise(environment(sim.model)), sim.iblksize/sim.irate, sim.irate))
      end
      stream(sim, node, task.t, x)
    end
    task.t += sim.iblksize
  end
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

################################################################################
### Node methods

"""
    run(sim::Simulation, node::Node)

Start listening for UDP commands/data for `node`.
"""
function Base.run(sim::Simulation, node::Node)
  # TODO
end

"""
    close(sim::Simulation, node::Node)

Stop listening for UDP commands/data for `node`.
"""
function Base.close(sim::Simulation, node::Node)
  # TODO
end

"""
    stream(sim::Simulation, node::Node, t, x)

Stream signal `x` at time index `t` to node `node`. Signal `x` must be a multichannel
signal (`Float32` matrix) with `sim.iblksize` samples and `length(node.relpos)`
channels.
"""
function stream(sim::Simulation, node::Node, t, x)
  # TODO
  if node.observer !== nothing
    if node.observer isa Vector{Float32}
      append!(node.observer, vec(x))
    else
      @invokelatest node.observer(sim, node, t, x)
    end
  end
end

"""
    record(sim::Simulation, node::Node, duration)

Record signals from all hydrophones on `node` for `duration` seconds.
"""
function UnderwaterAcoustics.record(sim::Simulation, node::Node, duration)
  buf = Float32[]
  node.observer = buf
  sleep(duration)
  node.observer = nothing
  reshape(permutedims(reshape(buf, sim.iblksize, length(node.tapes), :), (1,3,2)), :, length(node.tapes))
end

"""
    record(sim::Simulation, node::Node)

Start recording signals from all hydrophones on `node`. Call `stop()` to stop
the recording.
"""
function UnderwaterAcoustics.record(sim::Simulation, node::Node)
  node.observer = Float32[]
  nothing
end

"""
    stop(sim::Simulation, node::Node)

Stop recording signals on `node` and return the recorded signal.
"""
function stop(sim::Simulation, node::Node)
  buf = node.observer
  node.observer = nothing
  buf isa AbstractVector{Float32} || return nothing
  reshape(permutedims(reshape(buf, sim.iblksize, length(node.tapes), :), (1,3,2)), :, length(node.tapes))
end

"""
    transmit(sim::Simulation, node::Node, t, x)

Transmit signal `x` from `node` at time index `t`. The transmitter is assumed to be
half duplex and does not recieve its own transmission.
"""
function transmit(sim::Simulation, node::Node, t, x)
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
  arr = [arrivals(sim.model, tx1, rx1) for tx1 ∈ tx, rx1 ∈ rx]
  sf = 10 ^ (sim.txref / 20)
  y = UnderwaterAcoustics.Recorder(nothing, tx, rx, arr)(sf * x; fs, reltime=false)
  j = 1
  sf = 10 ^ (sim.rxref / 20)
  for node ∈ rxnodes
    for tape ∈ node.tapes
      push!(tape, t, sf * y[:,j])
      j += 1
    end
  end
  nothing
end
