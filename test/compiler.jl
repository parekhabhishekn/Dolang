@testset "compiler" begin

eqs = [:(foo = log(a)+b/x(-1)), :(bar = c(1)+u*d(1))]
args = [(:a, -1), (:a, 0), (:b, 0), (:c, 0), (:c, 1), (:d, 1)]
params = [:u]
defs = Dict(:x=>:(a/(1-c(1))))
targets = [:foo, :bar]
funname = :myfun

const flat_args = [(:a, 0), (:b, 1), (:c, -1)]
const grouped_args = OrderedDict(:x=>[(:a, -1),], :y=>[(:a, 0), (:b, 0), (:c, 0)], :z=>[(:c, 1), (:d, 1)])
const flat_params = [:beta, :delta]
const grouped_params = Dict(:p => [:u])


args2 = vcat(args, [(:foo, 0), (:bar, 0)])::Vector{Tuple{Symbol,Int}}

ff = Dolang.FunctionFactory(eqs, args, params, targets=targets, defs=defs,
                            funname=funname)

# no targets
ffnt = Dolang.FunctionFactory(eqs, args2, params, defs=defs, funname=funname)

# with dispatch
ffd = Dolang.FunctionFactory(Int, eqs, args, params, targets=targets,
                             defs=defs, funname=funname)

# TODO: test grouped argument style


@testset " _unpack_expr" begin
    nms = [:a, :b, :c]
    have = Dolang._unpack_expr(nms, :V)
    @test have.head == :block
    @test have.args[1] == :(_a_ = Dolang._unpack_var(V, 1))
    @test have.args[2] == :(_b_ = Dolang._unpack_var(V, 2))
    @test have.args[3] == :(_c_ = Dolang._unpack_var(V, 3))

    d = OrderedDict(:x=>nms, :y=>[:d])
    have = Dolang._unpack_expr(d, :V)
    @test have.head == :block
    @test length(have.args) == 2

    have1 = have.args[1]
    @test have1.head == :block
    @test have1.args[1] == :(_a_ = Dolang._unpack_var(x, 1))
    @test have1.args[2] == :(_b_ = Dolang._unpack_var(x, 2))
    @test have1.args[3] == :(_c_ = Dolang._unpack_var(x, 3))

    have2 = have.args[2]
    @test have2.head == :block
    @test have2.args[1] == :(_d_ = Dolang._unpack_var(y, 1))
end

@testset " _unpack_+?\(::FunctionFactory\)" begin
    ordered_args = [(:c, 1), (:d, 1), (:a, 0), (:b, 0), (:c, 0), (:a, -1)]
    @test Dolang.arg_block(ff, :V) == Dolang._unpack_expr(args, :V)
    @test Dolang.param_block(ff, :p) == Dolang._unpack_expr(params, :p)
end

@testset " _assign_var_expr" begin
    want = :(Dolang._assign_var(out, $Inf, 1))
    @test Dolang._assign_var_expr(:out, Inf, 1) == want

    want = :(Dolang._assign_var(z__m_1, 0, foo))
    @test Dolang._assign_var_expr(:z__m_1, 0, :foo) == want
end

@testset " equation_block" begin
    have = Dolang.equation_block(ff)
    @test have.head == :block
    @test length(have.args) == 4
    @test have.args[1] == :(_foo_ = log(_a_) + _b_ / (_a_m1_ / (1 - _c_)))
    @test have.args[2] == :(_bar_ = _c__1_ + _u_ * _d__1_)
    @test have.args[3] == :(Dolang._assign_var(out, _foo_, 1))
    @test have.args[4] == :(Dolang._assign_var(out, _bar_, 2))

    # now test without targets
    have = Dolang.equation_block(ffnt)
    @test have.head == :block
    @test length(have.args) == 2

    ex1 = :(log(_a_) + _b_ / (_a_m1_ / (1 - _c_)) - _foo_)
    ex2 = :(_c__1_ + _u_ * _d__1_ - _bar_)
    @test have.args[1] == :(Dolang._assign_var(out, $ex1, 1))
    @test have.args[2] == :(Dolang._assign_var(out, $ex2, 2))
end

@testset " allocate_block" begin
    have = Dolang.allocate_block(ff)
    want = :(out = Dolang._allocate_out(eltype(V), 2, V))
    @test have == want
end

@testset " sizecheck_block" begin
    have = Dolang.sizecheck_block(ff)
    want = quote
        expected_size = Dolang._output_size(2, V)
        if size(out) != expected_size
            msg = "Expected out to be size $(expected_size), found $(size(out))"
            throw(DimensionMismatch(msg))
        end
    end

    # remove :line blocks from want
    Dolang._filter_lines!(want)
    @test have == want
end

@testset " (arg|param)_names" begin
    @test [:V] == @inferred Dolang.arg_names(ff)
    @test [:p] == @inferred Dolang.param_names(ff)
end

@testset " signature!?" begin
    @test Dolang.signature(ff) == :(myfun(::Dolang.TDer{0},V::$(AbstractVector),p))
    @test Dolang.signature!(ff) == :(myfun!(::Dolang.TDer{0},out,V::$(AbstractVector),p))

    @test Dolang.signature(ffnt) == :(myfun(::Dolang.TDer{0},V::$(AbstractVector),p))
    @test Dolang.signature!(ffnt) == :(myfun!(::Dolang.TDer{0},out,V::$(AbstractVector),p))

    # NOTE: I need to escape the Int here so that it will refer to the exact
    #       same int inside ffd
    # @test Dolang.signature(ffd) == :(myfun(::Dolang.TDer{0},::$(Int),V::$(AbstractVector),p))
    # @test Dolang.signature!(ffd) == :(myfun!(::Dolang.TDer{0},::$(Int),out,V::$(AbstractVector),p))
end

@testset " compiling functions" begin
    want = Dolang._filter_lines!(:(begin
        function myfun(::Dolang.TDer{0},V::$(AbstractVector),p)
            out = Dolang._allocate_out(eltype(V),2,V)
            begin
                begin
                    _u_ = Dolang._unpack_var(p,1)
                end
                begin
                    _a_m1_ = Dolang._unpack_var(V,1)
                    _a_ = Dolang._unpack_var(V,2)
                    _b_ = Dolang._unpack_var(V,3)
                    _c_ = Dolang._unpack_var(V,4)
                    _c__1_ = Dolang._unpack_var(V,5)
                    _d__1_ = Dolang._unpack_var(V,6)
                end
                begin
                    _foo_ = log(_a_) + _b_ / (_a_m1_ / (1 - _c_))
                    _bar_ = _c__1_ + _u_ * _d__1_
                    Dolang._assign_var(out,_foo_,1)
                    Dolang._assign_var(out,_bar_,2)
                end
                return out
            end
        end
        function myfun(V::$(AbstractVector),p)
            out = Dolang._allocate_out(eltype(V),2,V)
            begin
                begin
                    _u_ = Dolang._unpack_var(p,1)
                end
                begin
                    _a_m1_ = Dolang._unpack_var(V,1)
                    _a_ = Dolang._unpack_var(V,2)
                    _b_ = Dolang._unpack_var(V,3)
                    _c_ = Dolang._unpack_var(V,4)
                    _c__1_ = Dolang._unpack_var(V,5)
                    _d__1_ = Dolang._unpack_var(V,6)
                end
                begin
                    _foo_ = log(_a_) + _b_ / (_a_m1_ / (1 - _c_))
                    _bar_ = _c__1_ + _u_ * _d__1_
                    Dolang._assign_var(out,_foo_,1)
                    Dolang._assign_var(out,_bar_,2)
                end
                return out
            end
        end
    end))

    want_vec = Dolang._filter_lines!(:(begin
        function myfun(::Dolang.TDer{0},V::$(AbstractMatrix),p)
            out = Dolang._allocate_out(eltype(V),2,V)
            nrow = size(V,1)
            for _row = 1:nrow
                @inbounds out[_row,:] = myfun($(Dolang.Der{0}),view(V,_row,:),p)
            end
            return out
        end
        function myfun(V::$(AbstractMatrix),p)
            out = Dolang._allocate_out(eltype(V),2,V)
            nrow = size(V,1)
            for _row = 1:nrow
                @inbounds out[_row,:] = myfun($(Dolang.Der{0}),view(V,_row,:),p)
            end
            return out
        end
    end
    ))

    want! = Dolang._filter_lines!(:(begin
        function myfun!(::Dolang.TDer{0},out,V::$(AbstractVector),p)
            begin
                expected_size = Dolang._output_size(2, V)
                if size(out) != expected_size
                    msg = "Expected out to be size $(expected_size), found $(size(out))"
                    throw(DimensionMismatch(msg))
                end
            end
            begin
                begin
                    _u_ = Dolang._unpack_var(p,1)
                end
                begin
                    _a_m1_ = Dolang._unpack_var(V,1)
                    _a_ = Dolang._unpack_var(V,2)
                    _b_ = Dolang._unpack_var(V,3)
                    _c_ = Dolang._unpack_var(V,4)
                    _c__1_ = Dolang._unpack_var(V,5)
                    _d__1_ = Dolang._unpack_var(V,6)
                end
                begin
                    _foo_ = log(_a_) + _b_ / (_a_m1_ / (1 - _c_))
                    _bar_ = _c__1_ + _u_ * _d__1_
                    Dolang._assign_var(out,_foo_,1)
                    Dolang._assign_var(out,_bar_,2)
                end
                return out
            end
        end
        function myfun!(out,V::$(AbstractVector),p)
            begin
                expected_size = Dolang._output_size(2, V)
                if size(out) != expected_size
                    msg = "Expected out to be size $(expected_size), found $(size(out))"
                    throw(DimensionMismatch(msg))
                end
            end
            begin
                begin
                    _u_ = Dolang._unpack_var(p,1)
                end
                begin
                    _a_m1_ = Dolang._unpack_var(V,1)
                    _a_ = Dolang._unpack_var(V,2)
                    _b_ = Dolang._unpack_var(V,3)
                    _c_ = Dolang._unpack_var(V,4)
                    _c__1_ = Dolang._unpack_var(V,5)
                    _d__1_ = Dolang._unpack_var(V,6)
                end
                begin
                    _foo_ = log(_a_) + _b_ / (_a_m1_ / (1 - _c_))
                    _bar_ = _c__1_ + _u_ * _d__1_
                    Dolang._assign_var(out,_foo_,1)
                    Dolang._assign_var(out,_bar_,2)
                end
                return out
            end
        end
    end))

    want!_vec = Dolang._filter_lines!(:(begin
        function myfun!(::Dolang.TDer{0},out,V::$(AbstractMatrix),p)
            begin
                expected_size = Dolang._output_size(2,V)
                if size(out) != expected_size
                    msg = "Expected out to be size $(expected_size), found $(size(out))"
                    throw(DimensionMismatch(msg))
                end
            end
            nrow = size(V,1)
            for _row = 1:nrow
                @inbounds out[_row,:] = myfun($(Dolang.Der{0}),view(V,_row,:),p)
            end
            return out
        end
        function myfun!(out,V::$(AbstractMatrix),p)
            begin
                expected_size = Dolang._output_size(2,V)
                if size(out) != expected_size
                    msg = "Expected out to be size $(expected_size), found $(size(out))"
                    throw(DimensionMismatch(msg))
                end
            end
            nrow = size(V,1)
            for _row = 1:nrow
                @inbounds out[_row,:] = myfun($(Dolang.Der{0}),view(V,_row,:),p)
            end
            return out
        end
    end
    ))

    want_d = Dolang._filter_lines!(:(begin
        function myfun(::Dolang.TDer{0},$(Dolang.DISPATCH_ARG)::$(Int),V::$(AbstractVector),p)
            out = Dolang._allocate_out(eltype(V),2,V)
            begin
                begin
                    _u_ = Dolang._unpack_var(p,1)
                end
                begin
                    _a_m1_ = Dolang._unpack_var(V,1)
                    _a_ = Dolang._unpack_var(V,2)
                    _b_ = Dolang._unpack_var(V,3)
                    _c_ = Dolang._unpack_var(V,4)
                    _c__1_ = Dolang._unpack_var(V,5)
                    _d__1_ = Dolang._unpack_var(V,6)
                end
                begin
                    _foo_ = log(_a_) + _b_ / (_a_m1_ / (1 - _c_))
                    _bar_ = _c__1_ + _u_ * _d__1_
                    Dolang._assign_var(out,_foo_,1)
                    Dolang._assign_var(out,_bar_,2)
                end
                return out
            end
        end
        function myfun($(Dolang.DISPATCH_ARG)::$(Int),V::$(AbstractVector),p)
            out = Dolang._allocate_out(eltype(V),2,V)
            begin
                begin
                    _u_ = Dolang._unpack_var(p,1)
                end
                begin
                    _a_m1_ = Dolang._unpack_var(V,1)
                    _a_ = Dolang._unpack_var(V,2)
                    _b_ = Dolang._unpack_var(V,3)
                    _c_ = Dolang._unpack_var(V,4)
                    _c__1_ = Dolang._unpack_var(V,5)
                    _d__1_ = Dolang._unpack_var(V,6)
                end
                begin
                    _foo_ = log(_a_) + _b_ / (_a_m1_ / (1 - _c_))
                    _bar_ = _c__1_ + _u_ * _d__1_
                    Dolang._assign_var(out,_foo_,1)
                    Dolang._assign_var(out,_bar_,2)
                end
                return out
            end
        end
    end))

    want_d_vec = Dolang._filter_lines(:(begin
        function myfun(::Dolang.TDer{0},$(Dolang.DISPATCH_ARG)::$(Int),V::$(AbstractMatrix),p)
            out = Dolang._allocate_out(eltype(V),2,V)
            nrow = size(V,1)
            for _row = 1:nrow
                @inbounds out[_row,:] = myfun($(Dolang.Der{0}),$(Dolang.DISPATCH_ARG)::$(Int),view(V,_row,:),p)
            end
            return out
        end
        function myfun($(Dolang.DISPATCH_ARG)::$(Int),V::$(AbstractMatrix),p)
            out = Dolang._allocate_out(eltype(V),2,V)
            nrow = size(V,1)
            for _row = 1:nrow
                @inbounds out[_row,:] = myfun($(Dolang.Der{0}),$(Dolang.DISPATCH_ARG)::$(Int),view(V,_row,:),p)
            end
            return out
        end
    end))

    want_d! = Dolang._filter_lines!(:(begin
        function myfun!(::Dolang.TDer{0},$(Dolang.DISPATCH_ARG)::($Int),out,V::$(AbstractVector),p)
            begin
                expected_size = Dolang._output_size(2, V)
                if size(out) != expected_size
                    msg = "Expected out to be size $(expected_size), found $(size(out))"
                    throw(DimensionMismatch(msg))
                end
            end
            begin
                begin
                    _u_ = Dolang._unpack_var(p,1)
                end
                begin
                    _a_m1_ = Dolang._unpack_var(V,1)
                    _a_ = Dolang._unpack_var(V,2)
                    _b_ = Dolang._unpack_var(V,3)
                    _c_ = Dolang._unpack_var(V,4)
                    _c__1_ = Dolang._unpack_var(V,5)
                    _d__1_ = Dolang._unpack_var(V,6)
                end
                begin
                    _foo_ = log(_a_) + _b_ / (_a_m1_ / (1 - _c_))
                    _bar_ = _c__1_ + _u_ * _d__1_
                    Dolang._assign_var(out,_foo_,1)
                    Dolang._assign_var(out,_bar_,2)
                end
                return out
            end
        end
        function myfun!($(Dolang.DISPATCH_ARG)::($Int),out,V::$(AbstractVector),p)
            begin
                expected_size = Dolang._output_size(2, V)
                if size(out) != expected_size
                    msg = "Expected out to be size $(expected_size), found $(size(out))"
                    throw(DimensionMismatch(msg))
                end
            end
            begin
                begin
                    _u_ = Dolang._unpack_var(p,1)
                end
                begin
                    _a_m1_ = Dolang._unpack_var(V,1)
                    _a_ = Dolang._unpack_var(V,2)
                    _b_ = Dolang._unpack_var(V,3)
                    _c_ = Dolang._unpack_var(V,4)
                    _c__1_ = Dolang._unpack_var(V,5)
                    _d__1_ = Dolang._unpack_var(V,6)
                end
                begin
                    _foo_ = log(_a_) + _b_ / (_a_m1_ / (1 - _c_))
                    _bar_ = _c__1_ + _u_ * _d__1_
                    Dolang._assign_var(out,_foo_,1)
                    Dolang._assign_var(out,_bar_,2)
                end
                return out
            end
        end
    end))

    want_d!_vec = Dolang._filter_lines(:(begin
        function myfun!(::Dolang.TDer{0},$(Dolang.DISPATCH_ARG)::$(Int),out,V::$(AbstractMatrix),p)
            begin
                expected_size = Dolang._output_size(2,V)
                if size(out) != expected_size
                    msg = "Expected out to be size $(expected_size), found $(size(out))"
                    throw(DimensionMismatch(msg))
                end
            end
            nrow = size(V,1)
            for _row = 1:nrow
                @inbounds out[_row,:] = myfun($(Dolang.Der{0}),$(Dolang.DISPATCH_ARG)::$(Int),view(V,_row,:),p)
            end
            return out
        end
        function myfun!($(Dolang.DISPATCH_ARG)::$(Int),out,V::$(AbstractMatrix),p)
            begin
                expected_size = Dolang._output_size(2,V)
                if size(out) != expected_size
                    msg = "Expected out to be size $(expected_size), found $(size(out))"
                    throw(DimensionMismatch(msg))
                end
            end
            nrow = size(V,1)
            for _row = 1:nrow
                @inbounds out[_row,:] = myfun($(Dolang.Der{0}),$(Dolang.DISPATCH_ARG)::$(Int),view(V,_row,:),p)
            end
            return out
        end
    end))


    @testset "  _build_function!?" begin
        @test want == Dolang.build_function(ff, Der{0})
        @test want! == Dolang.build_function!(ff, Der{0})
        @test want_d == Dolang.build_function(ffd, Der{0})
        @test want_d! == Dolang.build_function!(ffd, Der{0})

        @test want_vec == Dolang.build_vectorized_function(ff, Der{0})
        @test want!_vec == Dolang.build_vectorized_function!(ff, Der{0})
        @test want_d_vec == Dolang.build_vectorized_function(ffd, Der{0})
        @test want_d!_vec == Dolang.build_vectorized_function!(ffd, Der{0})
    end

    @testset "  make_method" begin
        @test make_method(ff) == Expr(:block, want!, want!_vec, want, want_vec)
        @test make_method(ff; mutating=false) == Expr(:block, want, want_vec)
        @test make_method(ff; allocating=false) == Expr(:block, want!, want!_vec)

        # test version where you pass args and it makes ff for you
        have1 = make_method(eqs, args, params, targets=targets, defs=defs,
                            funname=funname)
        have2 = make_method(eqs, args, params, targets=targets, defs=defs,
                            funname=funname, mutating=false)
        have3 = make_method(eqs, args, params, targets=targets, defs=defs,
                            funname=funname, allocating=false)

        @test have1 == Expr(:block, want!, want!_vec, want, want_vec)
        @test have2 == Expr(:block, want, want_vec)
        @test have3 == Expr(:block, want!, want!_vec)

        # now dispatch version
        @test make_method(ffd) == Expr(:block, want_d!, want_d!_vec , want_d, want_d_vec)
        @test make_method(ffd; mutating=false) == Expr(:block, want_d, want_d_vec)
        @test make_method(ffd; allocating=false) == Expr(:block, want_d!, want_d!_vec)

        # # test version where you pass args and it makes ffd for you
        have1 = make_method(Int, eqs, args, params, targets=targets, defs=defs,
                            funname=funname)
        have2 = make_method(Int, eqs, args, params, targets=targets, defs=defs,
                            funname=funname, mutating=false)
        have3 = make_method(Int, eqs, args, params, targets=targets, defs=defs,
                            funname=funname, allocating=false)

        @test have1 == Expr(:block, want_d!, want_d!_vec, want_d, want_d_vec)
        @test have2 == Expr(:block, want_d, want_d_vec)
        @test have3 == Expr(:block, want_d!, want_d!_vec)
    end

    @testset " evaluating compiled code" begin
        eval(current_module(), Dolang.make_method(ff, orders=[0,1]))
        u = rand()
        V = rand(6)+4
        am, a, b, c, cp, dp = V
        p = [u]

        want = [log(a) + b/(am / (1-c)), cp + u*dp]
        out = similar(want)

        # test scalar, allocating version
        @test want ≈ @inferred myfun(V, p)
        @test want ≈ @inferred myfun(Dolang.Der{0}, V, p)

        # test scalar, mutating version
        myfun!(out, V, p)
        @test want ≈ out

        myfun!(Dolang.Der{0}, out, V, p)
        @test want ≈ out

        # test vectorized version
        Vmat = repmat(V', 40, 1)
        @test maximum(abs, want' .- myfun(Vmat, p)) < 1e-15
        @test maximum(abs, want' .- myfun(Dolang.Der{0}, Vmat, p)) < 1e-15

        # test vectorized mutating version
        out_mat = Array{Float64}(40, 2)
        myfun!(out_mat, Vmat, p)
        @test maximum(abs, want' .- out_mat) < 1e-15

        myfun!(Dolang.Der{0}, out_mat, Vmat, p)
        @test maximum(abs, want' .- out_mat) < 1e-15

        ## Now test derivative code!
        want = zeros(Float64, 2, 6)
        want[1, 1] = -1 * b *(1-c)/ (am*am)  # ∂foo/∂am
        want[1, 2] = 1/a  # ∂foo/∂a
        want[1, 3] = (1-c) / (am)  # ∂foo/∂b
        want[1, 4] = -b/am  # ∂foo/∂b
        want[2, 5] = 1.0  # ∂bar/∂cp
        want[2, 6] = u # # ∂bar/∂dp

        # allocating version
        @test want ≈ @inferred myfun(Der{1}, V, p)

        # non-alocating version
        out2 = similar(want)
        myfun!(Der{1}, out2, V, p)
        @test want ≈ out2

    end
end

@testset "derivative code runs" begin
    @test (Dolang.build_function(ff, Der{1}); true)
    @test (Dolang.build_function(ff, Der{2}); true)
end  # @testset "derivative code runs"

@testset "issue #14" begin
    eqs = Expr[:(1+a-a)]
    ss_args = Tuple{Symbol,Int64}[(:a,0)]
    p_args = Symbol[:q]

    # just make sure this runs
    Dolang.make_method(eqs, ss_args, p_args, funname=:f_s, orders=[0, 1])
end


end  # @testset "compiler"
