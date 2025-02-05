struct Jacobian{T <: Number}
    data::AbstractArray{T, 2}
    data_mean::Vector{T}
    importance_weights::Union{Vector{<:Real}, Nothing}
    function Jacobian(m::AbstractMatrix{T}; importance_weights=nothing, mean_=nothing) where T <: Number
        if mean_ === nothing
            data_mean = wmean(m; weights=importance_weights, dims=1)
        else
            data_mean = reshape(mean_, 1, :)
        end
        
        m = m .- data_mean
        return Jacobian(m, data_mean[1, :]; importance_weights)
    end
    function Jacobian(m::AbstractMatrix{T}, data_mean::Vector{T}; importance_weights=nothing) where T <: Number
        if importance_weights !== nothing
            m = m .* sqrt.(importance_weights)
        end
        return new{T}(m, data_mean, importance_weights)
    end
    function Jacobian(m::Vector{Vector{T}}; importance_weights=nothing, mean_=nothing) where T <: Number
        m, data_mean = convert_to_matrix_without_mean(m; weights=importance_weights, mean_)
        return Jacobian(m, data_mean; importance_weights)
    end
end

Base.size(J::Jacobian) = size(J.data)
Base.size(J::Jacobian, i) = size(J.data, i)
nr_parameters(J::Jacobian) = size(J.data, 2)
nr_samples(J::Jacobian) = size(J.data, 1)

Base.length(J::Jacobian) = size(J.data, 1)
function get_importance_weights(J::Jacobian)
    if J.importance_weights === nothing
        return ones(nr_samples(J))
    else
        return J.importance_weights
    end
end

function centered(J::Jacobian; mode=:importance_sqrt)
    if J.importance_weights === nothing
        return J.data
    end
    if mode == :importance_sqrt
        return J.data
    elseif mode == :importance
        return J.data .* sqrt.(J.importance_weights)
    elseif mode == :no_importance
        return J.data ./ sqrt.(J.importance_weights)
    else
        error("mode should be :importance_sqrt, :importance or :no_importance. $mode was given.")
    end
end
    
function uncentered(J::Jacobian)
    Jd = centered(J; mode=:no_importance)
    return Jd .+ reshape(J.data_mean, 1, :)
end

Statistics.mean(J::Jacobian) = J.data_mean

function dense_T(G::Jacobian)
    J = centered(G)
    # J * J' is slow, so we use BLAS.gemm! instead
    C = Matrix{eltype(J)}(undef, size(J, 1), size(J, 1))
    return BLAS.gemm!('N', 'C', 1., J, J, 0., C)
end

function dense_S(G::Jacobian)
    J = centered(G)
    # (J' * J) ./ nr_parameters(G)
    C = Matrix{eltype(G)}(undef, size(J, 2), size(J, 2))
    return BLAS.gemm!('T', 'N', 1/nr_samples(G), J, J, 0., C)
end

mutable struct NaturalGradient{T <: Number}
    samples
    J::Jacobian{T}
    Es::EnergySummary
    logψσs::Vector{Complex{Float64}}
    grad
    θdot
    tdvp_error::Union{Real, Nothing}
    importance_weights::Union{Vector{<:Real}, Nothing}
    saved_properties
    function NaturalGradient(samples, J::Jacobian{T}, Es::EnergySummary,
         logψσs::Vector{Complex{Float64}}, θdot=nothing,
          tdvp_error::Union{Float64, Nothing}=nothing;
          importance_weights=nothing, grad=nothing, saved_properties=nothing) where {T <: Number}

        return new{T}(samples, J, Es, logψσs, grad, θdot, tdvp_error, importance_weights, saved_properties)
    end
end
function convert_to_vector(samples::Matrix{T}) where T <: Integer
    return [Vector{T}(samples[i, :]) for i in 1:size(samples, 1)]
end

Base.length(sr::NaturalGradient) = length(sr.Es)
Base.show(io::IO, sr::NaturalGradient) = print(io, "NaturalGradient($(sr.Es), tdvp_error=$(sr.tdvp_error))")


function get_θdot(sr::NaturalGradient; θtype=ComplexF64)
    if eltype(sr.θdot) <: Real
        return real(θtype).(sr.θdot)
    else
        if θtype <: Real
            return θtype.(real.(sr.θdot))
        else
            return sr.θdot
        end
    end
end

function centered(Oks::Vector{Vector{T}}) where T <: Number
    m = mean(Oks)
    return [ok .- m for ok in Oks]
end

function NaturalGradient(θ::Vector, Oks_and_Eks; sample_nr=100, timer=TimerOutput(), kwargs_Oks_and_Eks=Dict(), kwargs...)
    out = @timeit timer "Oks_and_Eks" Oks_and_Eks(θ, sample_nr; kwargs_Oks_and_Eks...)
    kwargs = Dict{Any, Any}(kwargs...)
    saved_properties = Dict{Symbol, Any}()

    if haskey(out, :Eks)
        Eks = out[:Eks]
    else error("Oks_and_Eks should return Dict with key :Eks") end
    if haskey(out, :Oks)
        Oks = out[:Oks]
    else error("Oks_and_Eks should return Dict with key :Oks") end
    if haskey(out, :logψs)
        logψσs = out[:logψs]
    else error("Oks_and_Eks should return Dict with key :logψs") end
    if haskey(out, :samples)
        samples = out[:samples]
    else error("Oks_and_Eks should return Dict with key :samples") end
    if haskey(out, :weights)
        kwargs[:importance_weights] = out[:weights]
    end

    for key in keys(out)
        if !(key in [:Eks, :Oks, :logψs, :samples, :weights])
            saved_properties[key] = out[key]
        end
    end
    kwargs[:saved_properties] = saved_properties

    #if length(out) == 4
    #    Oks, Eks, logψσs, samples = out
    #elseif length(out) == 5
    #    Oks, Eks, logψσs, samples, kwargs[:importance_weights] = out
    #else 
    #    error("Oks_and_Eks should return 4 or 5 values. If 4 are returned, importance_weights is assumed to be  equal to 1.")
    #end

    if Oks isa Tuple
        @assert length(Oks) == 2 "Oks should be a Tuple with 2 elements, Oks and Oks_mean"
        Oks, kwargs[:Oks_mean] = Oks
    end

    if Eks isa Tuple
        @assert length(Eks) == 3 "Eks should be a Tuple with 3 elements, Eks, Ek_mean and Ek_var"
        Eks, kwargs[:Eks_mean], kwargs[:Eks_var] = Eks
    end

    NaturalGradient(Oks, Eks, logψσs, samples; timer, kwargs...)
end

function NaturalGradient(Oks, Eks::Vector, logψσs::Vector, samples;
    importance_weights=nothing, Eks_mean=nothing, Eks_var=nothing, Oks_mean=nothing,
    solver=nothing, discard_outliers=0., timer=TimerOutput(), verbose=true, saved_properties=nothing) 

    if importance_weights !== nothing
        importance_weights ./= mean(importance_weights)
    end

    if discard_outliers > 0
        Eks, Oks, logψσs, samples, importance_weights = remove_outliers!(Eks, Oks, logψσs, samples, importance_weights; importance_weights, cut=discard_outliers, verbose)
    end
    
    Es = EnergySummary(Eks; importance_weights, mean_=Eks_mean, var_=Eks_var)
    J = @timeit timer "copy Oks" Jacobian(Oks; importance_weights, mean_=Oks_mean)

    sr = NaturalGradient(samples, J, Es, logψσs; importance_weights, saved_properties)

    if solver !== nothing
        @timeit timer "solver" solver(sr)
    end

    return sr
end

function get_gradient(sr::NaturalGradient)
    if sr.grad === nothing
        sr.grad = centered(sr.J)' * centered(sr.Es) .* (2/ length(sr.Es))
    end
    return sr.grad
end


function tdvp_error(sr::NaturalGradient)
    return tdvp_error(sr.J, sr.Es, get_gradient(sr)./2, sr.θdot)
end

function tdvp_error!(sr::NaturalGradient)
    sr.tdvp_error = tdvp_error(sr)
    return sr.tdvp_error
end


function tdvp_error(sr::NaturalGradient, SR_control::NaturalGradient)
    return tdvp_error(SR_control.J, SR_control.Es, get_gradient(SR_control)./2, sr.θdot)
end

function tdvp_error!(sr::NaturalGradient, SR_control::NaturalGradient)
    sr.tdvp_error = tdvp_error(sr, SR_control)
    return sr.tdvp_error
end

function tdvp_error(J::Jacobian, Es::EnergySummary, grad_half::Vector, θdot::Vector)
    var_E = var(Es)

    Eks_eff = -(centered(J) * θdot)
    Eks_eff = centered(Es) 
    var_eff_1 = -Eks_eff' * Eks_eff / (length(Es) - 1)

    f = length(Es) / (length(Es) - 1)
    var_eff_2 = θdot' * grad_half * f
    
    var_eff = var_eff_1 + real(var_eff_2)

    return 1 + var_eff/var_E/2
end

function tdvp_relative_error(sr::NaturalGradient)
    return tdvp_relative_error(sr.J, sr.Es, sr.θdot)
end

function tdvp_relative_error(sr::NaturalGradient, sr_control::NaturalGradient)
    return tdvp_relative_error(sr_control.J, sr_control.Es, sr.θdot)
end

function tdvp_relative_error(J::Jacobian, Es::EnergySummary, θdot::Vector)
    Eks_eff = -(centered(J) * θdot)
    Eks = centered(Es)
    relative_error = std(Eks_eff .- Eks) / (std(Eks) + 1e-10)
    return relative_error
end
