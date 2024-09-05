function hess!(hess::Matrix{T}, x::Vector{T}, _nllh::Function, model_info::ModelInfo,
               cfg::ForwardDiff.HessianConfig)::Nothing where T <: AbstractFloat
    @unpack prior_info, θ_indices, simulation_info = model_info

    # If Hessian computation failed a zero Hessian is returned
    simulation_info.could_solve[1] = true
    if _could_solveode_nllh(simulation_info)
        try
            ForwardDiff.hessian!(hess, _nllh, x, cfg)
            @views hess .= Symmetric(hess)
        catch
            fill!(hess, 0.0)
        end
    else
        fill!(hess, 0.0)
    end
    if simulation_info.could_solve[1] != true
        fill!(hess, 0.0)
        return nothing
    end
    return nothing
end

function hess_split!(hess::Matrix{T}, x::Vector{T}, _nllh::Function, model_info::ModelInfo;
                     cids::Vector{Symbol} = [:all])::Nothing where T <: AbstractFloat
    @unpack simulation_info, θ_indices, prior_info = model_info

    # If Hessian computation failed a zero Hessian is returned. Here a Hessian is computed
    # for each condition-id, only using parameter present for said condition
    simulation_info.could_solve[1] = true
    fill!(hess, 0.0)
    for (i, cid) in pairs(simulation_info.conditionids[:experiment])
        simid = simulation_info.conditionids[:simulation][i]
        ix_simid = _get_ixdynamic_simid(simid, θ_indices; full_x = true)
        xinput = x[ix_simid]

        hess_tmp = zeros(eltype(x), length(xinput), length(xinput))
        _nllh_cid = (_xinput) -> begin
            _x = convert.(eltype(_xinput), x)
            _x[ix_simid] .= _xinput
            return _nllh(_x, [cid])
        end
        try
            ForwardDiff.hessian!(hess_tmp, _nllh_cid, xinput)
        catch
            fill(hess, 0.0)
            return nothing
        end
        for i in eachindex(ix_simid)
            for j in eachindex(ix_simid)
                hess[ix_simid[i], ix_simid[j]] += hess_tmp[i, j]
            end
        end
    end
    if simulation_info.could_solve[1] != true
        fill!(hess, 0.0)
        return nothing
    end
    return nothing
end

function hess_block!(hess::Matrix{T}, x::Vector{T}, _nllh_not_solveode::Function,
                     _nllh_solveode::Function, probinfo::PEtabODEProblemInfo,
                     model_info::ModelInfo, cfg::ForwardDiff.HessianConfig;
                     cids::Vector{Symbol} = [:all])::Nothing where T <: AbstractFloat
    @unpack simulation_info, θ_indices, prior_info = model_info
    cache = probinfo.cache
    split_x!(x, θ_indices, cache)
    xdynamic = cache.xdynamic

    # If Hessian computation failed a zero Hessian is returned.
    simulation_info.could_solve[1] = true
    fill!(hess, 0.0)
    try
        # Even if xdynamic is empty the ODE must be solved to get the Hessian of the
        # parameters not appearing in the ODE
        if !isempty(xdynamic)
            ix = θ_indices.xindices[:dynamic]
            @views ForwardDiff.hessian!(hess[ix, ix], _nllh_solveode, xdynamic, cfg)
        else
            _nllh_solveode(xdynamic)
        end
    catch
        fill!(hess, 0.0)
        return nothing
    end
    if simulation_info.could_solve[1] != true
        fill!(hess, 0.0)
        return nothing
    end

    ix_notode = θ_indices.xindices[:not_system]
    x_notode = @view x[ix_notode]
    @views ForwardDiff.hessian!(hess[ix_notode, ix_notode], _nllh_not_solveode, x_notode)
    return nothing
end

function hess_block_split!(hess::Matrix{T}, x::Vector{T}, _nllh_not_solveode::Function,
                           _nllh_solveode::Function, probinfo::PEtabODEProblemInfo,
                           model_info::ModelInfo; cids::Vector{Symbol} = [:all])::Nothing where T <: AbstractFloat
    @unpack simulation_info, θ_indices, prior_info = model_info
    cache = probinfo.cache
    split_x!(x, θ_indices, cache)
    xdynamic = cache.xdynamic

    # If Hessian computation failed a zero Hessian is returned. Here a Hessian is computed
    # for each condition-id, only using parameter present for said condition
    simulation_info.could_solve[1] = true
    fill!(hess, 0.0)
    for (i, cid) in pairs(simulation_info.conditionids[:experiment])
        simid = simulation_info.conditionids[:simulation][i]
        ixdynamic_simid = _get_ixdynamic_simid(simid, θ_indices)
        xinput = x[ixdynamic_simid]

        hess_tmp = zeros(eltype(x), length(xinput), length(xinput))
        _nllh_cid = (_xinput) -> begin
            _x = convert.(eltype(_xinput), xdynamic)
            _x[ixdynamic_simid] .= _xinput
            return _nllh_solveode(_x, [cid])
        end
        try
            ForwardDiff.hessian!(hess_tmp, _nllh_cid, xinput)
        catch
            fill!(hess, 0.0)
            return nothing
        end
        for i in eachindex(ixdynamic_simid)
            for j in eachindex(ixdynamic_simid)
                hess[ixdynamic_simid[i], ixdynamic_simid[j]] += hess_tmp[i, j]
            end
        end
    end
    if simulation_info.could_solve[1] != true
        fill!(hess, 0.0)
        return nothing
    end

    ix_notode = θ_indices.xindices[:not_system]
    x_notode = @view x[ix_notode]
    @views ForwardDiff.hessian!(hess[ix_notode, ix_notode], _nllh_not_solveode, x_notode)
    return nothing
end

function hess_GN!(out::Matrix{T}, x::Vector{T}, _residuals_not_solveode::Function,
                  _solve_conditions!::Function, probinfo::PEtabODEProblemInfo,
                  model_info::ModelInfo, cfg::ForwardDiff.JacobianConfig,
                  cfg_not_solve_ode::ForwardDiff.JacobianConfig; ret_jacobian::Bool = false,
                  cids::Vector{Symbol} = [:all], isremade::Bool = false)::Nothing where T <: AbstractFloat
    @unpack θ_indices, prior_info = model_info
    cache = probinfo.cache
    @unpack jacobian_gn, residuals_gn = cache

    fill!(out, 0.0)
    fill!(jacobian_gn, 0.0)
    split_x!(x, θ_indices, cache)
    _jac = @view jacobian_gn[θ_indices.xindices[:dynamic], :]
    _jac_residuals_xdynamic!(_jac, _solve_conditions!, probinfo, model_info, cfg;
                             cids = cids, isremade = isremade)
    # Happens when at least one forward pass fails
    if !isempty(cache.xdynamic) && all(_jac .== 0.0)
        return nothing
    end

    x_notode = @view x[θ_indices.xindices[:not_system]]
    @views ForwardDiff.jacobian!(jacobian_gn[θ_indices.xindices[:not_system], :]',
                                 _residuals_not_solveode, residuals_gn, x_notode,
                                 cfg_not_solve_ode)

    # In case of testing we might want to return the jacobian, else we are interested
    # in the Guass-Newton approximaiton.
    if ret_jacobian == false
        out .= jacobian_gn * transpose(jacobian_gn)
    else
        out .= jacobian_gn
    end
    return nothing
end
