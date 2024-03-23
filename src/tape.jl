################################################################################
### types

"""
`RX` represents a reception of signal `x` at time index `t`.
"""
struct RX
  t::Int
  x::Vector{Float32}
end

"""
`SignalTape` stores a series of receptions at various times.
"""
struct SignalTape
  rxs::Vector{RX}
end

SignalTape() = SignalTape(RX[])

################################################################################
### SignalTape methods

"""
    push!(tape::SignalTape, t, x)

Add a reception of signal `x` at time index `t` to a signal tape.
"""
function Base.push!(tape::SignalTape, t, x)
  push!(tape.rxs, RX(t, x))
  tape
end

"""
    read(tape::SignalTape, t, n; purge=true)

Get `n` samples of signal received starting time index `t` taking into account
all signal receptions stored in the tape.

If `purge` is set to `true`, signal receptions ending from before time `t+n-1`
are dropped after reading the tape. This  is useful for real-time applications
where new receptions are added to the tape in chronological order, and the
tape is read back also in chronological order. Once read, receptions ending
before the end time of the last read signal are no longer needed and can be
purged to conserve memory.
"""
function Base.read(tape::SignalTape, t, n; purge=true)
  x = zeros(Float32, n)
  for rx in tape.rxs
    i = firstindex(rx) - t + 1
    j = lastindex(rx) - t + 1
    (j < 1 || i > n) && continue
    k = 1
    if i < 1
      k += 1 - i
      i = 1
    end
    m = min(length(rx.x) - k + 1, n - i + 1)
    x[i:i+m-1] .+= rx.x[k:k+m-1]
  end
  purge && purge!(tape, t + n - 1)
  clamp.(x, -1.0f0, 1.0f0)
end

"""
    purge!(tape::SignalTape, t)

Remove signals ending before time `t` from the signal tape.
"""
function purge!(tape::SignalTape, t)
  filter!(rx -> lastindex(rx) ≥ t, tape.rxs)
  tape
end

################################################################################
### RX methods

Base.firstindex(rx::RX) = rx.t
Base.lastindex(rx::RX) = rx.t + length(rx.x) - 1
