# VirtualAcousticOcean.jl
**Real-time Underwater Acoustic Simulator**

### Introduction

The [`UnderwaterAcoustics.jl`](https://github.com/org-arl/UnderwaterAcoustics.jl) project provides a unified interface to many underwater acoustic propagation models including such as [`PekerisRayModel`](https://org-arl.github.io/UnderwaterAcoustics.jl/stable/pm_pekeris.html), [`RaySolver`](https://github.com/org-arl/AcousticRayTracers.jl), [Bellhop, Kraken](https://github.com/org-arl/AcousticsToolbox.jl), etc. This project leverages these models to provide a <u>real-time streaming</u> ocean acoustic simulator for software-only or hardware-in-the-loop simulations. The data streams are simulated analog-to-digital convertor (ADC) and digital-to-analog (DAC) convertor data in acoustic systems.

If you only need offline acoustic simulations, you may want to consider using the [acoustic simulation API](https://org-arl.github.io/UnderwaterAcoustics.jl/stable/pm_basic.html#Acoustic-simulations) in `UnderwaterAcoustics.jl` directly instead.

### Installation

```julia
julia> # press ]
pkg> add VirtualAcousticOcean
```

### Setting up a simulation

Setting up a simulation is simple. We first describe an environment and create a propagation model, as one would with the [propagation modeling toolkit](https://org-arl.github.io/UnderwaterAcoustics.jl/stable/pm_basic.html):
```julia
using UnderwaterAcoustics

env = UnderwaterEnvironment(
  seabed = SandyClay,                 # sandy-clay seabed
  bathymetry = ConstantDepth(40.0)    # 40m water depth
)
pm = PekerisRayModel(env, 7)          # 7-ray Pekeris ray model
```

We then define a simulation using that environment, adding acoustic nodes to it:
```julia
using VirtualAcousticOcean

sim = Simulation(pm, 25000.0)               # operating at 25 kHz nominal frequency
addnode!(sim, (0.0, 0.0, -10.0), 9809)      # node 1 at 10 m depth, accessible over UDP port 9809
addnode!(sim, (1000.0, 0.0, -10.0), 9819)   # node 2 at 10 m depth, 1 km away, accessible over UDP port 9819
run(sim)                                    # start simulation (non-blocking)
```
Any number of nodes may be added to a simulation. Each node is accessible over UDP port using the [Grogu real-time streaming protocol](./docs/grogu-protocol.md). UnetStack 4 based models and software-defined model simulators support the Grogu protocol out-of-the-box.

Nodes may have an array of hydrophones, if desired. To define an array, each hydrophone location relative to the node location is specified using a keyword parameter `relpos`. For example:
```julia
addnode!(sim, (500.0, 500.0, -15.0), 9809; relpos=[
  (0.0,0.0,0.0),      # relative position of hydrophone 1
  (0.0,0.0,-1.0),     # relative position of hydrophone 2
  (0.0,0.0,-2.0),     # relative position of hydrophone 3
  (0.0,0.0,-3.0)      # relative position of hydrophone 4
])
```
To terminate the simulation, simply close the simulation:
```julia
close(sim)
```

### Extending / Contributing

While the Virtual Acoustic Ocean currently only supports the Grogu real-time streaming protocol, the code is designed to easily allow users to implement their own streaming protocols. If you implement a standard protocol that you feel may be useful to others, please do consider contributing the implementation back to this repository via a pull request (PR).

To implement a new protocol, create a new data type (e.g. `MyProtocol`) and support the following API:
```julia
MyProtocol(client)
VirtualAcousticOcean.run(conn::MyProtocol)
VirtualAcousticOcean.stream(conn::MyProtocol, timestamp::Int, seqno::Int, data::Matrix{Float32})
VirtualAcousticOcean.event(conn::MyProtcocol, timestamp::Int, event, id)
Base.close(conn::MyProtocol)
```
For documentation on what each API function should do, refer to the [Grogu real-time streaming protocol implementation](./src/grogu.jl).

The protocol implementation may call the following API:
```julia
Base.get(client, key::Symbol)                                                     # get parameter
VirtualAcousticOcean.set!(client, key::Symbol, value::Any)                        # set parameter
VirtualAcousticOcean.transmit(client, timestamp::Int, data::Matrix{Float32}, id)  # transmit a signal
```

Supported parameters:
```julia
:time         # current simulated time in µs
:iseqno       # next block sequence number of ADC input data stream
:iblksize     # ADC input data stream block size in samples
:irate        # ADC input data sampling rate (Sa/s)
:irates       # list of supported ADC input data sampling rate (Sa/s)
:ichannels    # number of ADC input channels
:igain        # gain (dB) of ADC channels
:orate        # DAC output sampling rate (Sa/s)
:orates       # list of supported DAC output sampling rate (Sa/s)
:ochannels    # number of DAC output channels
:ogain        # gain (dB) for DAC channels
:omute        # mute flag indicating that the DAC is muted
```

### Limitations

Currently, the Virtual Acoustic Ocean makes a quasi-static assumption:
- Node reception time is computed at time of transmission, and therefore does not account for any node motion while the transmission is in flight. This is a reasonable simplification for slow moving nodes and short distances, but may not hold at very long range communication.
- Node motion does not induce any Doppler in the reception.
