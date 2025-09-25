###############################################################
# run this simulation script with multiple threads:
#   julia -t auto --project examples/2-node-network.jl

using VirtualAcousticOcean
using UnderwaterAcoustics
using Sockets

###############################################################
# set up environment and propagation model
# (see documentation for UnderwaterAcoustics.jl)

env = UnderwaterEnvironment(
  bathymetry = 40.0,
  seabed = SandyClay
)
pm = PekerisRayTracer(env)

###############################################################
# set up simulation

sim = Simulation(pm, 24000.0)      # 24 kHz nominal frequency

# ip"0.0.0.0" asks the node to bind to all network interfaces
# if only localhost required, this argument can be dropped
addnode!(sim,    (0.0, 0.0, -10.0), UASP2, 9809, ip"0.0.0.0")
addnode!(sim, (1000.0, 0.0,  -5.0), UASP2, 9819, ip"0.0.0.0")

###############################################################
# run simulation

run(sim)        # start simulation asynchronously

println("Simulation running at $(sim.frequency)Hz with these nodes:")
for (idx, node) in enumerate(sim.nodes)
    println(" - Node $(idx) at position $(node.pos) receiving on port $(node.conn.port)")
end

wait()          # wait forever
