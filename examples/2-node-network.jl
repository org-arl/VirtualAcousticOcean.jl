using VirtualAcousticOcean
using UnderwaterAcoustics

env = UnderwaterEnvironment()
pm = PekerisRayModel(env, 7)
sim = Simulator(pm)
add!(sim, (0.0, 0.0, -10.0), 9809)
add!(sim, (1000.0, 0.0, -10.0), 9819)
