# PhotonPropagation

[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://plenum-group.github.io/PhotonPropagation.jl/stable/)
[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://plenum-group.github.io/PhotonPropagation.jl/dev/)
[![Build Status](https://github.com/plenum-group/PhotonPropagation.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/plenum-group/PhotonPropagation.jl/actions/workflows/CI.yml?query=branch%3Amain)
[![Coverage](https://codecov.io/gh/plenum-group/PhotonPropagation.jl/branch/main/graph/badge.svg)](https://codecov.io/gh/plenum-group/PhotonPropagation.jl)

CUDA-accelerated Monte-Carlo simulation of photon transport in homogeneous media.

## Installation

```
] add https://github.com/PLEnuM-group/PhotonPropagation.jl.git
```

## Example
```julia
using PhotonPropagation
using StaticArrays

# Setup target
target = DetectionSphere(
    SA[0., 0., 10.],
    0.21,
    1,
    0.1,
    UInt16(1))

# convert to Float32 for fast computation on gpu
target = convert(DetectionSphere{Float32}, target)

# Setup source
position = SA_F32[0., 0., 0.]
source = PointlikeIsotropicEmitter(position, 0f0, 100000)

# Setup medium
mean_sca_angle = 0.99f0
medium = make_cascadia_medium_properties(mean_sca_angle)

# Setup spectrum
spectrum = Monochromatic(450f0)

seed = 1

# Setup propagation
setup = PhotonPropSetup([source], [target], medium, spectrum, seed)

# Run propagation
hits = propagate_photons(setup)
```