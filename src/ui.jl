using Oxygen
using HTTP
import TOML

export load, webui

## Web UI

sim::Union{Simulation,Nothing} = nothing

function webui(filename; async=false, kwargs...)
  get("/config/load") do
    try
      join(readlines(filename), "\n")
    catch
      "# Could not read configuration file"
    end
  end
  post("/config/save") do req::HTTP.Request
    s = String(req.body)
    try
      open(filename, "w") do f
        print(f, s)
      end
      "OK"
    catch e
      string(e)
    end
  end
  get("/status") do
    if isnothing(sim)
      "stopped"
    else
      io = IOBuffer()
      println(io, "running\n")
      println(io, "Simulation running at $(sim.frequency) Hz with:")
      for (idx, node) ∈ enumerate(sim.nodes)
        println(io, " - Node $(idx) at position $(node.pos) receiving on port $(node.conn.port)")
      end
      String(take!(io))
    end
  end
  get("/start") do
    isnothing(sim) || return "already running"
    try
      global sim = load(filename)
      run(sim)
      "OK"
    catch e
      global sim = nothing
      e isa TOML.ParserError ? sprint(showerror, e) : string(e)
    end
  end
  get("/stop") do
    isnothing(sim) && return "not running"
    close(sim)
    global sim = nothing
    "OK"
  end
  get("/restart") do
    isnothing(sim) || close(sim)
    try
      global sim = load(filename)
      run(sim)
      "OK"
    catch e
      global sim = nothing
      e isa TOML.ParserError ? sprint(showerror, e) : string(e)
    end
  end
  get("/") do
    join(readlines(joinpath(@__DIR__, "webui.html")), "\n")
  end
  srv = serve(; async, kwargs...)
  async && return srv
  isnothing(sim) || close(sim)
  global sim = nothing
end

## TOML based simulation descriptor loader

const bcs = Dict(
  "SeaState0" => SeaState0,
  "SeaState1" => SeaState1,
  "SeaState2" => SeaState2,
  "SeaState3" => SeaState3,
  "SeaState4" => SeaState4,
  "SeaState5" => SeaState5,
  "SeaState6" => SeaState6,
  "SeaState7" => SeaState7,
  "SeaState8" => SeaState8,
  "SeaState9" => SeaState9,
  "Rock" => Rock,
  "Pebbles" => Pebbles,
  "SandyGravel" => SandyGravel,
  "VeryCoarseSand" => VeryCoarseSand,
  "MuddySandyGravel" => MuddySandyGravel,
  "CoarseSand" => CoarseSand,
  "GravellyMuddySand" => GravellyMuddySand,
  "MediumSand" => MediumSand,
  "MuddyGravel" => MuddyGravel,
  "FineSand" => FineSand,
  "MuddySand" => MuddySand,
  "VeryFineSand" => VeryFineSand,
  "ClayeySand" => ClayeySand,
  "CoarseSilt" => CoarseSilt,
  "SandySilt" => SandySilt,
  "MediumSilt" => MediumSilt,
  "SandyMud" => SandyMud,
  "FineSilt" => FineSilt,
  "SandyClay" => SandyClay,
  "VeryFineSilt" => VeryFineSilt,
  "SiltyClay" => SiltyClay,
  "Clay" => Clay,
  "PressureReleaseBoundary" => PressureReleaseBoundary,
  "RigidBoundary" => RigidBoundary
)

"""
    load(filename)::Simulation

Load simulation from TOML descriptor.
"""
function load(filename)
  toml = TOML.parsefile(filename)
  e = get(toml, "environment", Dict())
  bathymetry = get(e, "bathymetry", 100.0)
  surface = bcs[get(e, "surface", "PressureReleaseBoundary")]
  seabed = bcs[get(e, "seabed", "SandyClay")]
  env = UnderwaterEnvironment(; bathymetry, surface, seabed)
  a = get(toml, "acoustics", Dict())
  kwargs = Dict{Symbol,Any}()
  for (k, v) ∈ a
    k ∈ ("frequency",) || (kwargs[Symbol(k)] = v)
  end
  pm = PekerisRayTracer(env; kwargs...)
  f = get(a, "frequency", 24000.0)
  sim = Simulation(pm, f)
  for (i, n) ∈ enumerate(get(toml, "node", []))
    pos = get(n, "location", (0.0, 0.0, 0.0))
    length(pos) == 3 || error("Node position must be a 3-element array")
    pos = NTuple{3,Float64}(pos)
    port = get(n, "port", 9000 + i)
    addnode!(sim, pos, UASP2, port, ip"0.0.0.0")
  end
  sim
end
