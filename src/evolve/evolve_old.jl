function evolve_old(Oks_and_Eks_, θ::T;
    integrator=Euler(0.1), lr=nothing, solver=EigenSolver(1e-6),
    maxiter=10,
    callback = (args...; kwargs...) -> nothing,
    copy=true, sample_nr=1000,
    verbosity=0, save_params=false, save_rng=false,
    save_ng=false,
    misc_restart=nothing,
    discard_outliers=0.,
    transform=(args...) -> args,
    timer=TimerOutput()
    ) where {T}
    if lr !== nothing
        integrator = Euler(lr)
        @info "evolve: Warning lr is deprecated, use integrator=Euler(lr) instead"
    end

    if copy
        θ = deepcopy(θ)
    end

    if save_params
        history_params = Matrix{Float64}(undef, maxiter, length(θ))
    end

    if save_rng
        history_rng = Vector{Random.AbstractRNG}(undef, maxiter)
    end

    history = Matrix{Float64}(undef, maxiter, 7)
    # Restarting from a previous run
    niter_start = 1
    if misc_restart !== nothing
        history_old = misc_restart["history"]
        history[1:size(history_old, 1), :] = history_old

        if save_params
            history_params_old = misc_restart["history_params"]
            history_params[1:size(history_params_old, 1), :] = history_params_old
        end

        if save_rng
            history_rng_old = misc_restart["history_rng"]
            history_rng[1:length(history_rng_old)] = history_rng_old
        end

        niter_start = misc_restart["niter"] + 1
        if verbosity > 0
            @info "evolve: Restarting from niter = $niter_start"
        end
    end

    history_legend = Dict("energy" => 1, "var_energy" => 2, "sample_nr" => 3, "norm_grad" => 4, "norm_θ" => 5, "var_energy" => 6, "tdvp_error" => 7)
    misc = Dict()
    energy = 0.0
    dynamic_kwargs = Dict()
    for niter in niter_start:maxiter
        θ_old = θ
        θ, ng = @timeit timer "integrator" integrator(θ, Oks_and_Eks_; sample_nr, solver, discard_outliers, timer, dynamic_kwargs...)

        # Transform ng
        θ, ng, Oks_and_Eks_, solver, sample_nr = transform(θ, ng, Oks_and_Eks_, solver, sample_nr)

        # Compute energy
        energy = real(mean(ng.Es))
        var_energy = real(var(ng.Es))
        norm_grad = norm(get_θdot(ng; θtype=eltype(θ)))
        norm_θ = norm(θ_old)

        # Saving the energy and norms
        history[niter, :] .= energy, var_energy, length(ng), norm_grad, norm_θ, var(ng.Es), ng.tdvp_error
        if save_params
            history_params[niter, :] .= θ_old
        end
        if save_rng
            history_rng[niter] = copy(Random.default_rng())
        end

        # Callback
        misc = Dict("energy" => energy, "niter" => niter, "history" => history[1:niter, :],
                    "history_legend" => history_legend)
        if save_params
            misc["history_params"] = history_params[1:niter, :]
        end
        if save_ng
            misc["ng"] = ng
        end
        
        stop = callback(; energy_value=energy, model=θ, misc=misc, niter=niter)
        
        if verbosity >= 2
            @info "iter $niter: $(ng.Es), ‖∇f‖ = $(norm_grad), ‖θ‖ = $(norm_θ), tdvp_error = $(ng.tdvp_error)"
            flush(stdout)
            flush(stderr)
        end

        if stop === :stop
            break
        elseif stop isa Dict
            dynamic_kwargs = stop
        end
    end

    if verbosity >= 2
        @info "evolve: Done"
        show(timer)
    end

    return energy, θ, misc
end