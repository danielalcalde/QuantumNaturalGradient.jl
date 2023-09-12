struct EnergySummary{T <: Number}
    data::Vector{T}
    mean::T
    std_of_mean::Float64
    var::Float64
    std_of_var::Float64
    importance_weights::Union{Vector{Float64}, Nothing}
end

EnergySummary(ψ::MPS, H::MPO; sample_nr=1000) = EnergySummary([Ek(ψ, H) for _ in 1:sample_nr])

function EnergySummary(Eks::Vector{Complex{Float64}}; importance_weights=nothing)
    if any(imag.(Eks) .> 1e-10)
        mean_ = wmean(Eks; weights=importance_weights)
        Eks_c = Eks .- mean_
        var_ = wvar(Eks_c; weights=importance_weights)

        local std_of_mean
        if importance_weights !== nothing
            Eks_c = Eks_c .* sqrt.(importance_weights)
            Eks_c2 = real.(Eks_c .* importance_weights)
            std_of_mean = std(Eks_c2)
            std_of_var = std(Eks_c2 .* conj(Eks_c2))
        else
            std_of_mean = sqrt(real.(var_))
            std_of_var = std(Eks_c .* conj(Eks_c))
        end
        return EnergySummary(Eks_c, mean_, std_of_mean, real.(var_), real.(std_of_var), importance_weights)
    end
    return EnergySummary(real.(Eks); importance_weights)
end

function EnergySummary(Eks::Vector{Float64}; importance_weights=nothing)
    local mean_, std_of_var
    mean_, var_ = wmean_and_var(Eks; weights=importance_weights)
    Eks_c = real.(Eks .- mean_)

    local std_of_mean
    if importance_weights !== nothing
        Eks_c = Eks_c .* sqrt.(importance_weights)
        Eks_c2 = real.(Eks_c .* importance_weights)
        std_of_mean = std(Eks_c2)
        std_of_var = std(Eks_c2 .* Eks_c2)
    else
        std_of_mean = sqrt(real.(var_))
        std_of_var = std(Eks_c .^ 2)
    end

    return EnergySummary(Eks_c, mean_, std_of_mean, var_, std_of_var, importance_weights)
end

Statistics.mean(Es::EnergySummary) = Es.mean
Statistics.var(Es::EnergySummary) = Es.var
Statistics.std(Es::EnergySummary) = sqrt(Es.var)
Base.length(Es::EnergySummary) = length(Es.data)

function get_importance_weights(Es::EnergySummary)
    if Es.importance_weights === nothing
        return ones(length(Es))
    else
        return Es.importance_weights
    end
end

energy_error(Es::EnergySummary) = Es.std_of_mean / sqrt(length(Es))
energy_var_error(Es::EnergySummary) = Es.std_of_var / sqrt(length(Es))

function centered(Es::EnergySummary; mode=:importance_sqrt)
    if mode == :importance_sqrt
        return Es.data
    elseif mode == :importance
        return Es.data .* sqrt.(Es.importance_weights)
    elseif mode == :no_importance
        return Es.data ./ sqrt.(Es.importance_weights)
    else
        error("mode should be :importance_sqrt, :importance or :no_importance. $mode was given.")
    end
end
function uncentered(Es::EnergySummary)
    Esd = centered(Es; mode=:no_importance)
    return Esd .+ Es.mean
end

function Base.show(io::IO, Es::EnergySummary)
    error = energy_error(Es)
    digits = Int(min(ceil(-log10(error)), 10)) + 1
    E_str = "E = $(round(real(Es.mean), digits=digits)) ± $(round(error, digits=digits))"

    error2 = energy_var_error(Es)
    digits = Int(min(ceil(-log10(error2)), 10)) + 1
    Evar_str = "var(E) = $(round(Es.var, digits=digits)) ± $(round(error2, digits=digits))"

    print(io, "EnergySummary($E_str, $Evar_str, Nₛ=$(length(Es)))")
end