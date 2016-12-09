type ARMH_proposal

    support_points::Vector{Float64}
    prob_cache::Vector{Float64} # prob_cache[i] = scaled_true_pdf(support_points[i])

    slopes::Vector{Float64}
    intercepts::Vector{Float64}

    # segment_area[i] = area under support_points[i] - support_points[i-1], has one more element than support_points
    segment_area::Vector{Float64}
    total_area::Float64 # sum(segment_area)

    left_exp_slope::Float64
    left_exp_intercept::Float64
    right_exp_slope::Float64
    right_exp_intercept::Float64

    function ARMH_proposal()
        new( Float64[],
             Float64[], Float64[], Float64[],
             Vector{Float64}(Float64[]),
             0.0, 0.0, 0.0, 0.0, 0.0)
    end
end

"""
Used to cache various things the Gibbs sampler needs
"""
type GibbsSamplerState

    bn::BayesNet
    key_constructor_name_order::Array{Symbol,1}
    max_cache_size::Nullable{Integer}
    markov_blanket_cpds_cache::Dict{Symbol, Array{CPD}}
    markov_blanket_cache::Dict{Symbol, Vector{Symbol}}
    finite_distrbution_is_cacheable::Dict{Symbol, Bool}
    finite_distribution_cache::Dict{String, Array{Float64, 1}}
    AMH_support_point_cache::Dict{Symbol, ARMH_proposal}

    function GibbsSamplerState(
        bn::BayesNet,
        max_cache_size::Nullable{Integer}=Nullable{Integer}()
        )

        a = rand(bn)
        markov_blankets = Dict{Symbol, Vector{Symbol}}(name => Vector{Symbol}([ele for ele in markov_blanket(bn, name)])
                                                           for name in names(bn))

        is_cacheable = Dict{Symbol, Bool}(
                       name => all(
                                  [hasfinitesupport(get(bn, mb_name)(a)) for mb_name in markov_blankets[name]]
                                  ) 
                       for name in names(bn)
                       )

        new(bn, names(bn), max_cache_size, 
            Dict{Symbol, Array{CPD}}(name => markov_blanket_cpds(bn, name) for name in names(bn)), 
            markov_blankets,
            is_cacheable,
            Dict{String, Array{Float64, 1}}(), 
            Dict{Symbol, Vector{Vector{Float64}}}()
            )
    end

end

"""
Helper to sample_posterior_finite

Modifies a and gss
"""
function get_finite_distribution!(gss::GibbsSamplerState, varname::Symbol, a::Assignment, support::AbstractArray)

    is_cacheable = gss.finite_distrbution_is_cacheable[varname]
    key = ""
    if is_cacheable

        key = join([string(a[name]) for name in gss.markov_blanket_cache[varname]], ",")
        key = join([string(varname), key], ",")

        if haskey(gss.finite_distribution_cache, key)
            return gss.finite_distribution_cache[key]
        end

    end

    markov_blanket_cpds = gss.markov_blanket_cpds_cache[varname]
    posterior_distribution = zeros(length(support))
    for (index, domain_element) in enumerate(support)
        a[varname] = domain_element
        # Sum logs for numerical stability
        posterior_distribution[index] = exp(sum([logpdf(cpd, a) for cpd in markov_blanket_cpds]))
    end
    posterior_distribution = posterior_distribution / sum(posterior_distribution)
    if is_cacheable && ( isnull(gss.max_cache_size) || length(gss.finite_distribution_cache) < get(gss.max_cache_size) )
        gss.finite_distribution_cache[key] = posterior_distribution
    end
    return posterior_distribution
end

"""
Chooses a sample at random from the result of rand_table_weighted
"""
function sample_weighted_dataframe(rand_samples::DataFrame)
    p = rand_samples[:, :p]
    n = length(p)
    i = 1
    c = p[1]
    u = rand()
    while c < u && i < n
        c += p[i += 1]
    end

    return Assignment(Dict(varname => rand_samples[i, varname] for varname in names(rand_samples) if varname != :p))
end

"""
Helper to sample_posterior
Should only be called if the variable associated with varname is discrete

set a[varname] ~ P(varname | not varname)

Modifies both a and gss
"""
function sample_posterior_finite!(gss::GibbsSamplerState, varname::Symbol, a::Assignment, support::AbstractArray)

   posterior_distribution = get_finite_distribution!(gss, varname, a, support)

   # Adapted from Distributions.jl, credit to its authors
   p = posterior_distribution
   n = length(p)
   i = 1
   c = p[1]
   u = rand()
   while c < u && i < n
       c += p[i += 1]
   end

   a[varname] = support[i]

end

function L(x::Float64, proposal::ARMH_proposal, index1::Int64, index2::Int64)
    return proposal.slopes[index1] * x + proposal.intercepts[index1]
end

function eval_exponential(x::Float64, proposal::ARMH_proposal, left::Bool)
    if left
        return exp(proposal.left_exp_slope * x + proposal.left_exp_intercept)
    end
    return exp(proposal.right_exp_slope * x + proposal.right_exp_intercept)
end

function update_segment(proposal::ARMH_proposal, segment_index::Int64)
    # segment_index in 1 to num_support_points + 1
    num_points = length(proposal.support_points)

    if segment_index == 1
        dy = log(proposal.prob_cache[2]) - log(proposal.prob_cache[1])
        dx = proposal.support_points[2] - proposal.support_points[1]
        slope = dy/dx
        slope = max(slope, 0.05)
        intercept = log(proposal.prob_cache[1]) - slope * proposal.support_points[1]
        area = 1.0/slope * exp(slope * proposal.support_points[1] + intercept)
        # TODO for bounded distributions, do area -= 1.0/slope * exp(slope * left_bound + intercept)

        proposal.total_area += area - proposal.segment_area[segment_index]
        proposal.segment_area[segment_index] = area
        proposal.left_exp_slope = slope
        proposal.left_exp_intercept = intercept
    elseif segment_index == num_points + 1
        index2 = num_points - 1
        index1 = num_points
        dy = log(proposal.prob_cache[index2]) - log(proposal.prob_cache[index1])
        dx = proposal.support_points[index2] - proposal.support_points[index1]
        slope = dy/dx
        slope = min(slope, -0.05)
        intercept = log(proposal.prob_cache[index1]) - slope * proposal.support_points[index1]
        area = -1.0/slope * exp(slope * proposal.support_points[index1] + intercept)
        # TODO for bounded distributions, do area += 1.0/slope * exp(slope * right + intercept)

        proposal.total_area += area - proposal.segment_area[segment_index]
        proposal.segment_area[segment_index] = area
        proposal.right_exp_slope = slope
        proposal.right_exp_intercept = intercept
    else
        xl = proposal.support_points[segment_index - 1]
        xu = proposal.support_points[segment_index]
        yl = proposal.prob_cache[segment_index - 1]
        yu = proposal.prob_cache[segment_index]

        area = (xu - xl) * (yu + yl)/2.0
        slope = (yu - yl)/(xu - xl)
        intercept = yl - slope * xl

        print("Line (x1, y1, x2, y2): ")
        println([xl, yl, xu, yu])
        print("Line area: ")
        println(area)

        proposal.total_area += area - proposal.segment_area[segment_index]
        proposal.segment_area[segment_index] = area
        proposal.slopes[segment_index - 1] = slope
        proposal.intercepts[segment_index - 1] = intercept
    end

end
"""
Assumes there are atleast 3 points in the proposal
"""
function update_support_points(proposal::ARMH_proposal, new_support_point::Float64, support_point_scaled_true_prob::Float64)
    # If you average the densities correctly, the density update should be small
    insertion_index = 1 + searchsortedlast(proposal.support_points, new_support_point)
    insert!(proposal.segment_area, insertion_index + 1, 0.0)
    insert!(proposal.support_points, insertion_index, new_support_point)
    insert!(proposal.prob_cache, insertion_index, support_point_scaled_true_prob)
    insert!(proposal.slopes, insertion_index, 0.0)
    insert!(proposal.intercepts, insertion_index, 0.0)
    update_segment(proposal, insertion_index)
    update_segment(proposal, insertion_index + 1)
end

function value_at_cdf(proposal::ARMH_proposal, cdf_val::Float64)
    num_points = length(proposal.support_points)
    area_jump_val = proposal.total_area * cdf_val
    segment_index = 0
    while area_jump_val >= 0.0
        segment_index += 1
        area_jump_val -= proposal.segment_area[segment_index]
    end
    area_jump_val += proposal.segment_area[segment_index]

    if segment_index == 1

        return (log(area_jump_val * proposal.left_exp_slope) - proposal.left_exp_intercept) / proposal.left_exp_slope

    elseif segment_index == num_points + 1

        tmp = area_jump_val - 
            exp(proposal.right_exp_slope * proposal.support_points[end] + proposal.right_exp_intercept) / proposal.right_exp_slope
        return (log(tmp * (-proposal.right_exp_slope)) - proposal.right_exp_intercept) / proposal.right_exp_slope

    else
        right_bound = proposal.support_points[segment_index]
        left_bound = proposal.support_points[segment_index - 1]
        m = proposal.slopes[segment_index - 1]
        b = proposal.intercepts[segment_index - 1]
        A = area_jump_val + (m * left_bound * left_bound / 2 + b * left_bound)
        x = (sqrt(2 * A * m + b*b) - b)/m
        if isapprox(m, 0.0) 
            return A/b
        else
            if (x > left_bound) && (x < right_bound)
                return x
            end
            return -1 * x 
        end
    end
    
end

function sample_from_AMH_proposal(proposal::ARMH_proposal)
    new_sample = value_at_cdf(proposal, rand())
    return new_sample, AMH_proposal_pdf(proposal, new_sample)
end

function AMH_proposal_pdf(proposal::ARMH_proposal, proposed_jump::Float64)
    insertion_index = searchsortedlast(proposal.support_points, proposed_jump)
    num_points = length(proposal.support_points)
    out = 0.0
    if insertion_index == num_points
        out = eval_exponential(proposed_jump, proposal, false)
    elseif insertion_index > 0
        out = L(proposed_jump, proposal, insertion_index, insertion_index + 1)
    else
        # insertion_index == 0
        out = eval_exponential(proposed_jump, proposal, true)
    end
    return out / proposal.total_area
end

function initialize_proposal(gss::GibbsSamplerState, varname::Symbol,
                                   var_distribution::ContinuousUnivariateDistribution, a::Assignment,
                                   markov_blanket::Vector{CPD})
    # initialze to the 5th, 50th, and 95th percentile values from the previous iteration if the support points
    	# are available this is based on the suggestion in:
    # W. R. Gilks, N. G. Best, and K. K. C. Tan, Adaptive rejection metropolis sampling within Gibbs sampling, Appl. Statist., vol. 44, no. 4, pp. 455472, 1995

    v1 = 0.0
    v2 = 0.0
    v3 = 0.0
    if haskey(gss.AMH_support_point_cache, varname)
        old_proposal = gss.AMH_support_point_cache[varname]
        v1 = value_at_cdf(old_proposal, 0.05)
        v2 = value_at_cdf(old_proposal, 0.5)
        v3 = value_at_cdf(old_proposal, 0.95)
    else
        v2 = mean(var_distribution)
        stddev = std(var_distribution)
        v3 = 5*stddev + v2
        v1 = v2 - 5 * stddev
    end
    # TODO initalize support points, consider using the bounds of the distribution if they exist

    v1 = max(v1, minimum(var_distribution))
    v3 = min(v3, maximum(var_distribution))
    p = ARMH_proposal()
    p.support_points = [v1, v2, v3]
    print("Initial points")
    println(p.support_points)
    sort!(p.support_points)
    p.segment_area = [0.0 for i in 1:4]
    p.slopes = [0.0 for i in 1:2]
    p.intercepts = [0.0 for i in 1:2]
    old_val = a[varname]
    for v in p.support_points
        a[varname] = v
        push!(p.prob_cache, exp(sum([logpdf(cpd, a) for cpd in markov_blanket])))
    end
    a[varname] = old_val
    for i in 1:4
        update_segment(p, i)
    end
    return p
end

"""
Martino, L.; Read, J.; Luengo, D. (2015-06-01). "Independent Doubly Adaptive Rejection Metropolis Sampling Within Gibbs Sampling". IEEE Transactions on Signal Processing. 63 (12): 31233138. doi:10.1109/TSP.2015.2420537. ISSN 1053-587X

This implements the proposal from equation (9)

http://ieeexplore.ieee.org/document/7080917/?arnumber=7080917

https://arxiv.org/pdf/1205.5494v4.pdf

(These are different papers)
"""
function sample_posterior_continuous_adaptive!(gss::GibbsSamplerState, varname::Symbol, a::Assignment,
                                     var_distribution::ContinuousUnivariateDistribution; AMH_iterations::Integer=10)
    # Implements IA2RMS
    markov_blanket_cpds = gss.markov_blanket_cpds_cache[varname]
    _proposal = initialize_proposal(gss, varname, var_distribution, a, markov_blanket_cpds)    

    previous_sample_scaled_true_prob = exp(sum([logpdf(cpd, a) for cpd in markov_blanket_cpds]))
    previous_sample_proposal_prob = AMH_proposal_pdf(_proposal, a[varname])

    for alg_iteration in 1:AMH_iterations
        current_value = a[varname]
        proposed_jump, proposed_jump_proposal_prob = sample_from_AMH_proposal(_proposal)
        a[varname] = proposed_jump
        proposed_jump_scaled_true_prob = exp(sum([logpdf(cpd, a) for cpd in markov_blanket_cpds]))    

        # Rejection step
        acceptance_prob = proposed_jump_scaled_true_prob / proposed_jump_proposal_prob
        if rand() > acceptance_prob
            # Reject and add to support points
            update_support_points(_proposal, proposed_jump, proposed_jump_scaled_true_prob)
            a[varname] = current_value
            previous_sample_proposal_prob = AMH_proposal_pdf(_proposal, current_value)
        else
            # MH acceptance step
            MH_acceptance_prob = proposed_jump_scaled_true_prob * min(previous_sample_scaled_true_prob, previous_sample_proposal_prob)
            MH_acceptance_prob /= previous_sample_scaled_true_prob * min(proposed_jump_scaled_true_prob, proposed_jump_proposal_prob)
            y = proposed_jump
            y_proposal_prob = proposed_jump_proposal_prob
            y_scaled_true_prob = proposed_jump_scaled_true_prob
            if rand() <= MH_acceptance_prob
                # Accept new sample
                y = current_value
                y_proposal_prob = previous_sample_proposal_prob
                y_scaled_true_prob = previous_sample_scaled_true_prob
                previous_sample_scaled_true_prob = proposed_jump_scaled_true_prob
                # a[varname] has already been set to proposed_jump
                # previous_sample_proposal_prob is updated below
            else
                # Reject new sample
                a[varname] = current_value
            end
    
            # Update proposal
            update_proposal_rejection_prob = y_proposal_prob / y_scaled_true_prob
            if rand() > update_proposal_rejection_prob
                update_support_points(_proposal, y, y_scaled_true_prob)
                previous_sample_proposal_prob = AMH_proposal_pdf(_proposal, a[varname])
            elseif a[varname] != current_value
                previous_sample_proposal_prob = AMH_proposal_pdf(_proposal, a[varname])
            end
        end
    
    end

    gss.AMH_support_point_cache[varname] = _proposal

end

"""
Implements Metropolis-Hastings with a normal distribution proposal with mean equal to the previous value
of the variable "varname" and stddev equal to 10 times the standard deviation of the distribution of the target
variable given its parents ( var_distribution should be get(bn, varname)(a) )

MH will go through nsamples iterations.  If no proposal is accepted, the original value will remain

This function expects that a[varname] is within the support of the distribution, it will not check to make sure this is true

Helper to sample_posterior
Should only be used to sampling continuous distributions

set a[varname] ~ P(varname | not varname)

Modifies a and caches in gss
"""
function sample_posterior_continuous!(gss::GibbsSamplerState, varname::Symbol, a::Assignment, 
                                     var_distribution::ContinuousUnivariateDistribution; MH_iterations::Integer=10)
    # TODO consider using slice sampling or having an option for slice sampling
    # Implement http://ieeexplore.ieee.org/stamp/stamp.jsp?arnumber=7080917

    # Random Walk Metropolis Hastings
    markov_blanket_cpds = gss.markov_blanket_cpds_cache[varname]
    stddev = std(var_distribution) * 10.0
    previous_sample_scaled_true_prob = exp(sum([logpdf(cpd, a) for cpd in markov_blanket_cpds]))
    proposal_distribution = Normal(a[varname], stddev) # TODO why does calling this constructor take so long?

    for sample_iter = 1:MH_iterations

        # compute proposed jump
        current_value = a[varname]
        proposed_jump = rand(proposal_distribution)
        if ~ insupport(var_distribution, proposed_jump)
            continue # reject immediately, zero probability
        end

        # Compute acceptance probability
        a[varname] = proposed_jump
        proposed_jump_scaled_true_prob = exp(sum([logpdf(cpd, a) for cpd in markov_blanket_cpds]))
        # Our proposal is symmetric, so q(X_new, X_old) / q(X_old, X_new) = 1
        # accept_prob = min(1, proposed_jump_scaled_true_prob/previous_sample_scaled_true_prob)
        accept_prob = proposed_jump_scaled_true_prob/previous_sample_scaled_true_prob # min operation is unnecessary

        # Accept or reject and clean up
        if rand() <= accept_prob
            # a[varname] = proposed_jump
            previous_sample_scaled_true_prob = proposed_jump_scaled_true_prob
            proposal_distribution = Normal(proposed_jump, stddev)
        else
            a[varname] = current_value
        end
    end

    # a[varname] is set in the above for loop

end

"""
set a[varname] ~ P(varname | not varname)

Modifies a and caches in gss
"""
function sample_posterior!(gss::GibbsSamplerState, varname::Symbol, a::Assignment)

    bn = gss.bn
    cpd = get(bn, varname)
    distribution = cpd(a)
    if hasfinitesupport(distribution)
        sample_posterior_finite!(gss, varname, a, support(distribution))
    elseif typeof(distribution) <: DiscreteUnivariateDistribution
        error("Infinite Discrete distributions are currently not supported in the Gibbs sampler")
    else
        # sample_posterior_continuous_adaptive!(gss, varname, a, distribution)
        sample_posterior_continuous!(gss, varname, a, distribution)
    end
end

"""
The main loop associated with Gibbs sampling
Returns a data frame with nsamples samples

Supports the various parameters supported by gibbs_sample
Refer to gibbs_sample for parameter meanings
"""
function gibbs_sample_main_loop(gss::GibbsSamplerState, nsamples::Integer, thinning::Integer, 
start_sample::Assignment, consistent_with::Assignment, variable_order::Nullable{Vector{Symbol}},
time_limit::Nullable{Integer})

    start_time = now()

    bn = gss.bn
    a = start_sample
    if isnull(variable_order)
         v_order = names(bn)
    else
         v_order = get(variable_order)
    end

    v_order = [varname for varname in v_order if ~haskey(consistent_with, varname)]

    t = Dict{Symbol, Vector{Any}}()
    for name in v_order
        t[name] = Any[]
    end

    for sample_iter in 1:nsamples
        if (~ isnull(time_limit)) && (Integer(now() - start_time) > get(time_limit))
            break
        end

        if isnull(variable_order)
            v_order = shuffle!(v_order)
        end

        # skip over thinning samples
        for skip_iter in 1:thinning
            for varname in v_order
                 sample_posterior!(gss, varname, a)
            end

            if isnull(variable_order)
                v_order = shuffle!(v_order)
            end
        end

        for varname in v_order
            sample_posterior!(gss, varname, a)
            push!(t[varname], a[varname])
        end

    end

    return convert(DataFrame, t), Integer(now() - start_time)
end

"""
Implements Gibbs sampling. (https://en.wikipedia.org/wiki/Gibbs_sampling)
For finite variables, the posterior distribution is sampled by building the exact distribution.
For continuous variables, the posterior distribution is sampled using Metropolis Hastings MCMC.
Discrete variables with infinite support are currently not supported.
The Gibbs Sampler only supports CPDs that return Univariate Distributions. (CPD{D<:UnivariateDistribution})

bn:: A Bayesian Network to sample from.  bn should only contain CPDs that return UnivariateDistributions.

nsamples: The number of samples to return.

burn_in:  The first burn_in samples will be discarded.  They will not be returned.
The thinning parameter does not affect the burn in period.
This is used to ensure that the Gibbs sampler converges to the target stationary distribution before actual samples are drawn.

thinning: For every thinning + 1 number of samples drawn, only the last is kept.
Thinning is used to reduce autocorrelation between samples.
Thinning is not used during the burn in period.
e.g. If thinning is 1, samples will be drawn in groups of two and only the second sample will be in the output.

time_limit: The number of milliseconds to run the algorithm.
The algorithm will return the samples it has collected when either nsamples samples have been collected or time_limit 
milliseconds have passed.  If time_limit is null then the algorithm will run until nsamples have been collected.
This means it is possible that zero samples are returned.

error_if_time_out: If error_if_time_out is true and the time_limit expires, an error will be raised.
If error_if_time_out is false and the time limit expires, the samples that have been collected so far will be returned.
	This means it is possible that zero samples are returned.  Burn in samples will not be returned.
If time_limit is null, this parameter does nothing.

consistent_with: the assignment that all samples must be consistent with (ie, Assignment(:A=>1) means all samples must have :A=1).
Use to sample conditional distributions.

max_cache_size:  If null, cache as much as possible, otherwise cache at most "max_cache_size"  distributions

variable_order: variable_order determines the order of variables changed when generating a new sample.  
If null use a random order for every sample (this is different from updating the variables at random).
Otherwise should be a list containing all the variables in the order they should be updated.

initial_sample:  The inital assignment to variables to use.  If null, the initial sample is chosen by 
briefly running rand_table_weighted.
"""
function gibbs_sample(bn::BayesNet, nsamples::Integer, burn_in::Integer;
        thinning::Integer=0,
        consistent_with::Assignment=Assignment(),
        variable_order::Nullable{Vector{Symbol}}=Nullable{Vector{Symbol}}(), 
        time_limit::Nullable{Integer}=Nullable{Integer}(),
        error_if_time_out::Bool=true, 
        initial_sample::Nullable{Assignment}=Nullable{Assignment}(),
        max_cache_size::Nullable{Integer}=Nullable{Integer}()
        )
    # check parameters for correctness
    nsamples > 0 || throw(ArgumentError("nsamples parameter less than 1"))
    burn_in >= 0 || throw(ArgumentError("Negative burn_in parameter"))
    thinning >= 0 || throw(ArgumentError("Negative sample_skip parameter"))
    if ~ isnull(variable_order)
        v_order = get(variable_order)
        bn_names = names(bn)
        for name in bn_names
            name in v_order || throw(ArgumentError("Gibbs sample variable_order must contain all variables in the Bayes Net"))
        end
        for name in v_order
            name in bn_names || throw(ArgumentError("Gibbs sample variable_order contains a variable not in the Bayes Net"))
        end
    end
    if ~ isnull(time_limit)
        get(time_limit) > 0 || throw(ArgumentError(join(["Invalid time_limit specified (", get(time_limit), ")"])))
    end
    if ~ isnull(initial_sample)
        init_sample = get(initial_sample)
        for name in names(bn)
            haskey(init_sample, name) || throw(ArgumentError("Gibbs sample initial_sample must be an assignment with all variables in the Bayes Net"))
        end
        for name in keys(consistent_with)
            init_sample[name] == consistent_with[name] || throw(ArgumentError("Gibbs sample initial_sample was inconsistent with consistent_with"))
        end
    end

    gss = GibbsSamplerState(bn, max_cache_size)
   
    # Burn in 
    # for burn_in_initial_sample use rand_table_weighted, should be consistent with the varibale consistent_with
    if isnull(initial_sample)
        rand_samples = rand_table_weighted(bn, nsamples=10, consistent_with=consistent_with)
	if any(isnan(convert(Array{AbstractFloat}, rand_samples[:p])))
		error("Gibbs Sampler was unable to find an inital sample with non-zero probability")
	end
        burn_in_initial_sample = sample_weighted_dataframe(rand_samples)
    else
        burn_in_initial_sample = get(initial_sample)
    end
    burn_in_samples, burn_in_time = gibbs_sample_main_loop(gss, burn_in, 0, burn_in_initial_sample, 
                                         consistent_with, variable_order, time_limit)

    # Check that more time is available
    remaining_time = Nullable{Integer}()
    if ~isnull(time_limit)
        remaining_time = Nullable{Integer}(get(time_limit) - burn_in_time)
        if error_if_time_out
            get(remaining_time) > 0 || error("Time expired during Gibbs sampling")
        end
    end
   
    # Real samples
    main_samples_initial_sample = burn_in_initial_sample
    if burn_in != 0 && size(burn_in_samples)[1] > 0
        main_samples_initial_sample = Assignment(Dict(varname => 
                      (haskey(consistent_with, varname) ? consistent_with[varname] : burn_in_samples[end, varname])
                      for varname in names(bn))) 
    end
    samples, samples_time = gibbs_sample_main_loop(gss, nsamples, thinning, 
                               main_samples_initial_sample, consistent_with, variable_order, remaining_time)
    combined_time = burn_in_time + samples_time
    if error_if_time_out && ~isnull(time_limit)
        combined_time < get(time_limit) || error("Time expired during Gibbs sampling")
    end

    # Add in columns for variables that were conditioned on
    evidence = DataFrame(Dict(varname => ones(size(samples)[1]) * consistent_with[varname] 
                 for varname in keys(consistent_with)))
    return hcat(samples, evidence)
end

"""
The GibbsSampler type houses the parameters of the Gibbs sampling algorithm.  The parameters are defined below:

burn_in:  The first burn_in samples will be discarded.  They will not be returned.
The thinning parameter does not affect the burn in period.
This is used to ensure that the Gibbs sampler converges to the target stationary distribution before actual samples are drawn.

thinning: For every thinning + 1 number of samples drawn, only the last is kept.
Thinning is used to reduce autocorrelation between samples.
Thinning is not used during the burn in period.
e.g. If thinning is 1, samples will be drawn in groups of two and only the second sample will be in the output.

time_limit: The number of milliseconds to run the algorithm.
The algorithm will return the samples it has collected when either nsamples samples have been collected or time_limit
milliseconds have passed.  If time_limit is null then the algorithm will run until nsamples have been collected.
This means it is possible that zero samples are returned.

error_if_time_out: If error_if_time_out is true and the time_limit expires, an error will be raised.
If error_if_time_out is false and the time limit expires, the samples that have been collected so far will be returned.
        This means it is possible that zero samples are returned.  Burn in samples will not be returned.
If time_limit is null, this parameter does nothing.

consistent_with: the assignment that all samples must be consistent with (ie, Assignment(:A=>1) means all samples must have :A=1).
Use to sample conditional distributions.

max_cache_size:  If null, cache as much as possible, otherwise cache at most "max_cache_size"  distributions

variable_order: variable_order determines the order of variables changed when generating a new sample.
If null use a random order for every sample (this is different from updating the variables at random).
Otherwise should be a list containing all the variables in the order they should be updated.

initial_sample:  The inital assignment to variables to use.  If null, the initial sample is chosen by
briefly running rand_table_weighted.
"""
type GibbsSampler <: BayesNetSampler

    burn_in::Integer
    thinning::Integer
    consistent_with::Assignment
    variable_order::Nullable{Vector{Symbol}}
    time_limit::Nullable{Integer}
    error_if_time_out::Bool
    initial_sample::Nullable{Assignment}
    max_cache_size::Nullable{Integer}

    function GibbsSampler(burn_in::Integer;
        thinning::Integer=0,
        consistent_with::Assignment=Assignment(),
        variable_order::Nullable{Vector{Symbol}}=Nullable{Vector{Symbol}}(),
        time_limit::Nullable{Integer}=Nullable{Integer}(),
        error_if_time_out::Bool=true,
        initial_sample::Nullable{Assignment}=Nullable{Assignment}(),
        max_cache_size::Nullable{Integer}=Nullable{Integer}()
        )

        new(burn_in, thinning, consistent_with, variable_order, time_limit, error_if_time_out, initial_sample, max_cache_size)
    end

end

"""
Implements Gibbs sampling. (https://en.wikipedia.org/wiki/Gibbs_sampling)
For finite variables, the posterior distribution is sampled by building the exact distribution.
For continuous variables, the posterior distribution is sampled using Metropolis Hastings MCMC.
Discrete variables with infinite support are currently not supported.
The Gibbs Sampler only supports CPDs that return Univariate Distributions. (CPD{D<:UnivariateDistribution})

Sampling requires a GibbsSampler object which contains the parameters for Gibbs sampling.
See the GibbsSampler documentation for parameter details.
"""
function Base.rand(bn::BayesNet, config::GibbsSampler, nsamples::Integer)

    return gibbs_sample(bn, nsamples, config.burn_in; thinning=config.thinning,
		consistent_with=config.consistent_with, variable_order=config.variable_order,
		time_limit=config.time_limit, error_if_time_out=config.error_if_time_out,
		initial_sample=config.initial_sample, max_cache_size=config.max_cache_size)

end
