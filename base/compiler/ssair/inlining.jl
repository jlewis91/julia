# This file is a part of Julia. License is MIT: https://julialang.org/license

@nospecialize

struct InvokeData
    entry::Method
    types0
    min_valid::UInt
    max_valid::UInt
end

struct Signature
    f::Any
    ft::Any
    atypes::Vector{Any}
    atype::Type
    Signature(f, ft, atypes) = new(f, ft, atypes)
    Signature(f, ft, atypes, atype) = new(f, ft, atypes, atype)
end
with_atype(sig::Signature) = Signature(sig.f, sig.ft, sig.atypes, argtypes_to_type(sig.atypes))

struct ResolvedInliningSpec
    # The LineTable and IR of the inlinee
    ir::IRCode
    # If the function being inlined is a single basic block we can use a
    # simpler inlining algorithm. This flag determines whether that's allowed
    linear_inline_eligible::Bool
end

"""
    Represents a callsite that our analysis has determined is legal to inline,
    but did not resolve during the analysis step to allow the outer inlining
    pass to apply its own inlining policy decisions.
"""
struct DelayedInliningSpec
    match::MethodMatch
    atypes::Vector{Any}
    stmttype::Any
end

struct InliningTodo
    # The MethodInstance to be inlined
    mi::MethodInstance
    spec::Union{ResolvedInliningSpec, DelayedInliningSpec}
end

InliningTodo(mi::MethodInstance, match::MethodMatch, atypes::Vector{Any}, @nospecialize(stmttype)) = InliningTodo(mi, DelayedInliningSpec(match, atypes, stmttype))

struct ConstantCase
    val::Any
    ConstantCase(val) = new(val)
end

struct UnionSplit
    fully_covered::Bool
    atype # ::Type
    cases::Vector{Pair{Any, Any}}
    bbs::Vector{Int}
    UnionSplit(fully_covered::Bool, atype, cases::Vector{Pair{Any, Any}}) =
        new(fully_covered, atype, cases, Int[])
end

@specialize

function ssa_inlining_pass!(ir::IRCode, linetable::Vector{LineInfoNode}, state::InliningState, propagate_inbounds::Bool)
    # Go through the function, performing simple ininlingin (e.g. replacing call by constants
    # and analyzing legality of inlining).
    @timeit "analysis" todo = assemble_inline_todo!(ir, state)
    isempty(todo) && return ir
    # Do the actual inlining for every call we identified
    @timeit "execution" ir = batch_inline!(todo, ir, linetable, propagate_inbounds)
    return ir
end

mutable struct CFGInliningState
    new_cfg_blocks::Vector{BasicBlock}
    inserted_block_ranges::Vector{UnitRange{Int}}
    todo_bbs::Vector{Tuple{Int, Int}}
    first_bb::Int
    bb_rename::Vector{Int}
    dead_blocks::Vector{Int}
    split_targets::BitSet
    merged_orig_blocks::BitSet
    cfg::CFG
end

function CFGInliningState(ir::IRCode)
    CFGInliningState(
        BasicBlock[],
        UnitRange{Int}[],
        Tuple{Int, Int}[],
        0,
        zeros(Int, length(ir.cfg.blocks)),
        Vector{Int}(),
        BitSet(),
        BitSet(),
        ir.cfg
    )
end

# Tells the inliner that we're now inlining into block `block`, meaning
# all previous blocks have been proceesed and can be added to the new cfg
function inline_into_block!(state::CFGInliningState, block::Int)
    if state.first_bb != block
        new_range = state.first_bb+1:block
        l = length(state.new_cfg_blocks)
        state.bb_rename[new_range] = (l+1:l+length(new_range))
        append!(state.new_cfg_blocks, map(copy, state.cfg.blocks[new_range]))
        push!(state.merged_orig_blocks, last(new_range))
    end
    state.first_bb = block
    return
end

function cfg_inline_item!(ir::IRCode, idx::Int, spec::ResolvedInliningSpec, state::CFGInliningState, from_unionsplit::Bool=false)
    inlinee_cfg = spec.ir.cfg
    # Figure out if we need to split the BB
    need_split_before = false
    need_split = true
    block = block_for_inst(ir, idx)
    inline_into_block!(state, block)

    if !isempty(inlinee_cfg.blocks[1].preds)
        need_split_before = true
    end

    last_block_idx = last(state.cfg.blocks[block].stmts)
    if false # TODO: ((idx+1) == last_block_idx && isa(ir[SSAValue(last_block_idx)], GotoNode))
        need_split = false
        post_bb_id = -ir[SSAValue(last_block_idx)].label
    else
        post_bb_id = length(state.new_cfg_blocks) + length(inlinee_cfg.blocks) + (need_split_before ? 1 : 0)
        need_split = true #!(idx == last_block_idx)
    end

    if !need_split
        delete!(state.merged_orig_blocks, last(new_range))
    end

    push!(state.todo_bbs, (length(state.new_cfg_blocks) - 1 + (need_split_before ? 1 : 0), post_bb_id))

    from_unionsplit || delete!(state.split_targets, length(state.new_cfg_blocks))
    orig_succs = copy(state.new_cfg_blocks[end].succs)
    empty!(state.new_cfg_blocks[end].succs)
    if need_split_before
        l = length(state.new_cfg_blocks)
        bb_rename_range = (1+l:length(inlinee_cfg.blocks)+l)
        push!(state.new_cfg_blocks[end].succs, length(state.new_cfg_blocks)+1)
        append!(state.new_cfg_blocks, inlinee_cfg.blocks)
    else
        # Merge the last block that was already there with the first block we're adding
        l = length(state.new_cfg_blocks)
        bb_rename_range = (l:length(inlinee_cfg.blocks)+l-1)
        append!(state.new_cfg_blocks[end].succs, inlinee_cfg.blocks[1].succs)
        append!(state.new_cfg_blocks, inlinee_cfg.blocks[2:end])
    end
    if need_split
        push!(state.new_cfg_blocks, BasicBlock(state.cfg.blocks[block].stmts,
            Int[], orig_succs))
        from_unionsplit || push!(state.split_targets, length(state.new_cfg_blocks))
    end
    new_block_range = (length(state.new_cfg_blocks)-length(inlinee_cfg.blocks)+1):length(state.new_cfg_blocks)
    push!(state.inserted_block_ranges, new_block_range)

    # Fixup the edges of the newely added blocks
    for (old_block, new_block) in enumerate(bb_rename_range)
        if old_block != 1 || need_split_before
            p = state.new_cfg_blocks[new_block].preds
            let bb_rename_range = bb_rename_range
                map!(p, p) do old_pred_block
                    return old_pred_block == 0 ? 0 : bb_rename_range[old_pred_block]
                end
            end
        end
        if new_block != last(new_block_range)
            s = state.new_cfg_blocks[new_block].succs
            let bb_rename_range = bb_rename_range
                map!(s, s) do old_succ_block
                    return bb_rename_range[old_succ_block]
                end
            end
        end
    end

    if need_split_before
        push!(state.new_cfg_blocks[first(bb_rename_range)].preds, first(bb_rename_range)-1)
    end

    any_edges = false
    for (old_block, new_block) in enumerate(bb_rename_range)
        if (length(state.new_cfg_blocks[new_block].succs) == 0)
            terminator_idx = last(inlinee_cfg.blocks[old_block].stmts)
            terminator = spec.ir[SSAValue(terminator_idx)]
            if isa(terminator, ReturnNode) && isdefined(terminator, :val)
                any_edges = true
                push!(state.new_cfg_blocks[new_block].succs, post_bb_id)
                if need_split
                    push!(state.new_cfg_blocks[post_bb_id].preds, new_block)
                end
            end
        end
    end

    if !any_edges
        push!(state.dead_blocks, post_bb_id)
    end
end

function cfg_inline_unionsplit!(ir::IRCode, idx::Int, item::UnionSplit, state::CFGInliningState)
    block = block_for_inst(ir, idx)
    inline_into_block!(state, block)
    from_bbs = Int[]
    delete!(state.split_targets, length(state.new_cfg_blocks))
    orig_succs = copy(state.new_cfg_blocks[end].succs)
    empty!(state.new_cfg_blocks[end].succs)
    for (i, (_, case)) in enumerate(item.cases)
        # The condition gets sunk into the previous block
        # Add a block for the union-split body
        push!(state.new_cfg_blocks, BasicBlock(StmtRange(idx, idx)))
        cond_bb = length(state.new_cfg_blocks)-1
        push!(state.new_cfg_blocks[end].preds, cond_bb)
        push!(state.new_cfg_blocks[cond_bb].succs, cond_bb+1)
        if isa(case, InliningTodo)
            spec = case.spec::ResolvedInliningSpec
            if !spec.linear_inline_eligible
                cfg_inline_item!(ir, idx, spec, state, true)
            end
        end
        bb = length(state.new_cfg_blocks)
        push!(from_bbs, bb)
        # TODO: Right now we unconditionally generate a fallback block
        # in case of subtyping errors - This is probably unnecessary.
        if true # i != length(item.cases) || !item.fully_covered
            # This block will have the next condition or the final else case
            push!(state.new_cfg_blocks, BasicBlock(StmtRange(idx, idx)))
            push!(state.new_cfg_blocks[cond_bb].succs, length(state.new_cfg_blocks))
            push!(state.new_cfg_blocks[end].preds, cond_bb)
            push!(item.bbs, length(state.new_cfg_blocks))
        end
    end
    # The edge from the fallback block.
    if !item.fully_covered
        push!(from_bbs, length(state.new_cfg_blocks))
    end
    # This block will be the block everyone returns to
    push!(state.new_cfg_blocks, BasicBlock(StmtRange(idx, idx), from_bbs, orig_succs))
    join_bb = length(state.new_cfg_blocks)
    push!(state.split_targets, join_bb)
    push!(item.bbs, join_bb)
    for bb in from_bbs
        push!(state.new_cfg_blocks[bb].succs, join_bb)
    end
end

function finish_cfg_inline!(state::CFGInliningState)
    new_range = (state.first_bb + 1):length(state.cfg.blocks)
    l = length(state.new_cfg_blocks)
    state.bb_rename[new_range] = (l+1:l+length(new_range))
    append!(state.new_cfg_blocks, state.cfg.blocks[new_range])

    # Rename edges original bbs
    for (orig_bb, bb) in pairs(state.bb_rename)
        p, s = state.new_cfg_blocks[bb].preds, state.new_cfg_blocks[bb].succs
        map!(p, p) do pred_bb
            pred_bb == length(state.bb_rename) && return length(state.new_cfg_blocks)
            return state.bb_rename[pred_bb + 1] - 1
        end
        if !(orig_bb in state.merged_orig_blocks)
            map!(s, s) do succ_bb
                return state.bb_rename[succ_bb]
            end
        end
    end

    for bb in collect(state.split_targets)
        s = state.new_cfg_blocks[bb].succs
        map!(s, s) do succ_bb
            return state.bb_rename[succ_bb]
        end
    end

    # Rename any annotated original bb references
    for bb in 1:length(state.new_cfg_blocks)
        s = state.new_cfg_blocks[bb].succs
        map!(s, s) do succ_bb
            return succ_bb < 0 ? state.bb_rename[-succ_bb] : succ_bb
        end
    end

    # Kill dead blocks
    for block in state.dead_blocks
        for succ in state.new_cfg_blocks[block].succs
            kill_edge!(state.new_cfg_blocks, block, succ)
        end
    end
end

function ir_inline_item!(compact::IncrementalCompact, idx::Int, argexprs::Vector{Any},
                         linetable::Vector{LineInfoNode}, item::InliningTodo,
                         boundscheck::Symbol, todo_bbs::Vector{Tuple{Int, Int}})
    # Ok, do the inlining here
    spec = item.spec::ResolvedInliningSpec
    inline_cfg = spec.ir.cfg
    stmt = compact.result[idx][:inst]
    linetable_offset::Int32 = length(linetable)
    # Append the linetable of the inlined function to our line table
    inlined_at = Int(compact.result[idx][:line])
    for entry in spec.ir.linetable
        push!(linetable, LineInfoNode(entry.module, entry.method, entry.file, entry.line,
            (entry.inlined_at > 0 ? entry.inlined_at + linetable_offset : inlined_at)))
    end
    nargs_def = item.mi.def.nargs
    isva = nargs_def > 0 && item.mi.def.isva
    if isva
        vararg = mk_tuplecall!(compact, argexprs[nargs_def:end], compact.result[idx][:line])
        argexprs = Any[argexprs[1:(nargs_def - 1)]..., vararg]
    end
    flag = compact.result[idx][:flag]
    boundscheck_idx = boundscheck
    if boundscheck_idx === :default || boundscheck_idx === :propagate
        if (flag & IR_FLAG_INBOUNDS) != 0
            boundscheck_idx = :off
        end
    end
    # If the iterator already moved on to the next basic block,
    # temporarily re-open in again.
    local return_value
    # Special case inlining that maintains the current basic block if there's only one BB in the target
    if spec.linear_inline_eligible
        terminator = spec.ir[SSAValue(last(inline_cfg.blocks[1].stmts))]
        #compact[idx] = nothing
        inline_compact = IncrementalCompact(compact, spec.ir, compact.result_idx)
        for ((_, idx′), stmt′) in inline_compact
            # This dance is done to maintain accurate usage counts in the
            # face of rename_arguments! mutating in place - should figure out
            # something better eventually.
            inline_compact[idx′] = nothing
            stmt′ = ssa_substitute!(idx′, stmt′, argexprs, item.mi.def.sig, item.mi.sparam_vals, linetable_offset, boundscheck_idx, compact)
            if isa(stmt′, ReturnNode)
                isa(stmt′.val, SSAValue) && (compact.used_ssas[stmt′.val.id] += 1)
                return_value = SSAValue(idx′)
                inline_compact[idx′] = stmt′.val
                val = stmt′.val
                inline_compact.result[idx′][:type] = (isa(val, Argument) || isa(val, Expr)) ?
                    compact_exprtype(compact, stmt′.val) :
                    compact_exprtype(inline_compact, stmt′.val)
                break
            end
            inline_compact[idx′] = stmt′
        end
        just_fixup!(inline_compact)
        compact.result_idx = inline_compact.result_idx
    else
        bb_offset, post_bb_id = popfirst!(todo_bbs)
        # This implements the need_split_before flag above
        need_split_before = !isempty(spec.ir.cfg.blocks[1].preds)
        if need_split_before
            finish_current_bb!(compact, 0)
        end
        pn = PhiNode()
        #compact[idx] = nothing
        inline_compact = IncrementalCompact(compact, spec.ir, compact.result_idx)
        for ((_, idx′), stmt′) in inline_compact
            inline_compact[idx′] = nothing
            stmt′ = ssa_substitute!(idx′, stmt′, argexprs, item.mi.def.sig, item.mi.sparam_vals, linetable_offset, boundscheck_idx, compact)
            if isa(stmt′, ReturnNode)
                if isdefined(stmt′, :val)
                    val = stmt′.val
                    # GlobalRefs can have side effects, but are currently
                    # allowed in arguments of ReturnNodes
                    push!(pn.edges, inline_compact.active_result_bb-1)
                    if isa(val, GlobalRef) || isa(val, Expr)
                        stmt′ = val
                        inline_compact.result[idx′][:type] = (isa(val, Argument) || isa(val, Expr)) ?
                            compact_exprtype(compact, val) :
                            compact_exprtype(inline_compact, val)
                        insert_node_here!(inline_compact, GotoNode(post_bb_id),
                                          Any, compact.result[idx′][:line],
                                          true)
                        push!(pn.values, SSAValue(idx′))
                    else
                        push!(pn.values, val)
                        stmt′ = GotoNode(post_bb_id)
                    end

                end
            elseif isa(stmt′, GotoNode)
                stmt′ = GotoNode(stmt′.label + bb_offset)
            elseif isa(stmt′, Expr) && stmt′.head === :enter
                stmt′ = Expr(:enter, stmt′.args[1] + bb_offset)
            elseif isa(stmt′, GotoIfNot)
                stmt′ = GotoIfNot(stmt′.cond, stmt′.dest + bb_offset)
            elseif isa(stmt′, PhiNode)
                stmt′ = PhiNode(Int32[edge+bb_offset for edge in stmt′.edges], stmt′.values)
            end
            inline_compact[idx′] = stmt′
        end
        just_fixup!(inline_compact)
        compact.result_idx = inline_compact.result_idx
        compact.active_result_bb = inline_compact.active_result_bb
        for i = 1:length(pn.values)
            isassigned(pn.values, i) || continue
            if isa(pn.values[i], SSAValue)
                compact.used_ssas[pn.values[i].id] += 1
            end
        end
        if length(pn.edges) == 1
            return_value = pn.values[1]
        else
            return_value = insert_node_here!(compact, pn, compact_exprtype(compact, SSAValue(idx)), compact.result[idx][:line])
        end
    end
    return_value
end

const fatal_type_bound_error = ErrorException("fatal error in type inference (type bound)")

function ir_inline_unionsplit!(compact::IncrementalCompact, idx::Int,
                               argexprs::Vector{Any}, linetable::Vector{LineInfoNode},
                               item::UnionSplit, boundscheck::Symbol, todo_bbs::Vector{Tuple{Int, Int}})
    stmt, typ, line = compact.result[idx][:inst], compact.result[idx][:type], compact.result[idx][:line]
    atype = item.atype
    generic_bb = item.bbs[end-1]
    join_bb = item.bbs[end]
    bb = compact.active_result_bb
    pn = PhiNode()
    has_generic = false
    @assert length(item.bbs) > length(item.cases)
    for ((metharg, case), next_cond_bb) in zip(item.cases, item.bbs)
        @assert !isa(metharg, UnionAll)
        cond = true
        @assert length(atype.parameters) == length(metharg.parameters)
        for i in 1:length(atype.parameters)
            a, m = atype.parameters[i], metharg.parameters[i]
            # If this is always true, we don't need to check for it
            a <: m && continue
            # Generate isa check
            isa_expr = Expr(:call, isa, argexprs[i], m)
            ssa = insert_node_here!(compact, isa_expr, Bool, line)
            if cond === true
                cond = ssa
            else
                and_expr = Expr(:call, and_int, cond, ssa)
                cond = insert_node_here!(compact, and_expr, Bool, line)
            end
        end
        insert_node_here!(compact, GotoIfNot(cond, next_cond_bb), Union{}, line)
        bb = next_cond_bb - 1
        finish_current_bb!(compact, 0)
        argexprs′ = argexprs
        if !isa(case, ConstantCase)
            argexprs′ = copy(argexprs)
            for i = 1:length(metharg.parameters)
                a, m = atype.parameters[i], metharg.parameters[i]
                (isa(argexprs[i], SSAValue) || isa(argexprs[i], Argument)) || continue
                if !(a <: m)
                    argexprs′[i] = insert_node_here!(compact, PiNode(argexprs′[i], m),
                                                     m, line)
                end
            end
        end
        if isa(case, InliningTodo)
            val = ir_inline_item!(compact, idx, argexprs′, linetable, case, boundscheck, todo_bbs)
        elseif isa(case, MethodInstance)
            val = insert_node_here!(compact, Expr(:invoke, case, argexprs′...), typ, line)
        else
            case = case::ConstantCase
            val = case.val
        end
        if !isempty(compact.result_bbs[bb].preds)
            push!(pn.edges, bb)
            push!(pn.values, val)
            insert_node_here!(compact, GotoNode(join_bb), Union{}, line)
        else
            insert_node_here!(compact, ReturnNode(), Union{}, line)
        end
        finish_current_bb!(compact, 0)
    end
    bb += 1
    # We're now in the fall through block, decide what to do
    if item.fully_covered
        e = Expr(:call, GlobalRef(Core, :throw), fatal_type_bound_error)
        insert_node_here!(compact, e, Union{}, line)
        insert_node_here!(compact, ReturnNode(), Union{}, line)
        finish_current_bb!(compact, 0)
    else
        ssa = insert_node_here!(compact, stmt, typ, line)
        push!(pn.edges, bb)
        push!(pn.values, ssa)
        insert_node_here!(compact, GotoNode(join_bb), Union{}, line)
        finish_current_bb!(compact, 0)
    end

    # We're now in the join block.
    compact.ssa_rename[compact.idx-1] = insert_node_here!(compact, pn, typ, line)
    nothing
end

function batch_inline!(todo::Vector{Pair{Int, Any}}, ir::IRCode, linetable::Vector{LineInfoNode}, propagate_inbounds::Bool)
    # Compute the new CFG first (modulo statement ranges, which will be computed below)
    state = CFGInliningState(ir)
    for (idx, item) in todo
        if isa(item, UnionSplit)
            cfg_inline_unionsplit!(ir, idx, item::UnionSplit, state)
        else
            item = item::InliningTodo
            spec = item.spec::ResolvedInliningSpec
            # A linear inline does not modify the CFG
            spec.linear_inline_eligible && continue
            cfg_inline_item!(ir, idx, spec, state, false)
        end
    end
    finish_cfg_inline!(state)

    boundscheck = inbounds_option()
    if boundscheck === :default && propagate_inbounds
        boundscheck = :propagate
    end

    let compact = IncrementalCompact(ir, false)
        compact.result_bbs = state.new_cfg_blocks
        # This needs to be a minimum and is more of a size hint
        nn = 0
        for (_, item) in todo
            if isa(item, InliningTodo)
                spec = item.spec::ResolvedInliningSpec
                nn += (length(spec.ir.stmts) + length(spec.ir.new_nodes))
            end
        end
        nnewnodes = length(compact.result) + nn
        resize!(compact, nnewnodes)
        (inline_idx, item) = popfirst!(todo)
        for ((old_idx, idx), stmt) in compact
            if old_idx == inline_idx
                argexprs = copy(stmt.args)
                refinish = false
                if compact.result_idx == first(compact.result_bbs[compact.active_result_bb].stmts)
                    compact.active_result_bb -= 1
                    refinish = true
                end
                # At the moment we will allow globalrefs in argument position, turn those into ssa values
                for aidx in 1:length(argexprs)
                    aexpr = argexprs[aidx]
                    if isa(aexpr, GlobalRef) || isa(aexpr, Expr)
                        argexprs[aidx] = insert_node_here!(compact, aexpr, compact_exprtype(compact, aexpr), compact.result[idx][:line])
                    end
                end
                if isa(item, InliningTodo)
                    compact.ssa_rename[old_idx] = ir_inline_item!(compact, idx, argexprs, linetable, item, boundscheck, state.todo_bbs)
                elseif isa(item, UnionSplit)
                    ir_inline_unionsplit!(compact, idx, argexprs, linetable, item, boundscheck, state.todo_bbs)
                end
                compact[idx] = nothing
                refinish && finish_current_bb!(compact, 0)
                if !isempty(todo)
                    (inline_idx, item) = popfirst!(todo)
                else
                    inline_idx = -1
                end
            elseif isa(stmt, GotoNode)
                compact[idx] = GotoNode(state.bb_rename[stmt.label])
            elseif isa(stmt, Expr) && stmt.head === :enter
                compact[idx] = Expr(:enter, state.bb_rename[stmt.args[1]])
            elseif isa(stmt, GotoIfNot)
                compact[idx] = GotoIfNot(stmt.cond, state.bb_rename[stmt.dest])
            elseif isa(stmt, PhiNode)
                compact[idx] = PhiNode(Int32[edge == length(state.bb_rename) ? length(state.new_cfg_blocks) : state.bb_rename[edge+1]-1 for edge in stmt.edges], stmt.values)
            end
        end

        ir = finish(compact)
    end
    return ir
end

# This assumes the caller has verified that all arguments to the _apply_iterate call are Tuples.
function rewrite_apply_exprargs!(ir::IRCode, todo::Vector{Pair{Int, Any}}, idx::Int,
        argexprs::Vector{Any}, atypes::Vector{Any}, arginfos::Vector{Any},
        arg_start::Int, et::Union{EdgeTracker, Nothing}, caches::Union{InferenceCaches, Nothing},
        params::OptimizationParams)

    new_argexprs = Any[argexprs[arg_start]]
    new_atypes = Any[atypes[arg_start]]
    # loop over original arguments and flatten any known iterators
    for i in (arg_start+1):length(argexprs)
        def = argexprs[i]
        def_type = atypes[i]
        thisarginfo = arginfos[i-arg_start]
        if thisarginfo === nothing
            if def_type isa PartialStruct
                # def_type.typ <: Tuple is assumed
                def_atypes = def_type.fields
            else
                def_atypes = Any[]
                if isa(def_type, Const) # && isa(def_type.val, Union{Tuple, SimpleVector}) is implied
                    for p in def_type.val
                        push!(def_atypes, Const(p))
                    end
                else
                    ti = widenconst(def_type)
                    if ti.name === NamedTuple_typename
                        ti = ti.parameters[2]
                    end
                    for p in ti.parameters
                        if isa(p, DataType) && isdefined(p, :instance)
                            # replace singleton types with their equivalent Const object
                            p = Const(p.instance)
                        elseif isconstType(p)
                            p = Const(p.parameters[1])
                        end
                        push!(def_atypes, p)
                    end
                end
            end
            # now push flattened types into new_atypes and getfield exprs into new_argexprs
            for j in 1:length(def_atypes)
                def_atype = def_atypes[j]
                if isa(def_atype, Const) && is_inlineable_constant(def_atype.val)
                    new_argexpr = quoted(def_atype.val)
                else
                    new_call = Expr(:call, GlobalRef(Core, :getfield), def, j)
                    new_argexpr = insert_node!(ir, idx, def_atype, new_call)
                end
                push!(new_argexprs, new_argexpr)
                push!(new_atypes, def_atype)
            end
        else
            state = Core.svec()
            for i = 1:length(thisarginfo.each)
                call = thisarginfo.each[i]
                new_stmt = Expr(:call, argexprs[2], def, state...)
                state1 = insert_node!(ir, idx, call.rt, new_stmt)
                new_sig = with_atype(call_sig(ir, new_stmt))
                if isa(call.info, MethodMatchInfo) || isa(call.info, UnionSplitInfo)
                    info = isa(call.info, MethodMatchInfo) ?
                        MethodMatchInfo[call.info] : call.info.matches
                    # See if we can inline this call to `iterate`
                    analyze_single_call!(ir, todo, state1.id, new_stmt,
                        new_sig, call.rt, info, et, caches, params)
                end
                if i != length(thisarginfo.each)
                    valT = getfield_tfunc(call.rt, Const(1))
                    val_extracted = insert_node!(ir, idx, valT,
                        Expr(:call, GlobalRef(Core, :getfield), state1, 1))
                    push!(new_argexprs, val_extracted)
                    push!(new_atypes, valT)
                    state_extracted = insert_node!(ir, idx, getfield_tfunc(call.rt, Const(2)),
                        Expr(:call, GlobalRef(Core, :getfield), state1, 2))
                    state = Core.svec(state_extracted)
                end
            end
        end
    end
    return new_argexprs, new_atypes
end

function rewrite_invoke_exprargs!(argexprs::Vector{Any})
    argexpr0 = argexprs[2]
    argexprs = argexprs[4:end]
    pushfirst!(argexprs, argexpr0)
    return argexprs
end

function singleton_type(@nospecialize(ft))
    if isa(ft, Const)
        return ft.val
    elseif ft isa DataType && isdefined(ft, :instance)
        return ft.instance
    end
    return nothing
end

function compileable_specialization(et::Union{EdgeTracker, Nothing}, match::MethodMatch)
    mi = specialize_method(match, false, true)
    mi !== nothing && et !== nothing && push!(et, mi::MethodInstance)
    return mi
end

function resolve_todo(todo::InliningTodo, et::Union{EdgeTracker, Nothing}, caches::InferenceCaches)
    spec = todo.spec::DelayedInliningSpec
    isconst, src = find_inferred(todo.mi, spec.atypes, caches, spec.stmttype)

    if isconst
        push!(et, todo.mi)
        return ConstantCase(src)
    end

    if src === nothing
        return compileable_specialization(et, spec.match)
    end

    if isa(src, CodeInfo) || isa(src, Vector{UInt8})
        src_inferred = ccall(:jl_ir_flag_inferred, Bool, (Any,), src)
        src_inlineable = ccall(:jl_ir_flag_inlineable, Bool, (Any,), src)

        if !(src_inferred && src_inlineable)
            return compileable_specialization(et, spec.match)
        end
    elseif isa(src, IRCode)
        src = copy(src)
    end

    et !== nothing && push!(et, todo.mi)
    return InliningTodo(todo.mi, src)
end

function resolve_todo(todo::UnionSplit, et::Union{EdgeTracker, Nothing}, caches::InferenceCaches)
    UnionSplit(todo.fully_covered, todo.atype,
        Pair{Any,Any}[sig=>resolve_todo(item, et, caches) for (sig, item) in todo.cases])
end

function resolve_todo!(todo::Vector{Pair{Int, Any}}, et::Union{EdgeTracker, Nothing}, caches::InferenceCaches)
    for i = 1:length(todo)
        idx, item = todo[i]
        todo[i] = idx=>resolve_todo(item, et, caches)
    end
    todo
end

function analyze_method!(match::MethodMatch, atypes::Vector{Any},
                         et::Union{EdgeTracker, Nothing},
                         caches::Union{InferenceCaches, Nothing},
                         params::OptimizationParams, @nospecialize(stmttyp))
    method = match.method
    methsig = method.sig

    # Check that we habe the correct number of arguments
    na = Int(method.nargs)
    npassedargs = length(atypes)
    if na != npassedargs && !(na > 0 && method.isva)
        # we have a method match only because an earlier
        # inference step shortened our call args list, even
        # though we have too many arguments to actually
        # call this function
        return nothing
    end

    # Bail out if any static parameters are left as TypeVar
    ok = true
    for i = 1:length(match.sparams)
        (isa(match.sparams[i], TypeVar) || isa(match.sparams[i], Core.TypeofVararg)) && return nothing
    end

    if !params.inlining
        return compileable_specialization(et, match)
    end

    # See if there exists a specialization for this method signature
    mi = specialize_method(match, true) # Union{Nothing, MethodInstance}
    if !isa(mi, MethodInstance)
        return compileable_specialization(et, match)
    end

    todo = InliningTodo(mi, match, atypes, stmttyp)
    # If we don't have caches here, delay resolving this MethodInstance
    # until the batch inlining step (or an external post-processing pass)
    caches === nothing && return todo
    return resolve_todo(todo, et, caches)
end

function InliningTodo(mi::MethodInstance, ir::IRCode)
    return InliningTodo(mi, ResolvedInliningSpec(ir, linear_inline_eligible(ir)))
end

function InliningTodo(mi::MethodInstance, src::Union{CodeInfo, Array{UInt8, 1}})
    if !isa(src, CodeInfo)
        src = ccall(:jl_uncompress_ir, Any, (Any, Ptr{Cvoid}, Any), mi.def, C_NULL, src::Vector{UInt8})::CodeInfo
    end

    @timeit "inline IR inflation" begin
        return InliningTodo(mi, inflate_ir(src, mi)::IRCode)
    end
end

# Neither the product iterator not CartesianIndices are available
# here, so use this poor man's version
struct SimpleCartesian
    ranges::Vector{UnitRange{Int}}
end
function iterate(s::SimpleCartesian, state::Vector{Int}=Int[1 for _ in 1:length(s.ranges)])
    state[end] > last(s.ranges[end]) && return nothing
    vals = copy(state)
    any = false
    for i = 1:length(s.ranges)
        if state[i] < last(s.ranges[i])
            for j = 1:(i-1)
                state[j] = first(s.ranges[j])
            end
            state[i] += 1
            any = true
            break
        end
    end
    if !any
        state[end] += 1
    end
    (vals, state)
end

# Given a signure, iterate over the signatures to union split over
struct UnionSplitSignature
    it::SimpleCartesian
    typs::Vector{Any}
end

function UnionSplitSignature(atypes::Vector{Any})
    typs = Any[uniontypes(widenconst(atypes[i])) for i = 1:length(atypes)]
    ranges = UnitRange{Int}[1:length(typs[i]) for i = 1:length(typs)]
    return UnionSplitSignature(SimpleCartesian(ranges), typs)
end

function iterate(split::UnionSplitSignature, state::Vector{Int}...)
    y = iterate(split.it, state...)
    y === nothing && return nothing
    idxs, state = y
    sig = Any[split.typs[i][j] for (i, j) in enumerate(idxs)]
    return (sig, state)
end

function handle_single_case!(ir::IRCode, stmt::Expr, idx::Int, @nospecialize(case), isinvoke::Bool, todo::Vector{Pair{Int, Any}})
    if isa(case, ConstantCase)
        ir[SSAValue(idx)] = case.val
    elseif isa(case, MethodInstance)
        if isinvoke
            stmt.args = rewrite_invoke_exprargs!(stmt.args)
        end
        stmt.head = :invoke
        pushfirst!(stmt.args, case)
    elseif case === nothing
        # Do, well, nothing
    else
        if isinvoke
            stmt.args = rewrite_invoke_exprargs!(stmt.args)
        end
        push!(todo, idx=>(case::InliningTodo))
    end
    nothing
end

function is_valid_type_for_apply_rewrite(@nospecialize(typ), params::OptimizationParams)
    if isa(typ, Const) && isa(typ.val, SimpleVector)
        length(typ.val) > params.MAX_TUPLE_SPLAT && return false
        for p in typ.val
            is_inlineable_constant(p) || return false
        end
        return true
    end
    typ = widenconst(typ)
    if isa(typ, DataType) && typ.name === NamedTuple_typename
        typ = typ.parameters[2]
        while isa(typ, TypeVar)
            typ = typ.ub
        end
    end
    isa(typ, DataType) || return false
    if typ.name === Tuple.name
        return !isvatuple(typ) && length(typ.parameters) <= params.MAX_TUPLE_SPLAT
    else
        return false
    end
end

function inline_splatnew!(ir::IRCode, idx::Int)
    stmt = ir.stmts[idx][:inst]
    ty = ir.stmts[idx][:type]
    nf = nfields_tfunc(ty)
    if nf isa Const
        eargs = stmt.args
        tup = eargs[2]
        tt = argextype(tup, ir, ir.sptypes)
        tnf = nfields_tfunc(tt)
        # TODO: hoisting this tnf.val === nf.val check into codegen
        # would enable us to almost always do this transform
        if tnf isa Const && tnf.val === nf.val
            n = tnf.val
            new_argexprs = Any[eargs[1]]
            for j = 1:n
                atype = getfield_tfunc(tt, Const(j))
                new_call = Expr(:call, Core.getfield, tup, j)
                new_argexpr = insert_node!(ir, idx, atype, new_call)
                push!(new_argexprs, new_argexpr)
            end
            stmt.head = :new
            stmt.args = new_argexprs
        end
    end
    nothing
end

function call_sig(ir::IRCode, stmt::Expr)
    isempty(stmt.args) && return nothing
    ft = argextype(stmt.args[1], ir, ir.sptypes)
    has_free_typevars(ft) && return nothing
    f = singleton_type(ft)
    f === Core.Intrinsics.llvmcall && return nothing
    f === Core.Intrinsics.cglobal && return nothing
    atypes = Vector{Any}(undef, length(stmt.args))
    atypes[1] = ft
    ok = true
    for i = 2:length(stmt.args)
        a = argextype(stmt.args[i], ir, ir.sptypes)
        (a === Bottom || isvarargtype(a)) && return nothing
        atypes[i] = a
    end

    Signature(f, ft, atypes)
end

function inline_apply!(ir::IRCode, todo::Vector{Pair{Int, Any}}, idx::Int, sig::Signature,
                       et, caches, params::OptimizationParams)
    stmt = ir.stmts[idx][:inst]
    while sig.f === Core._apply_iterate
        info = ir.stmts[idx][:info]
        if isa(info, UnionSplitApplyCallInfo)
            if length(info.infos) != 1
                # TODO: Handle union split applies?
                new_info = info = nothing
            else
                info = info.infos[1]
                new_info = info.call
            end
        else
            @assert info === nothing || info === false
            new_info = info = nothing
        end
        arg_start = 3
        atypes = sig.atypes
        if arg_start > length(atypes)
            return nothing
        end
        ft = atypes[arg_start]
        if ft isa Const && ft.val === Core.tuple
            # if one argument is a tuple already, and the rest are empty, we can just return it
            # e.g. rewrite `((t::Tuple)...,)` to `t`
            nonempty_idx = 0
            for i = (arg_start + 1):length(atypes)
                ti = atypes[i]
                ti ⊑ Tuple{} && continue
                if ti ⊑ Tuple && nonempty_idx == 0
                    nonempty_idx = i
                    continue
                end
                nonempty_idx = 0
                break
            end
            if nonempty_idx != 0
                ir.stmts[idx][:inst] = stmt.args[nonempty_idx]
                return nothing
            end
        end
        # Try to figure out the signature of the function being called
        # and if rewrite_apply_exprargs can deal with this form
        infos = Any[]
        for i = (arg_start + 1):length(atypes)
            thisarginfo = nothing
            if !is_valid_type_for_apply_rewrite(atypes[i], params)
                if isa(info, ApplyCallInfo) && info.arginfo[i-arg_start] !== nothing
                    thisarginfo = info.arginfo[i-arg_start]
                else
                    return nothing
                end
            end
            push!(infos, thisarginfo)
        end
        # Independent of whether we can inline, the above analysis allows us to rewrite
        # this apply call to a regular call
        stmt.args, atypes = rewrite_apply_exprargs!(ir, todo, idx, stmt.args, atypes, infos, arg_start, et, caches, params)
        ir.stmts[idx][:info] = new_info
        has_free_typevars(ft) && return nothing
        f = singleton_type(ft)
        sig = Signature(f, ft, atypes)
    end
    sig
end

# TODO: this test is wrong if we start to handle Unions of function types later
is_builtin(s::Signature) =
    isa(s.f, IntrinsicFunction) ||
    s.ft ⊑ IntrinsicFunction ||
    isa(s.f, Builtin) ||
    s.ft ⊑ Builtin

function inline_invoke!(ir::IRCode, idx::Int, sig::Signature, invoke_data::InvokeData, state::InliningState, todo::Vector{Pair{Int, Any}})
    stmt = ir.stmts[idx][:inst]
    calltype = ir.stmts[idx][:type]
    method = invoke_data.entry
    (metharg, methsp) = ccall(:jl_type_intersection_with_env, Any, (Any, Any),
            sig.atype, method.sig)::SimpleVector
    methsp = methsp::SimpleVector
    match = MethodMatch(metharg, methsp, method, true)
    result = analyze_method!(match, sig.atypes, state.et, state.caches, state.params, calltype)
    handle_single_case!(ir, stmt, idx, result, true, todo)
    intersect!(state.et, WorldRange(invoke_data.min_valid, invoke_data.max_valid))
    return nothing
end

# Handles all analysis and inlining of intrinsics and builtins. In particular,
# this method does not access the method table or otherwise process generic
# functions.
function process_simple!(ir::IRCode, todo::Vector{Pair{Int, Any}}, idx::Int, state::InliningState)
    stmt = ir.stmts[idx][:inst]
    stmt isa Expr || return nothing
    if stmt.head === :splatnew
        inline_splatnew!(ir, idx)
        return nothing
    end

    stmt.head === :call || return nothing

    sig = call_sig(ir, stmt)
    sig === nothing && return nothing

    # Handle _apply_iterate
    sig = inline_apply!(ir, todo, idx, sig, state.et, state.caches, state.params)
    sig === nothing && return nothing

    # Check if we match any of the early inliners
    calltype = ir.stmts[idx][:type]
    res = early_inline_special_case(ir, sig, stmt, state.params, calltype)
    if res !== nothing
        ir.stmts[idx][:inst] = res
        return nothing
    end

    # Handle invoke
    invoke_data = nothing
    if sig.f === Core.invoke && length(sig.atypes) >= 3
        res = compute_invoke_data(sig.atypes, state.method_table)
        res === nothing && return nothing
        (sig, invoke_data) = res
    elseif is_builtin(sig)
        # No inlining for builtins (other than what was previously handled)
        return nothing
    end

    sig = with_atype(sig)

    # In :invoke, make sure that the arguments we're passing are a subtype of the
    # signature we're invoking.
    (invoke_data === nothing || sig.atype <: invoke_data.types0) || return nothing

    # Special case inliners for regular functions
    if late_inline_special_case!(ir, sig, idx, stmt, state.params) || is_return_type(sig.f)
        return nothing
    end
    return (sig, invoke_data)
end

# This is not currently called in the regular course, but may be needed
# if we ever want to re-run inlining again later in the pass pipeline after
# additional type information was discovered.
function recompute_method_matches(@nospecialize(atype), params::OptimizationParams, et::EdgeTracker, method_table::MethodTableView)
    # Regular case: Retrieve matching methods from cache (or compute them)
    # World age does not need to be taken into account in the cache
    # because it is forwarded from type inference through `sv.params`
    # in the case that the cache is nonempty, so it should be unchanged
    # The max number of methods should be the same as in inference most
    # of the time, and should not affect correctness otherwise.
    results = findall(atype, method_table; limit=params.MAX_METHODS)
    results !== missing && intersect!(et, results.valid_worlds)
    MethodMatchInfo(results)
end

function analyze_single_call!(ir::IRCode, todo::Vector{Pair{Int, Any}}, idx::Int, @nospecialize(stmt),
        sig::Signature, @nospecialize(calltype), infos::Vector{MethodMatchInfo},
        et, caches, params)
    cases = Pair{Any, Any}[]
    signature_union = Union{}
    only_method = nothing  # keep track of whether there is one matching method
    too_many = false
    local meth
    local fully_covered = true
    for i in 1:length(infos)
        info = infos[i]
        meth = info.results
        if meth === missing || meth.ambig
            # Too many applicable methods
            # Or there is a (partial?) ambiguity
            too_many = true
            break
        elseif length(meth) == 0
            # No applicable methods; try next union split
            continue
        elseif length(meth) == 1 && only_method !== false
            if only_method === nothing
                only_method = meth[1].method
            elseif only_method !== meth[1].method
                only_method = false
            end
        else
            only_method = false
        end
        for match in meth
            signature_union = Union{signature_union, match.spec_types}
            if !isdispatchtuple(match.spec_types)
                fully_covered = false
                continue
            end
            case = analyze_method!(match, sig.atypes, et, caches, params, calltype)
            if case === nothing
                fully_covered = false
                continue
            elseif _any(p->p[1] === match.spec_types, cases)
                continue
            end
            push!(cases, Pair{Any,Any}(match.spec_types, case))
        end
    end

    too_many && return

    signature_fully_covered = sig.atype <: signature_union
    # If we're fully covered and there's only one applicable method,
    # we inline, even if the signature is not a dispatch tuple
    if signature_fully_covered && length(cases) == 0 && only_method isa Method
        if length(infos) > 1
            (metharg, methsp) = ccall(:jl_type_intersection_with_env, Any, (Any, Any),
                sig.atype, only_method.sig)::SimpleVector
            match = MethodMatch(metharg, methsp, only_method, true)
        else
            @assert length(meth) == 1
            match = meth[1]
        end
        fully_covered = true
        case = analyze_method!(match, sig.atypes, et, caches, params, calltype)
        case === nothing && return
        push!(cases, Pair{Any,Any}(match.spec_types, case))
    end
    if !signature_fully_covered
        fully_covered = false
    end

    # If we only have one case and that case is fully covered, we may either
    # be able to do the inlining now (for constant cases), or push it directly
    # onto the todo list
    if fully_covered && length(cases) == 1
        handle_single_case!(ir, stmt, idx, cases[1][2], false, todo)
        return
    end
    length(cases) == 0 && return
    push!(todo, idx=>UnionSplit(fully_covered, sig.atype, cases))
    return nothing
end

function assemble_inline_todo!(ir::IRCode, state::InliningState)
    # todo = (inline_idx, (isva, isinvoke, na), method, spvals, inline_linetable, inline_ir, lie)
    todo = Pair{Int, Any}[]
    for idx in 1:length(ir.stmts)
        r = process_simple!(ir, todo, idx, state)
        r === nothing && continue

        stmt = ir.stmts[idx][:inst]
        calltype = ir.stmts[idx][:type]
        info = ir.stmts[idx][:info]
        # Inference determined this couldn't be analyzed. Don't question it.
        if info === false
            continue
        end

        (sig, invoke_data) = r

        # Check whether this call was @pure and evaluates to a constant
        if calltype isa Const && info isa MethodResultPure
            if is_inlineable_constant(calltype.val)
                ir.stmts[idx][:inst] = quoted(calltype.val)
                continue
            end
        end

        # Ok, now figure out what method to call
        if invoke_data !== nothing
            inline_invoke!(ir, idx, sig, invoke_data, state, todo)
            continue
        end

        nu = unionsplitcost(sig.atypes)
        if nu == 1 || nu > state.params.MAX_UNION_SPLITTING
            if !isa(info, MethodMatchInfo)
                if state.method_table === nothing
                    continue
                end
                info = recompute_method_matches(sig.atype, state.params, state.et, state.method_table)
            end
            infos = MethodMatchInfo[info]
        else
            if !isa(info, UnionSplitInfo)
                if state.method_table === nothing
                    continue
                end
                infos = MethodMatchInfo[]
                for union_sig in UnionSplitSignature(sig.atypes)
                    push!(infos, recompute_method_matches(argtypes_to_type(union_sig), state.params, state.et, state.method_table))
                end
            else
                infos = info.matches
            end
        end

        analyze_single_call!(ir, todo, idx, stmt, sig, calltype, infos, state.et, state.caches, state.params)
    end
    todo
end

function mk_tuplecall!(compact::IncrementalCompact, args::Vector{Any}, line_idx::Int32)
    e = Expr(:call, TOP_TUPLE, args...)
    etyp = tuple_tfunc(Any[compact_exprtype(compact, args[i]) for i in 1:length(args)])
    return insert_node_here!(compact, e, etyp, line_idx)
end

function linear_inline_eligible(ir::IRCode)
    length(ir.cfg.blocks) == 1 || return false
    terminator = ir[SSAValue(last(ir.cfg.blocks[1].stmts))]
    isa(terminator, ReturnNode) || return false
    isdefined(terminator, :val) || return false
    return true
end

function compute_invoke_data(@nospecialize(atypes), method_table)
    ft = widenconst(atypes[2])
    if !isdispatchelem(ft) || has_free_typevars(ft) || (ft <: Builtin)
        # TODO: this can be rather aggressive at preventing inlining of closures
        # but we need to check that `ft` can't have a subtype at runtime before using the supertype lookup below
        return nothing
    end
    invoke_tt = widenconst(atypes[3])
    if !isType(invoke_tt) || has_free_typevars(invoke_tt)
        return nothing
    end
    invoke_tt = invoke_tt.parameters[1]
    if !(isa(unwrap_unionall(invoke_tt), DataType) && invoke_tt <: Tuple)
        return nothing
    end
    if method_table === nothing
        # TODO: These should be forwarded in stmt_info, just like regular
        # method lookup results
        return nothing
    end
    invoke_types = rewrap_unionall(Tuple{ft, unwrap_unionall(invoke_tt).parameters...}, invoke_tt)
    invoke_entry = findsup(invoke_types, method_table)
    invoke_entry === nothing && return nothing
    method, valid_worlds = invoke_entry
    invoke_data = InvokeData(method, invoke_types, first(valid_worlds), last(valid_worlds))
    atype0 = atypes[2]
    atypes = atypes[4:end]
    pushfirst!(atypes, atype0)
    f = singleton_type(ft)
    return (Signature(f, ft, atypes), invoke_data)
end

# Check for a number of functions known to be pure
function ispuretopfunction(@nospecialize(f))
    return istopfunction(f, :typejoin) ||
        istopfunction(f, :isbits) ||
        istopfunction(f, :isbitstype) ||
        istopfunction(f, :promote_type)
end

function early_inline_special_case(ir::IRCode, s::Signature, e::Expr, params::OptimizationParams,
                                   @nospecialize(etype))
    f, ft, atypes = s.f, s.ft, s.atypes
    if (f === typeassert || ft ⊑ typeof(typeassert)) && length(atypes) == 3
        # typeassert(x::S, T) => x, when S<:T
        a3 = atypes[3]
        if (isType(a3) && !has_free_typevars(a3) && atypes[2] ⊑ a3.parameters[1]) ||
            (isa(a3, Const) && isa(a3.val, Type) && atypes[2] ⊑ a3.val)
            val = e.args[2]
            val === nothing && return QuoteNode(val)
            return val
        end
    end

    if params.inlining
        if isa(etype, Const) # || isconstType(etype)
            val = etype.val
            is_inlineable_constant(val) || return nothing
            if isa(f, IntrinsicFunction)
                if is_pure_intrinsic_infer(f) && intrinsic_nothrow(f, atypes[2:end])
                    return quoted(val)
                end
            elseif ispuretopfunction(f) || contains_is(_PURE_BUILTINS, f)
                return quoted(val)
            elseif contains_is(_PURE_OR_ERROR_BUILTINS, f)
                if _builtin_nothrow(f, atypes[2:end], etype)
                    return quoted(val)
                end
            end
        end
    end

    return nothing
end

function late_inline_special_case!(ir::IRCode, sig::Signature, idx::Int, stmt::Expr, params::OptimizationParams)
    f, ft, atypes = sig.f, sig.ft, sig.atypes
    typ = ir.stmts[idx][:type]
    if params.inlining && length(atypes) == 3 && istopfunction(f, :!==)
        # special-case inliner for !== that precedes _methods_by_ftype union splitting
        # and that works, even though inference generally avoids inferring the `!==` Method
        if isa(typ, Const)
            ir[SSAValue(idx)] = quoted(typ.val)
            return true
        end
        cmp_call = Expr(:call, GlobalRef(Core, :(===)), stmt.args[2], stmt.args[3])
        cmp_call_ssa = insert_node!(ir, idx, Bool, cmp_call)
        not_call = Expr(:call, GlobalRef(Core.Intrinsics, :not_int), cmp_call_ssa)
        ir[SSAValue(idx)] = not_call
        return true
    elseif params.inlining && length(atypes) == 3 && istopfunction(f, :(>:))
        # special-case inliner for issupertype
        # that works, even though inference generally avoids inferring the `>:` Method
        if isa(typ, Const)
            ir[SSAValue(idx)] = quoted(typ.val)
            return true
        end
        subtype_call = Expr(:call, GlobalRef(Core, :(<:)), stmt.args[3], stmt.args[2])
        ir[SSAValue(idx)] = subtype_call
        return true
    elseif is_return_type(f)
        if isconstType(typ)
            ir[SSAValue(idx)] = quoted(typ.parameters[1])
            return true
        elseif isa(typ, Const)
            ir[SSAValue(idx)] = quoted(typ.val)
            return true
        end
    end
    return false
end

function ssa_substitute!(idx::Int, @nospecialize(val), arg_replacements::Vector{Any},
                         @nospecialize(spsig), spvals::SimpleVector,
                         linetable_offset::Int32, boundscheck::Symbol, compact::IncrementalCompact)
    compact.result[idx][:flag] &= ~IR_FLAG_INBOUNDS
    compact.result[idx][:line] += linetable_offset
    return ssa_substitute_op!(val, arg_replacements, spsig, spvals, boundscheck)
end

function ssa_substitute_op!(@nospecialize(val), arg_replacements::Vector{Any},
                            @nospecialize(spsig), spvals::SimpleVector, boundscheck::Symbol)
    if isa(val, Argument)
        return arg_replacements[val.n]
    end
    if isa(val, Expr)
        e = val::Expr
        head = e.head
        if head === :static_parameter
            return quoted(spvals[e.args[1]])
        elseif head === :cfunction
            @assert !isa(spsig, UnionAll) || !isempty(spvals)
            e.args[3] = ccall(:jl_instantiate_type_in_env, Any, (Any, Any, Ptr{Any}), e.args[3], spsig, spvals)
            e.args[4] = svec(Any[
                ccall(:jl_instantiate_type_in_env, Any, (Any, Any, Ptr{Any}), argt, spsig, spvals)
                for argt
                in e.args[4] ]...)
        elseif head === :foreigncall
            @assert !isa(spsig, UnionAll) || !isempty(spvals)
            for i = 1:length(e.args)
                if i == 2
                    e.args[2] = ccall(:jl_instantiate_type_in_env, Any, (Any, Any, Ptr{Any}), e.args[2], spsig, spvals)
                elseif i == 3
                    argtuple = Any[
                        ccall(:jl_instantiate_type_in_env, Any, (Any, Any, Ptr{Any}), argt, spsig, spvals)
                        for argt
                        in e.args[3] ]
                    e.args[3] = svec(argtuple...)
                end
            end
        elseif head === :boundscheck
            if boundscheck === :off # inbounds == true
                return false
            elseif boundscheck === :propagate
                return e
            else # on or default
                return true
            end
        end
    end
    urs = userefs(val)
    for op in urs
        op[] = ssa_substitute_op!(op[], arg_replacements, spsig, spvals, boundscheck)
    end
    return urs[]
end

function find_inferred(mi::MethodInstance, atypes::Vector{Any}, caches::InferenceCaches, @nospecialize(rettype))
    if caches.inf_cache !== nothing
        # see if the method has a InferenceResult in the current cache
        # or an existing inferred code info store in `.inferred`
        haveconst = false
        for i in 1:length(atypes)
            if has_nontrivial_const_info(atypes[i])
                # have new information from argtypes that wasn't available from the signature
                haveconst = true
                break
            end
        end
        if haveconst || improvable_via_constant_propagation(rettype)
            inf_result = cache_lookup(mi, atypes, caches.inf_cache) # Union{Nothing, InferenceResult}
        else
            inf_result = nothing
        end
        #XXX: update_valid_age!(min_valid[1], max_valid[1], sv)
        if isa(inf_result, InferenceResult)
            let inferred_src = inf_result.src
                if isa(inferred_src, CodeInfo)
                    return svec(false, inferred_src)
                end
                if isa(inferred_src, Const) && is_inlineable_constant(inferred_src.val)
                    return svec(true, quoted(inferred_src.val),)
                end
            end
        end
    end

    linfo = get(caches.mi_cache, mi, nothing)
    if linfo isa CodeInstance
        if invoke_api(linfo) == 2
            # in this case function can be inlined to a constant
            return svec(true, quoted(linfo.rettype_const))
        end
        return svec(false, linfo.inferred)
    else
        # `linfo` may be `nothing` or an IRCode here
        return svec(false, linfo)
    end
end
