module VirtualAcousticOcean

export Simulator, add!

const Pos3D = NTuple{3,Float64}
const Time = UInt64

struct RX
  time::Time
  x::Vector{Float32}
end

mutable struct Node
  pos::Pos3D
  relpos::Vector{Pos3D}
  ochannels::Int
  baseport::Int
  igain::Float64                        # dB re rxref
  ogain::Float64                        # dB re txref
  mute::Bool
  seqno::UInt64
  oport::Int
  obuf::Vector{Float32}
  rx::Vector{RX}
end

mutable struct SimTask
  t0::Float64
  time::Time
  task::Union{Task,Nothing}
end

Base.@kwdef struct Simulator{T}
  model::T
  nodes::Vector{Node} = Node[]
  irate::Float64 = 96000.0              # Sa/s
  iblksize::Int = 256                   # samples
  orate::Float64 = 192000.0             # Sa/s
  obufsize::Int = 1920000               # samples
  txref::Float64 = 185.0                # dB re µPa @ 1m
  rxref::Float64 = -190.0               # dB re 1/µPa
  task::SimTask = SimTask(0.0, 0, nothing)
end

Simulator(model; kwargs...) = Simulator(model=model, kwargs...)

function add!(sim::Simulator, nodepos::Pos3D, baseport; relpos=[(0.0, 0.0, 0.0)], ochannels=1)
  node = Node(nodepos, relpos, ochannels, baseport, 0.0, 0.0, false, 0, 0, Float32[], RX[])
  push!(sim.nodes, node)
  start(sim, node)
  length(sim.nodes)
end

function start(sim::Simulator, node::Node)
  start(sim)
  # TODO
end

function Base.close(sim::Simulator, node::Node)
  # TODO
end

function start(sim::Simulator)
  sim.task.task === nothing || return
  sim.task.t0 = time()
  sim.task.task = @async begin
    T = round(UInt64, sim.iblksize / sim.irate * 1e6)
    while sim.task.t0 > 0
      Δt = sim.task.t0 + sim.task.time/1e6 - time()
      Δt > 0 && sleep(Δt)
      t1 = sim.task.time + T
      # TODO
      sim.task.time = t1
    end
  end
end

function Base.close(sim::Simulator)
  sim.task.t0 = 0.0
  sim.task.time = 0
  sim.task.task = nothing
  for node ∈ sim.nodes
    close(sim, node)
  end
  empty!(sim.nodes)
  nothing
end

end # module
