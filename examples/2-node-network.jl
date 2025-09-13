using VirtualAcousticOcean
using UnderwaterAcoustics
using Sockets

env = UnderwaterEnvironment(
  bathymetry = 40.0,
  seabed = SandyClay
)
pm = PekerisRayTracer(env)
sim = Simulation(pm, 24000.0)
addnode!(sim, (0.0, 0.0, -10.0), UASP2, 9809)
addnode!(sim, (1000.0, 0.0, -5.0), UASP2, 9819)
run(sim)

wait()
