# UnetStack acoustic streaming protocol

## Overview

The UnetStack acoustic streaming protocol (UASP) allows a UnetStack baseband service to access ADC/DAC over a network using UDP packets. Both, the UASP server (henceforth referred to as `uaspd`, provided by Virtual Acoustic Ocean or a hardware driver on a modem) and a UASP client (typically a baseband service in a modem) listen on 2 UDP ports: the _command_ port and the _data_ port. All communications over the command ports use ASCII JSON messages. All communications over the data ports use a binary PDU format.

## Command protocol

Any command sent by a client to `uaspd` command port (default port `9809`) is called a _request_. The `uaspd` may, if necessary, respond to a request with a _response_ to the UDP port from which the request came (client's command port). Sometimes `uaspd` may send unsolicited _notifications_ on the same port.

The JSON messages below show request/response interactions through examples:

### Check version:
```
{"action": "version"}
```
with response:
```
{"name": "uaspd", "version": "0.1.0", "protocol": "0.1.0"}
```
Here `uaspd` may be replaced by an identifier for the driver providing the service.

### Reset ADC data counters and time:
```
{"action": "ireset"}
```

### Start streaming ADC data:
(to client data port 8080)
```
{"action": "istart", "port": 8080}
```

### Stream a fixed number of blocks of ADC data:
(to client data port 8080)
```
{"action": "istart", "port": 8080, "blocks": 10}
```

### Stop streaming ADC data:
```
{"action": "istop"}
```

### Clear DAC data buffer:
```
{"action": "oclear"}
```

### Start DAC output from data buffer:
```
{"action": "ostart"}
{"action": "ostart", "time": 127653327}
```
with notifications at start and end of DAC output:
```
{"event": "ostart", "time": 37723672}
{"event": "ostop", "time": 48835643}
```
If a `time` is specified, the DAC output is deferred until the specified time.
If the `time` is in the past, the DAC output should start immediately. The value
of `time` should be treated as an unsigned 64-bit integer, and represents time in
µs from some arbitrary origin.

A successful `ostart` transmits the signal in the data buffer and clears the buffer.

### Stop DAC output:
```
{"action": "ostop"}
```
If the DAC output was enabled, this would result in a `ostop` notification:
```
{"event": "ostop", "time": 48835643}
```

### Get parameters:
```
{"action": "get", "param": "time"}
{"action": "get", "param": "iseqno"}
{"action": "get", "param": "iblksize"}
{"action": "get", "param": "irate"}
{"action": "get", "param": "irates"}
{"action": "get", "param": "ichannels"}
{"action": "get", "param": "igain"}
{"action": "get", "param": "obufsize"}
{"action": "get", "param": "orate"}
{"action": "get", "param": "orates"}
{"action": "get", "param": "ochannels"}
{"action": "get", "param": "ogain"}
{"action": "get", "param": "omute"}
```
with corresponding responses:
```
{"param": "time", "value": 347667475}         # timestamp in µs from some origin
{"param": "iseqno", "value": 3451}            # next ADC block sequence number
{"param": "iblksize", "value": 256}           # ADC block size in samples/channel
{"param": "irate", "value": 48000}            # ADC sampling rate in Sa/s
{"param": "irates", "value": [48000, 96000]}  # possible ADC sampling rates
{"param": "ichannels", "value": 1}            # number of ADC channels
{"param": "igain", "value": 0}                # ADC gain in dB
{"param": "obufsize", "value": 2880000}       # DAC buffer size in samples/channel
{"param": "orate", "value": 48000}            # DAC sampling rate in Sa/s
{"param": "orates", "value": [48000, 96000]}  # possible DAC sampling rates
{"param": "ochannels", "value": 1}            # number of DAC channels
{"param": "ogain", "value": 0}                # DAC gain in dB
{"param": "omute", "value": false}            # DAC mute setting
```

### Set parameters:
```
{"action": "set", "param": "irate", "value": 96000}
{"action": "set", "param": "igain", "value": 6}
{"action": "set", "param": "orate", "value": 96000}
{"action": "set", "param": "ogain", "value": -30}
{"action": "set", "param": "omute", "value": false}
```

### Quit uaspd:
```
{"action": "quit"}
```

If there is a need to associate a response with a request, an `id` field may be added to the request, and is copied in the response. For example:
```
{"action": "get", "param": "irate", id: 123}
```
yields
```
{"param": "irate", "value": 48000, id: 123}
```

## Data PDU format

Input/output data format:
```
timestamp :: uint64
seqno     :: uint32
nsamples  :: uint16
nchannels :: uint16
data      :: float32[nsamples*nchannels]
```
Data is sent over the network in network byte order (big endian).

ADC data is streamed to the client as it comes in, and all fields are populated.

DAC data is sent by the client to `uaspd`, and is appended to the DAC buffer provided it is valid and the buffer has sufficient space. The number of channels of data for DAC must match the published `ochannels` parameter. The `timestamp` field is ignored for DAC data.

Multiple channels are interleaved, i.e., data is organized as:<br>
`[ch1_t1 ch2_t1 ch3_t1 ch4_t1 ch1_t2 ch2_t2 ch3_t2 ch4_t2 ...]`

Note: Since data PDUs are sent as UDP packets, it is recommended that `nsamples` is chosen such that the packet size does not exceed the supported UDP MTU (typically 1432 bytes). Modern systems support UDP packets larger than this, but they are often fragmented at the physical layer and may have poor performance, and so not recommended.
