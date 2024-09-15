module VirtualAcousticOcean

### common types
const Pos3D = NTuple{3,Float64}
const Time = UInt64

### code modules
include("tape.jl")
include("sim.jl")
include("uasp.jl")

end # module
