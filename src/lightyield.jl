module LightYield

export LongitudinalParameters
export LongitudinalParameterisation
export get_longitudinal_params
export MediumPropertiesWater, MediumPropertiesIce
export CherenkovTrackLengthParameters
export longitudinal_profile, cascade_cherenkov_track_length, fractional_contrib_long
export particle_to_lightsource, particle_to_elongated_lightsource, particle_to_elongated_lightsource!
export total_lightyield
export rel_additional_track_length

export AngularEmissionProfile
export PhotonSource, PointlikeIsotropicEmitter, ExtendedCherenkovEmitter, CherenkovEmitter, PointlikeCherenkovEmitter
export AxiconeEmitter, PencilEmitter, PointlikeTimeRangeEmitter, CherenkovTrackEmitter
export cherenkov_ang_dist, cherenkov_ang_dist_int
export split_source, oversample_source

using Parameters: @with_kw
using SpecialFunctions: gamma
using StaticArrays
using QuadGK
using Sobol
using Zygote
using PhysicalConstants.CODATA2018
using Unitful
using PoissonRandom
using Interpolations
using PoissonRandom
using JSON
using ForwardDiff

using ..Spectral
using ..Medium
using ...Utils
using ...Types


c_vac_m_p_ns = ustrip(u"m/ns", SpeedOfLightInVacuum)

struct AngularEmissionProfile{U,T} end

struct CherenkovAngDistParameters{T<:Real}
    a::T
    b::T
    c::T
    d::T
end

# params for e-
STD_ANG_DIST_PARS = CherenkovAngDistParameters(4.27033, -6.02527, 0.29887, -0.00103)

"""
cherenkov_ang_dist(costheta, ref_index)

    Angular distribution of cherenkov photons for EM cascades.

    Taken from https://arxiv.org/pdf/1210.5140.pdf
"""
function cherenkov_ang_dist(
    costheta::Real,
    ref_index::Real,
    ang_dist_pars::CherenkovAngDistParameters=STD_ANG_DIST_PARS)

    cos_theta_c = 1 / ref_index
    a = ang_dist_pars.a
    b = ang_dist_pars.b
    c = ang_dist_pars.c
    d = ang_dist_pars.d

    return a * exp(b * abs(costheta - cos_theta_c)^c) + d
end


"""
    cherenkov_ang_dist_int(ref_index, lower, upper, ang_dist_pars)

Integral of the cherenkov angular distribution function.
"""

function _cherenkov_ang_dist_int(
    ref_index::Real,
    lower::Real=-1.0,
    upper::Real=1,
    ang_dist_pars::CherenkovAngDistParameters=STD_ANG_DIST_PARS)

    a = ang_dist_pars.a
    b = ang_dist_pars.b
    c = ang_dist_pars.c
    d = ang_dist_pars.d

    cos_theta_c = 1.0 / ref_index

    function indef_int(x)

        function lower_branch(x, cos_theta_c)
            return (1 / c * (c * d * x + (a * (cos_theta_c - x) * gamma(1 / c, -(b * (cos_theta_c - x)^c))) * (-(b * (cos_theta_c - x)^c))^(-1 / c)))
        end

        function upper_branch(x, cos_theta_c)
            return (1 / c * (c * d * x + (a * (cos_theta_c - x) * gamma(1 / c, -(b * (-cos_theta_c + x)^c))) * (-(b * (-cos_theta_c + x)^c))^(-1 / c)))
        end

        peak_val = lower_branch(cos_theta_c - 1e-5, cos_theta_c)

        if x <= cos_theta_c
            return lower_branch(x, cos_theta_c)
        else
            return upper_branch(x, cos_theta_c) + 2 * peak_val
        end
    end

    return indef_int(upper) - indef_int(lower)
end

struct ChAngDistInt
    interpolation
end

function interp_ch_ang_dist_int()
    ref_ixs = 1.1:0.01:1.5
    A = map(rfx -> _cherenkov_ang_dist_int(rfx, -1, 1), ref_ixs)
    ChAngDistInt(LinearInterpolation(ref_ixs, A))
end

(f::ChAngDistInt)(ref_ix::Real) = f.interpolation(ref_ix)
cherenkov_ang_dist_int = interp_ch_ang_dist_int()


@with_kw struct LongitudinalParameters
    alpha::Float64
    beta::Float64
    b::Float64
end

const LongitudinalParametersEMinus = LongitudinalParameters(alpha=2.01849, beta=1.45469, b=0.63207)
const LongitudinalParametersEPlus = LongitudinalParameters(alpha=2.00035, beta=1.45501, b=0.63008)
const LongitudinalParametersGamma = LongitudinalParameters(alpha=2.83923, beta=1.34031, b=0.64526)

@with_kw struct LongitudinalParameterisation{T<:Real}
    a::T
    b::T
    lrad::T
end

JSON.lower(p::LongitudinalParameterisation) = [p.a, p.b, p.lrad]

function LongitudinalParameterisation(energy::T, medium::MediumProperties, long_pars::LongitudinalParameters) where {T<:Real}
    b = T(long_parameter_b_edep(energy, long_pars))
    a = T(long_parameter_a_edep(energy, long_pars))

    unit_conv = 10 # g/cm^2 / "kg/m^3" in m
    lrad = radiation_length(medium) / material_density(medium) * unit_conv

    LongitudinalParameterisation(a, b, lrad)
end

LongitudinalParameterisation(energy::T, medium::MediumProperties, ::Type{ptype}) where {T<:Real,ptype<:ParticleType} = LongitudinalParameterisation(
    energy, medium, get_longitudinal_params(ptype))



@with_kw struct CherenkovTrackLengthParameters
    alpha::Float64 # cm
    beta::Float64
    alpha_dev::Float64 # cm
    beta_dev::Float64
end

const CherenkovTrackLengthParametersEMinus = CherenkovTrackLengthParameters(
    alpha=5.3207078881,
    beta=1.00000211,
    alpha_dev=0.0578170887,
    beta_dev=0.5
)

const CherenkovTrackLengthParametersEPlus = CherenkovTrackLengthParameters(
    alpha=5.3211320598,
    beta=0.99999254,
    alpha_dev=0.0573419669,
    beta_dev=0.5
)

const CherenkovTrackLengthParametersGamma = CherenkovTrackLengthParameters(
    alpha=5.3208540905,
    beta=0.99999877,
    alpha_dev=0.0578170887,
    beta_dev=5.66586567
)

@with_kw struct LightyieldParametrisation
    longitudinal::LongitudinalParameters
    track_length::CherenkovTrackLengthParameters
end


get_longitudinal_params(::Type{PEPlus}) = LongitudinalParametersEPlus
get_longitudinal_params(::Type{PEMinus}) = LongitudinalParametersEMinus
get_longitudinal_params(::Type{PGamma}) = LongitudinalParametersGamma

get_track_length_params(::Type{PEPlus}) = CherenkovTrackLengthParametersEPlus
get_track_length_params(::Type{PEMinus}) = CherenkovTrackLengthParametersEMinus
get_track_length_params(::Type{PGamma}) = CherenkovTrackLengthParametersGamma

function long_parameter_a_edep(
    energy::Real,
    long_pars::LongitudinalParameters
)
    long_pars.alpha + long_pars.beta * log10(energy)
end
long_parameter_a_edep(energy::Real, ::Type{ptype}) where {ptype<:ParticleType} = long_parameter_a_edep(energy, get_longitudinal_params(ptype))

long_parameter_b_edep(::Real, long_pars::LongitudinalParameters) = long_pars.b
long_parameter_b_edep(energy::Real, ::Type{ptype}) where {ptype<:ParticleType} = long_parameter_b_edep(energy, get_longitudinal_params(ptype))


"""
    longitudinal_profile(z::Real, medium::MediumProperties, long_pars::LongitudinalParameters)

Longitudinal shower profile (PDF) at shower depth z ( in m )
"""
function longitudinal_profile(z::Real, long_param::LongitudinalParameterisation)

    a = long_param.a
    b = long_param.b
    lrad = long_param.lrad

    t = z / lrad

    b * ((t * b)^(a - 1.0) * exp(-(t * b)) / gamma(a))
end

"""
    longitudinal_profile(energy::Real, z::Real, medium::MediumProperties, long_pars::LongitudinalParameters)

energy in GeV, z in m,
"""

function longitudinal_profile(
    energy::Real, z::Real, medium::MediumProperties, long_pars::LongitudinalParameters)
    long_param = LongitudinalParameterisation(energy, medium, long_pars)
    longitudinal_profile(z, long_param)

end

function longitudinal_profile(
    energy, z, medium, ::Type{ptype}) where {ptype<:ParticleType}
    longitudinal_profile(energy, z, medium, get_longitudinal_params(ptype))
end

"""
    gamma_cdf(a, b, z)

Cumulative Gamma distribution
\$ int_0^z Gamma(a, b) \$
"""
gamma_cdf(a, b, z) = 1.0 - gamma(a, b * z) / gamma(a)


"""
    integral_long_profile(z_low::Real, z_high::Real, long_param::LongitudinalParameterisation)

Integral of the longitudinal profile from shower depth z_low (in m) to z_high
"""
function integral_long_profile(z_low::Real, z_high::Real, long_param::LongitudinalParameterisation)
    a = long_param.a
    b = long_param.b
    lrad = long_param.lrad

    t_low = z_low / lrad
    t_high = z_high / lrad
    gamma_cdf(a, b, t_high) - gamma_cdf(a, b, t_low)
end

function integral_long_profile(energy::Real, z_low::Real, z_high::Real, medium::MediumProperties, long_pars::LongitudinalParameters)
    long_param = LongitudinalParameterisation(energy, medium, long_pars)
    integral_long_profile(z_low, z_high, long_param)
end

function integral_long_profile(energy::Real, z_low::Real, z_high::Real, medium::MediumProperties, ::Type{ptype}) where {ptype<:ParticleType}
    integral_long_profile(energy, z_low, z_high, medium, get_longitudinal_params(ptype))
end


function fractional_contrib_long!(
    z_grid::AbstractVector{T},
    long_param::LongitudinalParameterisation,
    output::Union{Zygote.Buffer,AbstractVector{T}}
) where {T<:Real}
    if length(z_grid) != length(output)
        error("Grid and output are not of the same length")
    end

    norm = integral_long_profile(z_grid[1], z_grid[end], long_param)

    output[1] = 0
    @inbounds for i in 1:size(z_grid, 1)-1
        output[i+1] = (
            1 / norm * integral_long_profile(z_grid[i], z_grid[i+1], long_param)
        )
    end
    output
end

function fractional_contrib_long!(
    energy::Real,
    z_grid::AbstractVector{T},
    medium::MediumProperties,
    long_pars::LongitudinalParameters,
    output::Union{Zygote.Buffer,AbstractVector{T}}
) where {T<:Real}

    long_param = LongitudinalParameterisation(energy, medium, long_pars)
    fractional_contrib_long!(z_grid, long_param, output)
end

function fractional_contrib_long!(
    energy,
    z_grid,
    medium,
    ::Type{ptype},
    output) where {ptype<:ParticleType}
    fractional_contrib_long!(energy, z_grid, medium, get_longitudinal_params(ptype), output)
end

function fractional_contrib_long(
    energy::Real,
    z_grid::AbstractVector{T},
    medium::MediumProperties,
    pars_or_ptype::Union{LongitudinalParameters,ptype}
) where {T<:Real,ptype}
    output = similar(z_grid)
    fractional_contrib_long!(energy, z_grid, medium, pars_or_ptype, output)
end



function cascade_cherenkov_track_length_dev(energy::Real, track_len_params::CherenkovTrackLengthParameters)
    track_len_params.alpha_dev * energy^track_len_params.beta_dev
end
cascade_cherenkov_track_length_dev(energy::Real, ::Type{ptype}) where {ptype<:ParticleType} = cascade_cherenkov_track_length_dev(energy, get_track_length_params(ptype))

"""
    cascade_cherenkov_track_length(energy::Real, track_len_params::CherenkovTrackLengthParameters)

Cherenkov track length for cascades.
energy in GeV

returns track length in m
"""
function cascade_cherenkov_track_length(energy::Real, track_len_params::CherenkovTrackLengthParameters)
    track_len_params.alpha * energy^track_len_params.beta
end


function cascade_cherenkov_track_length(energy::Real, ::Type{ptype}) where {ptype<:ParticleType}
    return cascade_cherenkov_track_length(energy, get_track_length_params(ptype))
end


"""
    rel_additional_track_length_params(ref_index)

Interpolate additional track length parameters, taken from
https://arxiv.org/pdf/1206.5530.pdf using E_cut = 500MeV
"""
function rel_additional_track_length_params(ref_index)

    xs = [1.30, 1.33, 1.36]
    λs = [0.1842, 0.1880, 0.1916]
    κs = [0.0204, 0.0206, 0.0207]

    slope_λ = (λs[end] - λs[1]) / (xs[end] - xs[1])
    slope_κ = (κs[end] - κs[1]) / (xs[end] - xs[1])

    λ = λs[1] + (ref_index - xs[1]) * slope_λ
    κ = κs[1] + (ref_index - xs[1]) * slope_κ

    return λ, κ
end

"""
    rel_additional_track_length(ref_index)
Calculate additional track length for muons.
From https://arxiv.org/pdf/1206.5530.pdf
"""
function rel_additional_track_length(ref_index, energy)
    λ, κ = rel_additional_track_length_params(ref_index)
    return λ + κ * log(energy)
end


function total_lightyield(::Track, energy::Number, length::Number, medium, wl_range)

    # This is probably correct...
    function integrand(wl)
        ref_ix = refractive_index(wl, medium)
        return frank_tamm(wl, ref_ix) * (1 + rel_additional_track_length(ref_ix, energy))
    end
    T = typeof(energy)
    total_contrib = integrate_gauss_quad(integrand, wl_range[1], wl_range[2]) * T(1E9) * length

    #=
    function integrand2(wl)
        lmu = frank_tamm_norm(wl_range, wl -> refractive_index(wl, medium))
        ref_ix = refractive_index(wl, medium)

        fadd(wl) = rel_additional_track_length(refractive_index(wl, medium), energy)
        dfadd(wl) = ForwardDiff.derivative(fadd, wl)

        return (
            frank_tamm(wl, ref_ix) * (1 + rel_additional_track_length(ref_ix, energy)) * 1E9 +
            lmu * dfadd(wl)
        )
    end

    total_contrib_full = integrate_gauss_quad(integrand2, wl_range[1], wl_range[2]) * length
    =#

    return total_contrib
end


function total_lightyield(::Track, particle::Particle, medium, wl_range)
    return total_lightyield(Track(), particle.energy, particle.length, medium, wl_range)
end

function total_lightyield(::Cascade, particle, medium, wl_range)
    total_contrib = (
        frank_tamm_norm(wl_range, wl -> refractive_index(wl, medium)) *
        cascade_cherenkov_track_length(particle.energy, particle.type)
    )
    return total_contrib
end


function total_lightyield(
    particle::Particle{PT,DT,ET,TT,LT,PType},
    medium::MediumProperties,
    wl_range
) where {PT,DT,ET,TT,LT,PType}
    return total_lightyield(particle_shape(PType), particle, medium, wl_range)
end


abstract type PhotonSource{T} end


function split_source(source::T, parts::Integer) where {T<:PhotonSource}
    if source.photons < parts
        error("Cannot split source. Fewer photons than parts")
    end

    ph_split, remainder = divrem(source.photons, parts)
    out_sources = Vector{T}(undef, parts)

    for i in 1:parts

        if i == parts
            nph = ph_split + remainder
        else
            nph = ph_split
        end

        out_fields = []
        for field in fieldnames(T)
            if field == :photons
                push!(out_fields, nph)
            else
                push!(out_fields, getfield(source, field))
            end
        end

        out_sources[i] = T(out_fields...)
    end

    return out_sources
end



"""
    oversample_source(em::T, factor::Number) where {T <: PhotonSource}

Return a new emitter of type `T` with number of photons increased by `factor`
"""
function oversample_source(em::T, factor::Number) where {T<:PhotonSource}
    args = []
    for field in fieldnames(T)
        if field == :photons
            push!(args, getfield(em, field) * factor)
        else
            push!(args, getfield(em, field))
        end
    end
    return T(args...)
end
struct AxiconeEmitter{T} <: PhotonSource{T}
    position::SVector{3,T}
    direction::SVector{3,T}
    time::T
    photons::Int64
    angle::T
end

struct PencilEmitter{T} <: PhotonSource{T}
    position::SVector{3,T}
    direction::SVector{3,T}
    beam_divergence::T
    time::T
    photons::Int64

end

struct PointlikeIsotropicEmitter{T} <: PhotonSource{T}
    position::SVector{3,T}
    time::T
    photons::Int64
end


JSON.lower(e::PointlikeIsotropicEmitter) = Dict(
    "position" => e.position,
    "time" => e.time,
    "photons" => e.photons,
)

struct PointlikeTimeRangeEmitter{T,U} <: PhotonSource{T}
    position::SVector{3,T}
    time_range::Tuple{U,U}
    photons::Int64
end

JSON.lower(e::PointlikeTimeRangeEmitter) = Dict(
    "position" => e.position,
    "time_range" => e.time_range,
    "photons" => e.photons,
)

abstract type CherenkovEmitter{T} <: PhotonSource{T} end

struct ExtendedCherenkovEmitter{T} <: CherenkovEmitter{T}
    position::SVector{3,T}
    direction::SVector{3,T}
    time::T
    photons::Int64
    long_param::LongitudinalParameterisation{T}
end

function ExtendedCherenkovEmitter(
    particle::Particle,
    medium::MediumProperties,
    wl_range::Tuple{T,T};
    oversample=1.0
) where {T<:Real}

    long_param = LongitudinalParameterisation(particle.energy, medium, particle.type)
    photons = pois_rand(total_lightyield(particle, medium, wl_range) * oversample)

    ExtendedCherenkovEmitter(particle.position, particle.direction, particle.time, photons, long_param)
end

JSON.lower(e::ExtendedCherenkovEmitter) = Dict(
    "position" => e.position,
    "direction" => e.direction,
    "time" => e.time,
    "photons" => e.photons,
    "long_param" => e.long_param,
)

struct PointlikeCherenkovEmitter{T} <: CherenkovEmitter{T}
    position::SVector{3,T}
    direction::SVector{3,T}
    time::T
    photons::Int64
end

function PointlikeCherenkovEmitter(
    particle::Particle,
    medium::MediumProperties,
    wl_range::Tuple{T,T}) where {T<:Real}

    photons = pois_rand(total_lightyield(particle, medium, wl_range))
    PointlikeCherenkovEmitter(particle.position, particle.direction, particle.time, photons)
end

function PointlikeCherenkovEmitter(particle::Particle, photons::Integer)
    PointlikeCherenkovEmitter(particle.position, particle.direction, particle.time, photons)
end

JSON.lower(e::PointlikeCherenkovEmitter) = Dict(
    "position" => e.position,
    "direction" => e.direction,
    "time" => e.time,
    "photons" => e.photons,
)


struct CherenkovTrackEmitter{T} <: CherenkovEmitter{T}
    position::SVector{3,T}
    direction::SVector{3,T}
    time::T
    length::T
    photons::Int64
end

function CherenkovTrackEmitter(particle::Particle{T}, medium::MediumProperties, wl_range::Tuple{T,T}) where {T<:Real}
    n_photons = pois_rand(total_lightyield(particle, medium, wl_range))
    return CherenkovTrackEmitter(particle.position, particle.direction, particle.time, particle.length, n_photons)
end


end
