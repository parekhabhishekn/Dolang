@testset "factory" begin

const flat_args = [(:a, 0), (:b, 1), (:c, -1)]
const grouped_args = Dict(:x=>[(:a, 0), (:c, -1)], :y=>[(:b, 1)])
const flat_params = [:beta, :delta]
const grouped_params = Dict(:p => [:beta, :delta])

@testset " convert Grouped" begin
    @test sort(Dolang.FlatArgs(grouped_args), by=_->_[1]) == flat_args
    @test sort(Dolang.FlatParams(grouped_params)) == flat_params
end

@testset " allowed_dates" begin
    out = OrderedDict()
    Dolang.allowed_dates!(flat_args, out)
    @test out == OrderedDict(:a=>Set(0), :b=>Set(1), :c=>Set(-1))

    @test out == Dolang.allowed_dates(flat_args)
    @test out == Dolang.allowed_dates(grouped_args)
end

@testset " param_names" begin
    @test Dolang.param_names(flat_params) == flat_params
    @test Dolang.param_names(grouped_params) == flat_params
end

@testset " is_time_shift" begin
    @test Dolang.is_time_shift(:(sin(1)))
    @test Dolang.is_time_shift(:(x(2)))
    @test !Dolang.is_time_shift(:(a(b)))
    @test !Dolang.is_time_shift(:(a(1.0)))
    @test Dolang.is_time_shift(:(a(1)))
end

@testset " IncidenceTable" begin
    ex1 = :(foo = bing + bong)
    ex2 = :(cowboy = yee - haw! + foo)
    ex3 = :(x = foo(-3) + bing(1))
    exs = [ex1, ex2, ex3]

    # visiting symbols
    it = Dolang.IncidenceTable()
    Dolang.visit!(it, :x, 1, 0)
    want_eq = OrderedDict(1=>Dict(:x=>Set(0)))
    @test want_eq == it.by_eq
    @test Dict(:x=>Set(0)) == it.by_var

    Dolang.visit!(it, :x, 1, 1)
    want_eq[1][:x] = Set([0, 1])
    @test want_eq == it.by_eq
    @test Dict(:x=>Set([0, 1])) == it.by_var

    Dolang.visit!(it, :x, 2, 3)
    want_eq[1][:x] = Set([0, 1])
    want_eq[2] = Dict(:x=>Set(3))
    @test want_eq == it.by_eq
    @test Dict(:x=>Set([0, 1, 3])) == it.by_var

    Dolang.visit!(it, :y, 1, -1)
    want_eq[1][:y] = Set([-1])
    @test want_eq == it.by_eq
    @test Dict(:x=>Set([0, 1, 3]), :y=>Set([-1])) == it.by_var

    # visiting numbers shouldn't change anything
    for i in 1:100
        Dolang.visit!(it, i, 1, 1)
    end
    @test want_eq == it.by_eq
    @test Dict(:x=>Set([0, 1, 3]), :y=>Set([-1])) == it.by_var

    # reset `it` before working on expressions
    it = Dolang.IncidenceTable()
    want_eq = deepcopy(it.by_eq)
    want_bv = deepcopy(it.by_var)

    s0 = Set(0)
    Dolang.visit!(it, ex1, 1, 0)
    want_eq[1] = Dict(:foo=>s0, :bing=>s0, :bong=>s0)
    want_bv = deepcopy(want_eq[1])
    @test want_eq == it.by_eq
    @test want_bv == it.by_var

    Dolang.visit!(it, ex2, 2, 0)
    want_eq[2] = Dict(:cowboy=>s0, :yee=>s0, :haw! =>s0, :foo=>s0)
    # want_bv[:cowboy] =s0; want_bv[:yee] = s0; want_bv[:haw!] =s0
    merge!(want_bv, want_eq[2])
    @test want_eq == it.by_eq
    @test want_bv == it.by_var

    Dolang.visit!(it, ex3, 3, 0)
    want_eq[3] = Dict(:x=>s0, :foo=>Set([-3]), :bing=>Set(1))
    want_bv[:x] = s0
    want_bv[:foo] = Set([-3, 0])
    want_bv[:bing] = Set([0, 1])
    @test want_eq == it.by_eq
    @test want_bv == it.by_var

    Dolang.visit!(it, ex3, 4, 1)
    want_eq[4] = Dict(:x=>Set(1), :foo=>Set([-2]), :bing=>Set(2))
    want_bv[:x] = Set([0, 1])
    want_bv[:foo] = Set([-3, -2, 0])
    want_bv[:bing] = Set([0, 1, 2])
    @test want_eq == it.by_eq
    @test want_bv == it.by_var

    # using expressions
    it1 = Dolang.IncidenceTable(ex1)
    want = OrderedDict(1=>Dict(:foo=>Set(0), :bing=>Set(0),
                               :bong=>Set(0)))
    @test it1.by_eq == want

    want = Dict(:foo=>Set(0), :bing=>Set(0), :bong=>Set(0))
    @test it1.by_var == want

    # getindex
    @test it[1] == it.by_date[1]
    @test it[:foo] == it.by_var[:foo]
end

@testset " Function Factory" begin
    # TODO: test grouped argument style

    eqs = [:(foo = log(a)+b/x(-1)), :(bar = c(1)+u*d(1))]
    args = [(:a, -1), (:a, 0), (:b, 0), (:c, 0), (:c, 1), (:d, 1)]
    params = [:u]
    defs = Dict(:x=>:(a/(1-c(1))))
    targets = [:foo, :bar]
    funname = :myfun
    _FF = Dolang.FunctionFactory

    @testset "  constructors" begin
        # inner constructor directly
        ff1 = _FF{Dolang.FlatArgs,
                  Dolang.FlatParams,
                  Dict{Symbol,Expr},
                  DataType}(eqs, args, params, targets, defs, funname,
                            Dolang.SkipArg)

        # First outer constructor
        ff2 = _FF(eqs, args, params, targets, defs, funname, Dolang.SkipArg)

        # kwarg outer constructor -- SkipArg default
        ff3 = _FF(eqs, args, params, targets=targets, defs=defs,
                  funname=funname)

        ff4 = _FF(Dolang.SkipArg, eqs, args, params, targets=targets,
                  defs=defs, funname=funname)

        @test ff2 == ff1
        @test ff3 == ff1
        @test ff4 == ff1
    end

    @testset "  constructor behavior" begin
        _FF = _FF
        ff = _FF(eqs, args, params, targets=targets, defs=defs, funname=funname)

        # test that equations were normalized properly
        norm_eq1 = :(_foo_ = log(_a_) + _b_ / (_a_m1_ / (1 - _c_)))
        norm_eq2 = :(_bar_ = _c__1_ + _u_ * _d__1_)
        norm_eq = [norm_eq1, norm_eq2]
        @test ff.eqs == norm_eq

        # test that Exceptions are thrown for bad defs
        bad_defs = Dict(:x=> :(a(2)/(1-c(1))))
        @test_throws(Dolang.DefinitionNotAllowedError,
                     _FF(eqs, args, params, targets=targets, defs=bad_defs,
                         funname=funname))

        # make sure content of the Exception is correct
        ex = try
            _FF(eqs, args, params, targets=targets, defs=bad_defs)
           catch e
               e
           end

        @test ex.var == :x
        @test ex.def == :(a(2)/(1-c(1)))
        @test ex.shift == -1

        # test that excecptions are thrown for variables appearing at the
        # wrong time in the equations
        bad_eqs = vcat(eqs, :(foo = b + a(1)))::Vector{Expr}
        @test_throws(Dolang.VariableNotAllowedError,
                     _FF(bad_eqs, args, params, targets=targets, defs=defs,
                         funname=funname))

        # check content of exception
        ex = try
            _FF(bad_eqs, args, params, targets=targets, targets=targets,
                defs=defs)
           catch e
               e
           end

        @test ex.eq == :(foo = b + a(1))
        @test ex.bad_var == :a
        @test ex.shifts == Set(1)

        # test that exceptions are thrown for unknown variables appearing
        # in the equations
        bad_eqs = vcat(eqs, :(whoami = a-b))::Vector{Expr}
        @test_throws(Dolang.UnknownSymbolError,
                     _FF(bad_eqs, args, params, targets=targets, defs=defs,
                         funname=funname))

        # check content of exception
        ex = try
            _FF(bad_eqs, args, params, targets=targets, targets=targets,
                defs=defs)
           catch e
               e
           end

        @test ex.eq == :(whoami = a-b)
        @test ex.bad_var == :whoami
        @test ex.shifts == Set{Int}()

    end

    @testset " issue #18 (expand definitions in ff.incidence.by_eq)" begin
        ff = _FF(eqs, args, params, targets=targets, defs=defs, funname=funname)

        @test haskey(ff.incidence.by_eq[1], :a)
        @test haskey(ff.incidence.by_eq[1], :c)
        @test ff.incidence.by_eq[1][:a] == Set([-1, 0])
        @test ff.incidence.by_eq[1][:c] == Set([0])

    end

end

end  # @testset "factory"
