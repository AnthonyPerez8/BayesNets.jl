VERSION >= v"0.4.0-dev+6521" && __precompile__(true)

module BayesNets

using Compat
import Compat.String
@compat import Base.show
if isdefined(Base, :normalize)
    import Base: normalize
end

using Reexport

pkgdir = dirname(@__DIR__)
include(joinpath(pkgdir, "src", "CPDs", "cpds.jl"))
@reexport using BayesNets.CPDs

import LightGraphs: DiGraph, add_edge!, rem_edge!, add_vertex!, rem_vertex!, has_edge, topological_sort_by_dfs, in_neighbors, out_neighbors, is_cyclic, nv, ne, outdegree, badj
import TikzGraphs: plot
import Iterators: subsets, product
import Base.Collections: PriorityQueue, peek

export
	BayesNet,
	DAG,

    parents,
    children,
    markov_blanket_cpds,
    markov_blanket,
    has_edge,
    enforce_topological_order!,

	add_edge!,
    has_edge,

    rand_cpd,
    rand_table_weighted,
    BayesNetSampler,
    gibbs_sample,
    GibbsSampler,

    table,
    sumout,
    normalize,
    estimate_convergence,
    readxdsl,

    DirichletPrior,
    UniformPrior,
    BDeuPrior,

    ScoringFunction,
    ScoreComponentCache,
    NegativeBayesianInformationCriterion,
    score_component,
    score_components,

    GraphSearchStrategy,
    K2GraphSearch,
    GreedyHillClimbing,

    statistics,
    index_data,
    adding_edge_preserves_acyclicity,
    bayesian_score_component,
    bayesian_score_components,
    bayesian_score,

    GibbsSamplerState,
    sample_posterior_continuous!

include("bayes_nets.jl")
include("io.jl")
include("sampling.jl")
include("learning.jl")
include("gibbs.jl")

include("DiscreteBayesNet/ndgrid.jl")
include("DiscreteBayesNet/factors.jl")
include("DiscreteBayesNet/dirichlet_priors.jl")
include("DiscreteBayesNet/discrete_bayes_net.jl")
include("DiscreteBayesNet/structure_scoring.jl")
include("DiscreteBayesNet/greedy_hill_climbing.jl")

end # module
