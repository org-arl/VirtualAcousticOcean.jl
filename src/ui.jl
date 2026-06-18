using Oxygen
using HTTP
import TOML

## Web UI

sim::Union{Simulation,Nothing} = nothing

"""
    webui(filename; async=false, kwargs...)

Start web UI for simulation configuration and control. The UI will read the
simulation configuration from `filename` and allow the user to start, stop,
and restart the simulation, as well as view the current status. The UI is
served at on port 8080 by default, but the port and other options can be
configured via `kwargs`. If `async` is set to `true`, the function will
return the server object immediately, allowing the caller to manage the server
lifecycle. Otherwise, the function will block until the server is stopped.

For details on supported `kwargs`, see the documentation for `Oxygen.serve`.
"""
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

Builds a simulation from a TOML descriptor. The TOML file should have the following
structure:
```toml
[environment]
bathymetry = 100.0
surface = "SeaState3"
seabed = "SandyClay"

[acoustics]
frequency = 24000.0

[[node]]
location = [x, y, z]
port = 9001
```

Node entries can be repeated to add multiple nodes. If `port` is not specified,
it will be assigned automatically starting from 9001. The `surface` and `seabed`
values are named boundary conditions from `UnderwaterAcoustics.jl`. If not
specified, they will default to `PressureReleaseBoundary` and `SandyClay`,
respectively. The `bathymetry` value is the depth of the water column in meters,
and defaults to 100.0 if not specified. The `frequency` is nominal acoustic
frequency in Hz, and defaults to 24000. Other model-specific parameters can
also be included in the `[acoustics]` section and will be passed as keyword
arguments to the model constructor. Currently, only the `PekerisRayTracer`
model is supported, but this may be extended in the future to allow selection
of different models.
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
