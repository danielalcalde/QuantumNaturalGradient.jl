function random_unitary_tensor(link1, link2; eltype=Float64, rng=Random.default_rng())
    O = NDTensors.random_unitary(rng, eltype, dim(link1), dim(link2))
    T = reshape(O, (dim(link1), dim(link2)))
    return itensor(T, link1, link2)
end

function apply_link_unitaries(ψ, Us)
    ψ2 = copy(ψ)
    N = length(ψ2)
    @assert N - 1 == length(Us)
    for i in 1:N
        if i == 1
            ψ2[i] = ψ[i] * Us[1]
        elseif i == N
            ψ2[i] = ψ[i] * Us[N - 1]
        else
            ψ2[i] = ψ[i] * Us[i - 1] * Us[i]
        end
        
    end
    return ψ2
end

function randomize_links(ψ; kwargs...)
    ls = linkinds(ψ)
    Us = [random_unitary_tensor(l, l'; kwargs...) for l in ls]
    ψo = apply_link_unitaries(ψ, Us)
    ψo = prime(ψo, -1, linkinds(ψo))
    fix_indices!(ψo, ψ)
    return ψo
end