struct RX
  t::Int
  x::Vector{Float32}
end

Base.firstindex(rx::RX) = rx.t
Base.lastindex(rx::RX) = rx.t + length(rx.x) - 1

struct AcousticTape
  rxs::Vector{RX}
end

AcousticTape() = AcousticTape(RX[])

function Base.push!(tape::AcousticTape, t, x)
  push!(tape.rxs, RX(t, x))
  tape
end

function Base.read(tape::AcousticTape, t, n; purge=true)
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

function purge!(tape::AcousticTape, t)
  filter!(rx -> lastindex(rx) ≥ t, tape.rxs)
  tape
end
