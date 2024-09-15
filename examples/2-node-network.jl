using VirtualAcousticOcean
using UnderwaterAcoustics

env = UnderwaterEnvironment()
pm = PekerisRayModel(env, 7)
sim = Simulation(pm, 24000.0)
addnode!(sim, (0.0, 0.0, -10.0), UASP, 9809)
addnode!(sim, (1000.0, 0.0, -10.0), UASP, 9819)
run(sim)

close(sim)
