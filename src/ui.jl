using Oxygen
using HTTP
import TOML

export load, webui

const CONFIG_FILENAME = "/tmp/vao.toml"

## Web UI

function webui(; async=true, kwargs...)
  get("/config/load") do
    try
      join(readlines(CONFIG_FILENAME), "\n")
    catch e
      "# Could not read configuration file"
    end
  end
  post("/config/save") do req::HTTP.Request
    @info "post" String(req.body)
    "OK"
  end
  get("/status") do
    "not running"
  end
  get("/restart") do
    "OK"
  end
  serve(; async, kwargs...)
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
