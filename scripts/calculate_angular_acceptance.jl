using CSV
using DataFrames
using CairoMakie
using PhysicsTools
using LinearAlgebra
using PhotonPropagation
using StaticArrays
using Glob
using HDF5
using Interpolations
using Distributions
using PhysicalConstants.CODATA2018
using Unitful
using Rotations
using LinearAlgebra
using JSON3
using Healpix
using StatsBase

function calc_coordinates!(df)
    pos_in = Matrix{Float64}(df[:, ["in_x", "in_y", "in_z"]])
    norm_in = norm.(eachrow(pos_in))
    pos_in_normed = pos_in ./ norm_in
   
    df[!, :in_norm_x] .= pos_in_normed[:, 1]
    df[!, :in_norm_y] .= pos_in_normed[:, 2]
    df[!, :in_norm_z] .= pos_in_normed[:, 3]

    in_p_cart = Matrix{Float64}((df[:, [:in_px, :in_py, :in_pz]]))

    norm_p = norm.(eachrow(in_p_cart))
    in_p_cart_norm = in_p_cart ./ norm_p

    df[!, :in_p_norm_x] .= in_p_cart_norm[:, 1]
    df[!, :in_p_norm_y] .= in_p_cart_norm[:, 2]
    df[!, :in_p_norm_z] .= in_p_cart_norm[:, 3]
   return df
end

function calc_pmt_coords()
    coords = Matrix{Float64}(undef, 2, 16)

    #upper 
    coords[1, 1:4] .= deg2rad(32.5)
    coords[2, 1:4] = (range(0; step=π / 2, length=4))

    # upper 2
    coords[1, 5:8] .= deg2rad(65)
    coords[2, 5:8] = (range(π / 4; step=π / 2, length=4))

    #lower 
    coords[1, 9:12] .= deg2rad(32.5)
    coords[2, 9:12] = (range(0; step=π / 2, length=4))
 
    # lower 2
    coords[1, 13:16] .= deg2rad(65)
    coords[2, 13:16] = (range(π / 4; step=π / 2, length=4))


    # Geant4 sets reference coordinates for the PMT placement to
    # e_x = [0, 0, 1]
    # e_y = [1, 0, 0]
    # Calculate rotation matrix and apply inverse rotation to get PMT coordinates in global frame

    R = calc_rot_matrix(SA[0.0, 1.0, 0.0], SA[1.0, 0.0, 0.0]) * calc_rot_matrix(SA[1.0, 0.0, 0.0], SA[0.0, 0.0, 1.0])

    center = [0.08, 0, 0]
    @views for col in eachcol(coords[:, 1:8])
        cart = sph_to_cart(col[1], col[2]) + center
        cart_shifted = cart / norm(cart)
        col[:] .= cart_to_sph((R' * cart_shifted)...)
    end

    center = [0.08, 0, 0]
    R = calc_rot_matrix(SA[0.0, 1.0, 0.0], SA[1.0, 0.0, 0.0]) * calc_rot_matrix(SA[1.0, 0.0, 0.0], SA[0.0, 0.0, -1.0])
    @views for col in eachcol(coords[:, 9:16])
        cart = sph_to_cart(col[1], col[2]) + center
        cart_shifted = cart / norm(cart)
        col[:] .= cart_to_sph((R' * cart_shifted)...)
    end

    coords = SMatrix{2,16}(coords)

    return coords
end


function build_acceptance_model(geant4_sims)

    coords = calc_pmt_coords()

    coords_cart = reduce(hcat, sph_to_cart.(eachcol(coords)))

    all_hc_1 = Vector{Float64}[]
    all_hc_2 = Vector{Float64}[]

    all_hc = [all_hc_1, all_hc_2]

    wavelengths = Float64[]
    total_acc_1 = Float64[]
    total_acc_2 = Float64[]

    for f in geant4_sims

        df = DataFrame(CSV.File(f))
        
        n_sim = nrow(df)
        wl = round(ustrip(u"nm", PlanckConstant * SpeedOfLightInVacuum ./ ( df[1, :in_E]u"eV")))
        push!(wavelengths, wl)
        calc_coordinates!(df)
  
        for pmt_ix in 1:16
            pmt_grp = get_pom_pmt_group(pmt_ix)

            pmt_coords = coords_cart[:, pmt_ix]

            in_pos_cart_norm = Matrix{Float64}(df[!, [:in_norm_x, :in_norm_y, :in_norm_z]])
            rel_costheta = dot.(eachrow(in_pos_cart_norm), Ref(pmt_coords))

            #=
            hit_pmt::BitVector = (
                (df[:, :out_VolumeName] .== "photocathode" .|| df[:, :out_VolumeName] .== "photocathodeTube") .&&
                df[:, :out_Volume_CopyNo] .== (pmt_ix-1)
                #df[:, :out_ProcessName] .== "OpAbsorption"
            )
            =#

            hit_pmt::BitVector = df[:, :pmt_Volume_CopyNo] .== (pmt_ix-1)
            
            rel_theta = acos.(rel_costheta[hit_pmt])

            push!(all_hc[pmt_grp], rel_theta)

        end
        
        any_hit = df[:, :pmt_Volume_CopyNo] .!= -1

        mask_grp_1 = any_hit .&& (div.(df[:, :out_Volume_CopyNo],  4) .% 2 .== 0)
        mask_grp_2 = any_hit .&& (div.(df[:, :out_Volume_CopyNo],  4) .% 2 .== 1)

        # mask_grp_1 / mask_grp_2 are the probabilities to hit any pmt from the PMT group
        # have to account the number of PMTs per group to get the probability for a specific pmt
        push!(total_acc_1, sum(mask_grp_1) / n_sim)
        push!(total_acc_2, sum(mask_grp_2) / n_sim)
    end

    wlsort = sortperm(wavelengths)

    wavelengths = wavelengths[wlsort]
    total_acc_1 = total_acc_1[wlsort]
    total_acc_2 = total_acc_2[wlsort]
    
    all_hc_1 = reduce(vcat, all_hc_1)
    all_hc_2 = reduce(vcat, all_hc_2)

    d1 = Distributions.fit(Rayleigh, all_hc_1[all_hc_1 .< 1]) 
    d2 = Distributions.fit(Rayleigh, all_hc_2[all_hc_2 .< 1]) 
    #d1 = Distributions.fit(Gamma, all_hc_1[all_hc_1 .< 1]) 
    #d2 = Distributions.fit(Gamma, all_hc_2[all_hc_2 .< 1]) 


    return total_acc_1, total_acc_2, wavelengths, d1, d2, all_hc_1, all_hc_2
end

sim_path = joinpath(ENV["ECAPSTOR"], "geant4_pmt/30cm_sphere/V15_ch/")
files = glob("*.csv", sim_path)

df = DataFrame(CSV.File("/home/wecapstor3/capn/capn100h/geant4_pmt/30cm_sphere/V15_ch/sim_320.csv"))

mask = df[:, :out_VolumeName] .== "photocathode"

total_acc_1, total_acc_2, wavelengths, d1, d2, all_hc_1, all_hc_2 = build_acceptance_model(files)


fig = Figure()
ax = Axis(fig[1, 1], xlabel="Angular Distance to PMT axis (rad)", ylabel="PDF")
bins = 0:0.05:π
colors = Makie.wong_colors()
hist!(ax, (reduce(vcat, all_hc_1)), bins=bins, label="PMT Group 1", normalization=:pdf, color=(colors[1], 0.7))
plot!(ax, d1)
hist!(ax, (reduce(vcat, all_hc_2)), bins=bins, label="PMT Group 2", normalization=:pdf, color=(colors[2], 0.7))
plot!(ax, d2)
axislegend()
#ylims!(ax, 1E-3, 10)
fig

fig = Figure()
ax = Axis(fig[1, 1], xlabel="Wavelength(nm)", ylabel="Acceptance (%)")
lines!(ax, wavelengths, total_acc_1*100, label="PMT Group 1")
lines!(ax, wavelengths, total_acc_2*100, label="PMT Group 2")
axislegend(position=:rb)
fig

qe = 0.25
correction_factor = 0.3^2 / 0.2159^2 

fig = Figure()
ax = Axis(fig[1, 1], xlabel="Wavelength(nm)", ylabel="Acceptance (%)",
    xminorgridvisible=true, yminorgridvisible=true, yminorticksvisible=true, xminorticksvisible=true)
lines!(ax, wavelengths, (total_acc_1 .+ total_acc_2) *100, label="Default")
lines!(ax, wavelengths, (total_acc_1 .+ total_acc_2) *100 * correction_factor, label="Corrected")
lines!(ax, wavelengths, (total_acc_1 .+ total_acc_2) *100 * correction_factor .* target.quantum_eff.rel_acceptance.(wavelengths), label="Corrected + QE")
axislegend(position=:rb)
fig


fig = Figure()
ax = Axis(fig[1, 1], xlabel="Wavelength(nm)", ylabel="QE * Acceptance (%)", xminorgridvisible=true, yminorgridvisible=true)
lines!(ax, wavelengths, (total_acc_1 .+ total_acc_2)*100*correction_factor.*target.quantum_eff.rel_acceptance.(wavelengths), label="PMT Group 1")
#lines!(ax, wavelengths, total_acc_2*100*correction_factor*qe, label="PMT Group 2")
#axislegend(position=:rb)
fig

import PythonCall
using CondaPkg
np = PythonCall.pyimport("numpy")

target = POM(SA_F32[0., 0., 10.], UInt16(1))
rot = RotMatrix3(I)
pmt_coords = get_pmt_positions(target, rot)

np.savez("pmt_acc.npz", acc_pmt_grp_1=total_acc_1, acc_pmt_grp_2=total_acc_2, wavelengths=wavelengths, sigma_grp_1=d1.σ, sigma_grp_2=d2.σ, pmt_coords=reduce(hcat, pmt_coords)')

fname = joinpath(@__DIR__, "../assets/pmt_acc.hd5")
h5open(fname, "w") do fid
    fid["acc_pmt_grp_1"] = total_acc_1
    fid["acc_pmt_grp_2"] = total_acc_2
    fid["wavelengths"] = wavelengths
    fid["sigma_grp_1"] = d1.σ 
    fid["sigma_grp_2"] = d2.σ
end

fname = joinpath(@__DIR__, "../assets/pmt_acc.hd5")
h5open(fname, "r") do fid
    fig = Figure()
    ax = Axis(fig[1, 1], xticks = WilkinsonTicks(8), xminorticks = IntervalsBetween(10), xminorticksvisible=true)
    lines!(ax, fid["wavelengths"][:], fid["acc_pmt_grp_1"][:])
    lines!(ax, fid["wavelengths"][:], fid["acc_pmt_grp_2"][:])
    fig
end


azimuth_hit = []

m_accepted = HealpixMap{Float64, RingOrder}(32)
m_all = HealpixMap{Float64, RingOrder}(32)
m_all[:] .= 0
m_accepted[:] .= 0

length(m_all)

coords_rot = []
for col in eachcol(coords)
    R = calc_rot_matrix(SA[0.0, 0.0, 1.0], SA[1.0, 0.0, 0.0])
    cart = sph_to_cart(col[1], col[2])
    col = cart_to_sph((R * cart)...)
    push!(coords_rot, col)
    
end
coords_rot = Matrix(reduce(hcat, coords_rot))

for f in files

    df = DataFrame(CSV.File(f))
    calc_coordinates!(df)

    in_dir_cart = Matrix{Float64}(df[!, [:in_norm_x, :in_norm_y, :in_norm_z]])
    R = calc_rot_matrix(SA[0.0, 0.0, 1.0], SA[1.0, 0.0, 0.0])
    in_dir_cart = Ref(R) .* eachrow(in_dir_cart)
    
    in_dir_sph = reduce(hcat, cart_to_sph.(in_dir_cart))
    
    any_hit = ((df[:, :out_VolumeName] .== "photocathode" .|| df[:, :out_VolumeName] .== "photocathodeTube")
          #df[:, :out_ProcessName] .== "OpAbsorption"
    )

    pix_id = map(x -> ang2pix(m_all, vec2ang(x...)...), in_dir_cart)
    pix_id_accepted = pix_id[any_hit]
    m_accepted .+= counts(pix_id_accepted, 1:length(m_accepted))
    m_all .+= counts(pix_id, 1:length(m_all))

    push!(azimuth_hit, in_dir_sph[2, any_hit])
end

m_ratio = m_accepted / m_all
m_ratio[m_all .== 0] .= 0

fig = Figure()
ax = Axis(fig[1, 1], aspect=2)
img, mask, anymasked = mollweide(m_ratio)
hm = heatmap!(ax, img', show_axis = false)
hidespines!(ax)
hidedecorations!(ax)
# colat, long
coords_rot_lat = reduce(hcat, map(x -> collect(vec2ang(x...)), sph_to_cart.(eachcol(coords_rot))))
coords_rot_lat[1, :] = colat2lat.(coords_rot[1, :])
coords_rot_lat[2, :] .-= π


coords_proj = Point2f.(map(x -> collect(mollweideproj(x...)[[2,3]]), eachcol(coords_rot_lat)))
coords_proj ./= 2
coords_proj .+= Ref([0.5, 0.5])
relative_projection = Makie.camrelative(ax.scene);

coords_proj
scatter!(relative_projection, coords_proj, color=:blue)
Colorbar(fig[2, 1], hm, vertical = false, label="Acceptance")
fig


azimuth_hit = reduce(vcat, azimuth_hit)

bins = 0:0.05:2*π
fig, ax, h = hist(azimuth_hit, bins=bins, axis=(xlabel="Azimuth angle [rad]", ylabel="Counts"))


#vlines!(ax, coords_rot[2, :], color=(:red, 0.5))
fig



rand(size(azimuth_hit))
uni_hits = rand(size(azimuth_hit)[1]).*2 .*π

fig = Figure()
ax = Axis3(fig[1, 1], aspect = (1, 1, 1), azimuth = deg2rad(30))
ax2 = Axis3(fig[1, 2], aspect = (1, 1, 1), azimuth = deg2rad(60))
coords_cart = Point3f.(sph_to_cart.(eachcol(Matrix(coords_rot))))

coords_cart[1:8] .+= Ref([2, 0, 0])
coords_cart[9:16] .-= Ref([2, 0, 0])
dirs_cart = Vec3f.(coords_cart)
arrows!(ax, 5 .*coords_cart, dirs_cart)
arrows!(ax2, 5 .*coords_cart, dirs_cart)
fig

ax2 = Axis3(fig[1, 2], aspect = (1, 1, 1), azimuth = deg2rad(60))
for coord in eachcol(coords_rot[:, 1:8])
    cc = sph_to_cart(coord)
    line = hcat(cc, 1.2*cc)
    arrows!(ax, cc..., cc...)
end


for coord in eachcol(coords_rot[:, 9:16])
    cc = sph_to_cart(coord)
    line = hcat(cc, 1.2*cc)
    lines!(ax, line, color=:blue)
    lines!(ax2, line, color=:blue)
end
fig


using DataFrames
using StaticArrays
using Rotations
using Random
using LinearAlgebra
using NeutrinoTelescopes
using PhotonPropagation
n = 5000000

function rand_sph(n)
    theta = acos.(2. *rand(n).-1)
    phi = 2 .* π.*rand(n)
    return theta, phi
end

target = POM(SA_F32[0., 0., 10.], UInt16(1))
medium = make_cascadia_medium_properties(0.95f0)
source = PointlikeIsotropicEmitter(SA_F32[0., 0., 0.], 0f0, 10000)
spectrum = Monochromatic(410f0)

normed_pos = sph_to_cart.(rand_sph(n)...)
positions = target.shape.radius .* normed_pos .+ Ref(target.shape.position)
directions = sph_to_cart.(rand_sph(n)...)
total_weights = ones(n)
photons = DataFrame(position=positions, direction=directions, total_weight=total_weights, module_id=ones(n), wavelength=fill(600, n))


seed = 1

# Setup propagation
setup = PhotonPropSetup([source], [target], medium, spectrum, seed, 1.)

hits = make_hits_from_photons(photons, setup, RotMatrix3(I))

acceptance_ratio = nrow(hits) / n

hit_normed_pos = (hits[:, :position] .- Ref(target.shape.position)) ./ target.shape.radius

m_accepted_param = HealpixMap{Float64, RingOrder}(16)
m_all_param = HealpixMap{Float64, RingOrder}(16)

m_accepted_param[:] .= 0
m_all_param[:] .= 0

pix_id_hit = map(x -> ang2pix(m_accepted_param, vec2ang(x...)...), hit_normed_pos)
m_accepted_param .+= counts(pix_id_hit, 1:length(m_accepted_param))

pix_id_hit = map(x -> ang2pix(m_all_param, vec2ang(x...)...), normed_pos)
m_all_param .+= counts(pix_id_hit, 1:length(m_all_param)) 

m_ratio = m_accepted_param / m_all_param

m_ratio

m_ratio[m_all_param .== 0] .= 0
fig = Figure()
ax = Axis(fig[1, 1], aspect=2)
img, mask, anymasked = mollweide(m_ratio, Dict("center"=>(π, 0)))

width = 720
height = 360



hm = heatmap!(ax, img', show_axis = false)
Colorbar(fig[2, 1], hm, vertical = false, label="Acceptance")
fig



unique(pix_id_hit)

any(isfinite.(img))

m_accepted_param

a = zeros(3)

a[[3, 3, 3, 3]] .+=1

a