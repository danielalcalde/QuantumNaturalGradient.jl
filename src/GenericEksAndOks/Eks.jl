abstract type AbstractTensorOperatorSum end

struct TensorOperatorSum <: AbstractTensorOperatorSum
    tensors::Vector{ITensor}
    hilbert::Array{<:Index}
    sites::Vector{Vector}
end
Base.size(t::TensorOperatorSum, args...) = size(t.hilbert, args...)
Base.ndims(t::TensorOperatorSum) = ndims(t.hilbert)

"""
    TensorOperatorSum(tensors, hilbert, sites)
    Generates a TensorOperatorSum from a hamiltonian and a hilbert space. It precomputes the sites where the operator acts on.
"""
function TensorOperatorSum(ham::OpSum, hilbert::Array; combine_tensors=true)
    
    tensors = Vector{ITensor}(undef, length(ham))
    sites = Vector{Vector{Int}}(undef, length(ham))
    hilbert_flat = hilbert
    if ndims(hilbert) > 1
        hilbert_flat = hilbert[:]
        ## Reduce dimensionality of hamiltonian to 1D for compatibility pourposes
        ham = reduce_dim(ham, size(hilbert))
    end
    
    for (i, o) in enumerate(ham)
        tensors[i] = ITensor(o, hilbert[:])
        sites[i] = get_active_sites(o)
    end
    tso = TensorOperatorSum(tensors, hilbert, sites)
    if combine_tensors
        tso = combine_tensors_at_same_site(tso)
    end
    return tso
end


function get_precomp_sOψ_elems_slow!(tensor::ITensor, sites::Vector, sample_, hilbert; sum_precompute=DefaultOrderedDict(()->0), offset=1, get_flip_sites=false)
    sample_r = sample_[sites]
    hilbert_r = hilbert[sites]
    
    indices_sample = collect(hi' => s for (hi, s) in zip(hilbert_r, sample_r)) # Selects the indices that act on the tensor from the left O|s>
    
    for sample_r2 in bitstring_permutations(length(sites))
        sample_r2 .+= offset
        indices = vcat(indices_sample, collect(hi => s for (hi, s) in zip(hilbert_r, sample_r2))) # <s'|
        vi = tensor[indices...] # <s'|O|s>
        if vi != 0.
            if get_flip_sites
                key = find_flip_site(sample_r .- offset, sample_r2 .- offset, sites)
            else
                sample_M = deepcopy(sample_)
                sample_M[sites] .= sample_r2
                key = sample_M .- offset
            end
            sum_precompute[key] += vi
            
        end
    end

    return sum_precompute
end

"""
Generates a Dictionary with the entries being (sample_config => energy_weight) so that Ek=sum energy_weight * exp(logψ(sample_config) - logψ(sample))
get_precomp_sOψ_elems(
    tensor::ITensor, 
    sites::Vector, 
    sample_, 
    hilbert; 
    sum_precompute = DefaultOrderedDict(()->0), 
    offset=1, 
    get_flip_sites=false # If true, it will give a Dictionary Dict(sites_flipped=>energy_weight) instead of Dict(s'=>energy_weight)
    sites_fliiped: First index is the site, second the new s'_i.
)
"""
function get_precomp_sOψ_elems!(tensor::ITensor, sites::Vector, sample_, hilbert; sum_precompute=DefaultOrderedDict(()->0), offset=1, get_flip_sites=false, fast=true)
    
    sample_r = sample_[sites]
    hilbert_r = hilbert[sites]
    
    indices_sample = collect(hi' => s for (hi, s) in zip(hilbert_r, sample_r)) # Selects the indices that act on the tensor from the left O|s>
    
    tensor_proj = onehot(indices_sample) * tensor
    
    # Make sure that the indices have the right permutation
    perm = NDTensors.getperm(ITensors.inds(tensor_proj), hilbert_r)
    tensor_proj = ITensor(permutedims(tensor_proj.tensor, perm))
    
    inds = findall(x-> x != 0, tensor_proj.tensor)
    for ind in inds
        sample_r2 = ind.I
        vi = tensor_proj[ind]
        if get_flip_sites
            key = find_flip_site(sample_r .- offset, sample_r2 .- offset, sites)
        else
            sample_M = deepcopy(sample_)
            sample_M[sites] .= sample_r2
            key = sample_M .- offset
        end
        sum_precompute[key] += vi
    end
    
    return sum_precompute
end

"""
find_flip_site([1, 2], [2,2], [4, 5])

1-element Vector{Any}:
 (4, 2)
"""
function find_flip_site(sample_orig, sample_shifted, sites)
    diffs = []
    for (i, s_orig, s_shift) in zip(sites, sample_orig, sample_shifted)
        if s_orig != s_shift
            push!(diffs, (i, s_shift))
        end
    end
    return diffs
end

function apply_flip_site(sample, patch)
    sample_c = copy(sample)
    for (index, value) in patch
        sample_c[index...] = value
    end
    return sample_c
end

function get_precomp_sOψ_elems(tso::Vector{TensorOperatorSum}, sample_::Array; sum_precompute = DefaultOrderedDict(()->0), offset=1, get_flip_sites=false)
    for tso_i in tso
        sum_precompute = get_precomp_sOψ_elems(tso_i, sample_; sum_precompute, offset, get_flip_sites)
    end
    return sum_precompute
end


function get_precomp_sOψ_elems(tso::TensorOperatorSum, sample_::Array{T, N}; sum_precompute=DefaultOrderedDict(()->0), offset=1, get_flip_sites=false, kwargs...) where {T <: Int, N}
    @assert size(sample_) == size(tso)
    sample_ = sample_[:] # Flatten the sample
    sample_ = sample_ .+ offset # Shift the sample from 0...N-1 to 1...N
    @assert all(sample_ .> 0) "Sample must be composed of positive integers instead of $sample_"
    
    for (tensor, sites) in zip(tso.tensors, tso.sites)
        get_precomp_sOψ_elems!(tensor, sites, sample_, tso.hilbert[:]; sum_precompute, offset, get_flip_sites, kwargs...)
    end
    
    # Remove zeros and make real if the imaginary part is too small
    for (key, value) in sum_precompute
        if value == 0.
            delete!(sum_precompute, key)
        elseif value isa Complex && abs(imag(value))/(abs(real(value))+1e-10) < 1e-14
            sum_precompute[key] = real(value)
        end
    end

    # If not 1D, reshape the samples
    if ndims(tso) > 1
        sum_precompute = increase_dim(sum_precompute, size(tso); get_flip_sites)
    end
    return sum_precompute
end

function inner_div_ψ(sample_, tso::TensorOperatorSum, logψ_func; logψ_sample=nothing)
    sum_precompute = get_precomp_sOψ_elems(tso, sample_)

    if logψ_sample === nothing
        logψ_sample = logψ_func(sample_)
    end
    
    O0 = 0
    if sample_ in keys(sum_precompute)
        O0 = sum_precompute[sample_]
        delete!(sum_precompute, sample_)
    end
    
    O = sum(weight * exp(logψ_func(sample_r) - logψ_sample) for (sample_r, weight) in sum_precompute; init=O0)
    if O isa Complex && abs(imag(O))/(abs(real(O))+1e-10) < 1e-14
        O = real(O)
    end
    return O
end

get_Ek(sample_, tso::TensorOperatorSum, logψ_func; logψ_sample=nothing) = inner_div_ψ(sample_, tso, logψ_func; logψ_sample)

inner_div_ψ(sample_, opsum::OpSum, logψ_func, hilbert; logψ_sample=nothing) = inner_div_ψ(sample_, TensorOperatorSum(opsum, hilbert), logψ_func; logψ_sample)
get_Ek(sample_, opsum::OpSum, logψ_func, hilbert; logψ_sample=nothing) = inner_div_ψ(sample_, opsum, logψ_func, hilbert; logψ_sample)

# TODO write a more general version for higher physical dimensions
function bitstring_permutations(n)
    ss = []
    for i = 0:2^n-1
       s = bitstring(i)
       s = s[end-n+1:end]
       s = [parse(Int, si) for si in s]
       push!(ss, s)
    end
    return ss
end

function get_active_sites(o::Scaled)
    return [a.sites[1] for a in ITensors.argument(o).args[1]]
end

## Reduce dimensionality of hamiltonian to 1D for compatibility pourposes
reduce_dim(O::Op, size::Tuple) = ITensors.Op(O.which_op, reduce_dim(O.sites[1], size))
reduce_dim(v::Vector, size::Tuple) = [reduce_dim(vi, size) for vi in v]
function reduce_dim(t::Tuple, size::Tuple)
    n = 0
    mul = 1
    for (ti, si) in zip(t, size)
        n += mul * (ti-1)
        mul *= si
    end
    return n + 1
end
function increase_dim(t::Integer, size::Tuple)
    n = t - 1
    t = []
    for si in size
        push!(t, n % si + 1)
        n ÷= si
    end
    return tuple(t...)
end

function increase_dim(sum_precompute, size_; get_flip_sites=false)
    sum_precompute2 = DefaultOrderedDict(()->0)
    if !get_flip_sites
        for (sample__, v) in sum_precompute
            sum_precompute2[reshape(sample__, size_)] += v
        end
    elseif get_flip_sites
        for (diff, v) in sum_precompute
            if diff isa Tuple
                sum_precompute2[diff] += v
            else
                diff_res = []
                for (i, s) in diff
                    push!(diff_res, (increase_dim(i, size_), s))
                end
                diff_res = Tuple(diff_res)
                sum_precompute2[diff_res] += v
            end
        end
    end
    return sum_precompute2
end

function reduce_dim!(O::ITensors.Scaled, size::Tuple)
    a = ITensors.argument(O)
    a.args[1] .= reduce_dim(a.args[1], size)
end

function reduce_dim(O::ITensors.OpSum, size::Tuple)
    O_c = deepcopy(O)
    for oi in O_c
        reduce_dim!(oi, size)
    end
    return O_c
end

second(x) = x[2]
function combine_tensors_at_same_site(tso::TensorOperatorSum)
    d = Dict()
    for (sites, tensor) in zip(tso.sites, tso.tensors)
        if sites in keys(d)
            d[sites] .+= tensor 
        else
            d[sites] = tensor         
        end
    end
    tensors_sites = collect(d)
    sites = first.(tensors_sites)
    tensors = second.(tensors_sites)
    return TensorOperatorSum(tensors, tso.hilbert, sites)
end