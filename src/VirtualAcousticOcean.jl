module VirtualAcousticOcean

# common types
const Pos3D = NTuple{3,Float64}
const Time = UInt64

# code modules
include("sim.jl")
include("tape.jl")

end # module
