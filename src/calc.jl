
module Calc

using PhysicalConstants.CODATA2018
using PhysicsTools
using Unitful
using DataFrames
using LinearAlgebra
using ..Medium
using ..Detection
using ..Processing
using ..LightYield


const c_vac_m_ns = ustrip(u"m/ns", SpeedOfLightInVacuum)

export calc_time_residual!, calc_tgeo
export calc_time_residual_tracks!, calc_tgeo_tracks
export shift_to_closest_approach
export closest_approach_distance


calc_tgeo(distance, c_n::Number) = distance / c_n
calc_tgeo(distance, medium::MediumProperties) = calc_tgeo(distance, group_velocity(800.0, medium))

function calc_tgeo(distance::Real, target::PhotonTarget{<:Spherical}, c_n_or_medium)
    return  calc_tgeo(distance - target.shape.radius, c_n_or_medium)
end


function closest_approach_distance(p0, dir, pos)
    return norm(cross((pos .- p0), dir))
end

"""
    closest_approach_distance(particle, target)
Calculate closest approach distance for particle and target.

For cascade-like particles, this is the distance between particle position and target position,
for tracks this is the closest approach distance betwee track and target position
"""
function closest_approach_distance(particle, target)
    if particle_shape(particle) == Track()
        return closest_approach_distance(particle.position, particle.direction, target.shape.position)
    elseif particle_shape(particle) == Cascade()
        return norm(particle.position .- target.shape.position)
    end
end


function calc_tgeo_tracks(p0, dir, pos, n_ph, n_grp)

    dist = closest_approach_distance(p0, dir, pos)
    dpos = pos .- p0
    t_geo = 1 / c_vac_m_ns * (dot(dir, dpos) + dist * (n_grp * n_ph - 1) / sqrt((n_ph^2 - 1)))
    return t_geo
end


function calc_tgeo_tracks(p0, dir, pos, medium::MediumProperties)

    wl = 800.0
    n_ph = phase_refractive_index(wl, medium)
    n_grp = c_vac_m_ns / group_velocity(wl, medium)

    return calc_tgeo_tracks(p0, dir, pos, n_ph, n_grp)
end

function calc_tgeo(particle::Particle, target, medium)
    if particle_shape(particle) == Track()
        return calc_tgeo_tracks(particle.position, particle.direction, target.shape.position, medium)
    else
        return calc_tgeo(norm(particle.position .- target.shape.position), target, medium)
    end
end


function closest_approach_param(p0, dir, pos)

    # Vector from pos to p
    a = pos .- p0

    d = dot(a, dir)
    return d
end

function shift_to_closest_approach(particle::Particle, pos::AbstractVector)
    d = closest_approach_param(particle.position, particle.direction, pos)

    # Projection of a into particle direction
    pos_along = particle.position .+ d .* particle.direction

    t = particle.time .+ d / c_vac_m_ns

    return Particle(pos_along, particle.direction, t, particle.energy, particle.length, particle.type)
end
    


function calc_time_residual_tracks!(df::AbstractDataFrame, setup::PhotonPropSetup)

    targ_id_map = Dict([target.module_id => target for target in setup.targets])

    t0 = setup.sources[1].time
    for (key, subdf) in pairs(groupby(df, :module_id))
        target = targ_id_map[key.module_id]
        tgeo = calc_tgeo_tracks(
            setup.sources[1].position,
            setup.sources[1].direction,
            target.shape.position,
            setup.medium)

        subdf[!, :tres] = (subdf[:, :time] .- tgeo .- t0)
    end
end


function calc_time_residual_cascades!(df::AbstractDataFrame, setup::PhotonPropSetup)

    targ_id_map = Dict([target.module_id => target for target in setup.targets])

    t0 = setup.sources[1].time
    for (key, subdf) in pairs(groupby(df, :module_id))
        target = targ_id_map[key.module_id]
        distance = norm(setup.sources[1].position .- target.shape.position)
        tgeo = calc_tgeo(distance, target, setup.medium)

        subdf[!, :tres] = (subdf[:, :time] .- tgeo .- t0)
    end
end


function calc_time_residual!(df::AbstractDataFrame, setup::PhotonPropSetup)
    if eltype(setup.sources) <: CherenkovTrackEmitter
        return calc_time_residual_tracks!(df, setup)
    else
        return calc_time_residual_cascades!(df, setup)
    end

end
end