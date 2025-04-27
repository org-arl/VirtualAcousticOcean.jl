# VirtualAcousticOcean.jl
**Real-time Underwater Acoustic Simulator**

### Introduction

The [`UnderwaterAcoustics.jl`](https://github.com/org-arl/UnderwaterAcoustics.jl) project provides a unified interface to many underwater acoustic propagation models including such as [`PekerisRayModel`](https://org-arl.github.io/UnderwaterAcoustics.jl/stable/pm_pekeris.html), [`RaySolver`](https://github.com/org-arl/AcousticRayTracers.jl), [Bellhop, Kraken](https://github.com/org-arl/AcousticsToolbox.jl), etc. This project leverages these models to provide a <u>real-time streaming</u> ocean acoustic simulator for software-only or hardware-in-the-loop simulations. The data streams simulate analog-to-digital convertors (ADC) and digital-to-analog convertors (DAC) in acoustic systems.

> [!TIP]
If you only need offline acoustic simulations, you may want to consider using the [acoustic simulation API](https://org-arl.github.io/UnderwaterAcoustics.jl/quickstart.html#channel-modeling) in `UnderwaterAcoustics.jl` directly instead.

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
  bathymetry = 40.0                   # 40m water depth
)
pm = PekerisRayTracer(env)            # Pekeris ray model
```

We then define a simulation using that environment, adding acoustic nodes to it:
```julia
using VirtualAcousticOcean

sim = Simulation(pm, 24000.0)                       # operating at 24 kHz nominal frequency
addnode!(sim, (0.0, 0.0, -10.0), UASP2, 9809)       # node 1 at 10 m depth
addnode!(sim, (1000.0, 0.0, -10.0), UASP2, 9819)    # node 2 at 10 m depth, 1 km away
run(sim)                                            # start simulation (non-blocking)
```
Any number of nodes may be added to a simulation. Both nodes above will be accessible over TCP ports (`9809` and `9819` respectively) using the [UnetStack acoustic streaming protocol v2](./docs/uasp2-protocol.md) (UASP2). [UnetStack](http://www.unetstack.net) 5 based modems and software-defined modem simulators support the UASP2 protocol out-of-the-box.

> [!TIP]
Previously we recommended the use of UASP protocol that used UDP to stream acoustic data. We now recommend using UASP2, which uses a combination of TCP and UDP for improved robustness. However, UnetStack 4 devices that only support [UASP](./docs/uasp-protocol.md) may use that protocol instead.

Nodes may have an array of hydrophones, if desired. To define an array, each hydrophone location relative to the node location is specified using a keyword parameter `relpos`. For example:
```julia
addnode!(sim, (500.0, 500.0, -15.0), UASP2, 9829; relpos=[
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

### Connecting to the simulator

Once the simulation is up and running, we can connect to the Virtual Acoustic Ocean and stream acoustic data from various nodes. For example, in the above simulation (with UASP2), we will have the following TCP ports open once the simulator is running:
- `9809` – command port for node 1 (single channel data)
- `9819` – command port for node 2 (single channel data)
- `9829` – command port for node 3 (4-channel data)

ADC data can be streamed from any of the nodes by sending a `istart` command and specifying the UDP port to stream the data to.

> [!TIP]
[UnetStack](www.unetstack.net) 5 based modems and software-defined model simulators allow us to specify the TCP port to connect to in the `modem.toml`. A minimal example `modem.toml` is shown below:

```toml
[input]
analoginterface = "UASP2DAQ"        # use UASP2 protocol
port = 9819                         # with control port 9819

[bb]
fc = 24000                          # carrier frequency of 24 kHz
```

### Extending / Contributing

While the Virtual Acoustic Ocean currently only supports [UASP](./docs/uasp-protocol.md) and [UASP2](./docs/uasp2-protocol.md), the code is designed to easily allow users to implement their own streaming protocols. If you implement a standard protocol that you feel may be useful to others, please do consider contributing the implementation back to this repository via a pull request (PR).

To implement a new protocol, create a new data type (e.g. `MyProtocol`) and support the following API:
```julia
MyProtocol(client)
VirtualAcousticOcean.run(conn::MyProtocol)
VirtualAcousticOcean.stream(conn::MyProtocol, timestamp::Int, seqno::Int, data::Matrix{Float32})
VirtualAcousticOcean.event(conn::MyProtcocol, timestamp::Int, event, id)
Base.close(conn::MyProtocol)
```
`data` matrix contains samples scaled in the ±1 range, with each column containing data for one channel. `timestamp` are in µs from an arbitrary time origin. `seqno` is a running packet number for streaming data. `id` is an opaque numeric ID identifying the transmission for which an event (transmission start `ostart` and transmission end `ostop`) is sent.

For detailed documentation on what each API function should do, refer to the [UASP2 implementation](./src/uasp2.jl).

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
