"""
A component that adds a hierarchical relation between parameters according to a LMM defined via MixedModels.jl

- `basis`: an object, if accessed, provides a 'basis-function', e.g. `hanning(40)`, this defines the response at a single event. It will be weighted by the model-prediction
- `formula`: Formula-Object in the style of MixedModels.jl e.g. `@formula dv~1+cond + (1|subject)` - left side must be `dv`
- `β` Vector of betas, must fit the formula
- `σs` Dict of random effect variances, e.g. `Dict(:subject=>[0.5,0.4])` or to specify correlationmatrix `Dict(:subject=>[0.5,0.4,I(2,2)],...)`. Technically, this will be passed to MixedModels.jl `create_re` function, which creates the θ matrices.
- `contrasts`: Dict in the style of MixedModels.jl. Default is empty.

All arguments can be named, in that case `contrasts` is optional

Works best with `MultiSubjectDesign`
```julia
MixedModelComponent(;
    basis=hanning(40),
    formula=@formula(dv~1+cond+(1+cond|subject)),
    β = [1.,2.],
    σs= Dict(:subject=>[0.5,0.4]),
    contrasts=Dict(:cond=>EffectsCoding())
)

```
"""
@with_kw struct MixedModelComponent <: AbstractComponent
    basis
    formula # e.g. dv~1+cond - left side must be "dv"
    β::Vector
    σs::Dict # Dict(:subject=>[0.5,0.4]) or to specify correlationmatrix Dict(:subject=>[0.5,0.4,I(2,2)],...)
    contrasts::Dict = Dict()
end

"""
A multiple regression component for one subject

- `basis`: an object, if accessed, provides a 'basis-function', e.g. `hanning(40)`, this defines the response at a single event. It will be weighted by the model-prediction
- `formula`: StatsModels Formula-Object  `@formula 0~1+cond` (left side must be 0)
- `β` Vector of betas, must fit the formula
- `contrasts`: Dict. Default is empty, e.g. `Dict(:condA=>EffectsCoding())`

All arguments can be named, in that case `contrasts` is optional

Works best with `SingleSubjectDesign`
```julia
LinearModelComponent(;
    basis=hanning(40),
    formula=@formula(0~1+cond),
    β = [1.,2.],
    contrasts=Dict(:cond=>EffectsCoding())
)

```
"""
@with_kw struct LinearModelComponent <: AbstractComponent
    basis
    formula # e.g. 0~1+cond - left side must be "0"
    β::Vector
    contrasts::Dict = Dict()
end


Base.length(c::AbstractComponent) = length(c.basis)
maxlength(c::Vector{AbstractComponent}) = maximum(length.(c))

"""
# by default call simulate with `::Abstractcomponent,::AbstractDesign``, but allow for custom types
# making use of other information in simulation
"""
simulate(rng,c::AbstractComponent,simulation::Simulation) = simulate(rng,c,simulation.design)

"""
simulate a linearModel

julia> c = UnfoldSim.LinearModelComponent([0,1,1,0],@formula(0~1+cond),[1,2],Dict())
julia> design = MultiSubjectDesign(;n_subjects=2,n_items=50,item_between=(;:cond=>["A","B"]))
julia> simulate(StableRNG(1),c,design)
"""
function simulate(rng,c::LinearModelComponent,design::AbstractDesign)
    evts = generate(design)
    
    # special case, intercept only 
    # https://github.com/JuliaStats/StatsModels.jl/issues/269
    if c.formula.rhs == ConstantTerm(1)
        X = ones(nrow(evts),1)
    else
        if isempty(c.contrasts)
            m = StatsModels.ModelFrame(c.formula, evts)
        else
            m = StatsModels.ModelFrame(c.formula, evts;contrasts=c.contrasts)
        end
        X = StatsModels.modelmatrix(m)    
    end
    y = X * c.β
    return y' .* c.basis
end
"""
simulate MixedModelComponent

julia> design = MultiSubjectDesign(;n_subjects=2,n_items=50,item_between=(;:cond=>["A","B"]))
julia> c = UnfoldSim.MixedModelComponent([0.,1,1,0],@formula(dv~1+cond+(1|subject)),[1,2],Dict(:subject=>[2],),Dict())
julia> simulate(StableRNG(1),c,design)

"""
function simulate(rng,c::MixedModelComponent,design::AbstractDesign)
	evts = generate(design)

	# create dummy
    if isempty(c.contrasts)
        m = MixedModels.MixedModel(c.formula, evts)
    else
	    m = MixedModels.MixedModel(c.formula, evts; contrasts=c.contrasts)
    end


	# empty epoch data
	epoch_data_component = zeros(Int(length(c.basis)), length(design))

	# residual variance for lmm
	σ_lmm = 	0.0001
	if 1 == 1
        namedre = weight_σs(c.σs,1.,σ_lmm)
        θ = createθ(m; namedre...)
        simulate!(deepcopy(rng), m.y, m; 
        β= c.β, 
        σ= σ_lmm,
        θ= θ)

        # save data to array
        #@show size(m.y)
        #@show size(c.basis)
    
    
        epoch_data_component = kron(c.basis,m.y')
        

    else
        # iterate over each timepoint
        for t in eachindex(c.basis)

			# select weight from basis
            # right now, it is the same, but maybe changein thefuture?
			basis_β  = c.basis[t]
			basis_σs = c.basis[t]
			
			
            # weight random effects by the basis function
            namedre = weight_σs(c.σs,basis_σs,σ_lmm)
            
            θ = createθ(m; namedre...)

        
			# simulate with new parameters; will update m.y
            simulate!(deepcopy(rng), m.y, m; 
                    β=basis_β .* c.β, 
                    σ= σ_lmm,
                    θ= θ)

			# save data to array
			epoch_data_component[t, :] = m.y
		end
    end
    return epoch_data_component
	
end


"""
Weights a σs Dict for MixedModels.jl by a Float64

Finally sales it by σ_lmm, as a trick to simulate noise-free LMMs

I anticipate a function
    `function weight_σs(σs::Dict,b_σs::Dict,σ_lmm::Float64)`
where each σs entry can be weighted individually
"""
function weight_σs(σs::Dict,b_σs::Float64,σ_lmm::Float64)
    #k = (collect(keys(σs))...,)
    #val = values(σs)

    keys = Symbol[]
    vals = LowerTriangular[]

    for (k,v) in σs

        scale = (x)-> b_σs./σ_lmm .* x
        
        if v[end] isa Matrix
            v = create_re.(scale(v[1:end-1])...;corrmat=v[end])    
        else
            v = create_re.(scale(v)...;)
        end
        
        push!(keys,k)
        push!(vals,v)
    end
    
    namedre = NamedTuple(keys.=>vals)
    
   return namedre
end
