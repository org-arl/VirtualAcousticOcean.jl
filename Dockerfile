# syntax=docker/dockerfile:1
FROM julia:1.12.1-trixie

# Set env for non-interactive installs
ENV JULIA_DEPOT_PATH=/usr/local/julia

# Copy your package code
COPY . /VirtualAcousticOcean

# Precompile your package
RUN julia --color=yes --project=/VirtualAcousticOcean -e \
    'using Pkg; Pkg.instantiate(); Pkg.precompile()'

WORKDIR /sims

# Default to Julia REPL (can override with CMD in docker run)
ENTRYPOINT ["julia", "--color=yes", "-t", "auto", "--project=/VirtualAcousticOcean"]
CMD []
