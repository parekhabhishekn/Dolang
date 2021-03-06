@testset "symbolic" begin

@testset "Dolang.eq_expr" begin
    ex = :(z = x + y(1))
    @test Dolang.eq_expr(ex) == :(_x_ + _y__1_ - _z_)
    @test Dolang.eq_expr(ex, [:z]) == :(_z_ = _x_ + _y__1_)
end

@testset "Dolang.normalize" begin
    @testset "Dolang.normalize(::Union{Symbol,String}, Integer)" begin
        @test Dolang.normalize(:x, 0) == :_x_
        @test Dolang.normalize(:x, 1) == :_x__1_
        @test Dolang.normalize(:x, -1) == :_x_m1_
        @test Dolang.normalize(:x, -100) == :_x_m100_

        @test Dolang.normalize("x", 0) == :_x_
        @test Dolang.normalize("x", 1) == :_x__1_
        @test Dolang.normalize("x", -1) == :_x_m1_
        @test Dolang.normalize("x", -100) == :_x_m100_

        @test Dolang.normalize((:x, 0)) == :_x_
        @test Dolang.normalize((:x, 1)) == :_x__1_
        @test Dolang.normalize((:x, -1)) == :_x_m1_
        @test Dolang.normalize((:x, -100)) == :_x_m100_
    end

    @testset "numbers" begin
        for T in (Float16, Float32, Float64, Int8, Int16, Int32, Int64)
            x = rand(T)
            @test Dolang.normalize(x) == x
        end
    end

    @testset "symbols" begin
        for i=1:10
            s = gensym()
            @test Dolang.normalize(s) == Symbol("_", string(s), "_")
        end
    end

    @testset "x_(shift_Integer)" begin
        for i=1:10, T in (Int8, Int16, Int32, Int64)
            @test Dolang.normalize(string("x(", T(i), ")")) == Symbol("_x__$(i)_")
            @test Dolang.normalize(string("x(", T(-i), ")")) == Symbol("_x_m$(i)_")
        end

        # only add underscore to naems when shift is 0
        @test Dolang.normalize("x(0)") == :_x_
    end

    @testset "other function calls" begin
        @testset "one argument" begin
            @test Dolang.normalize("sin(x)") == :(sin(_x_))
            @test Dolang.normalize("sin(x(-1))") == :(sin(_x_m1_))
            @test Dolang.normalize("foobar(x(2))") == :(foobar(_x__2_))
        end

        @testset "two arguments" begin
            @test Dolang.normalize("dot(x, y(1))") == :(dot(_x_, _y__1_))
            @test Dolang.normalize("plot(x(-1), y)") == :(plot(_x_m1_, _y_))
            @test Dolang.normalize("bingbong(x(2), y)") == :(bingbong(_x__2_, _y_))
        end

        @testset "more args" begin
            for i=3:10
                ex = Expr(:call, :my_func, [:(x($j)) for j in 1:i]...)
                want = Expr(:call, :my_func, [Symbol("_x__", j, "_") for j in 1:i]...)
                @test Dolang.normalize(ex) == want
            end
        end

        @testset "arithmetic" begin
            @test Dolang.normalize(:(a(1) + b + c(2) + d(-1))) == :(((_a__1_ + _b_) + _c__2_) + _d_m1_)
            @test Dolang.normalize(:(a(1) * b * c(2) * d(-1))) == :(((_a__1_ * _b_) * _c__2_) * _d_m1_)
            @test Dolang.normalize(:(a(1) - b - c(2) - d(-1))) == :(((_a__1_ - _b_) - _c__2_) - _d_m1_)
            @test Dolang.normalize(:(a(1) ^ b)) == :(_a__1_ ^ _b_)
        end

        @testset "throws errors when unsupported" begin
            @test_throws Dolang.NormalizeError Dolang.normalize("x+y || i <= 100")
        end
    end

    @testset "Expr(:(=), ...)" begin
        @testset "without targets" begin
            @test Dolang.normalize(:(x = y)) == :(_y_ - _x_)
        end

        @testset "with targets" begin
            @test Dolang.normalize(:(x = log(y(-1))); targets=[:x]) == :(_x_ = log(_y_m1_))
            @test_throws Dolang.NormalizeError Dolang.normalize(:(x = y); targets=[:y])
        end
    end

    @testset "normalize(::Tuple{Symbol,Int})" begin
        @test Dolang.normalize((:x, 0)) == :_x_
        @test Dolang.normalize((:x, 1)) == :_x__1_
        @test Dolang.normalize((:x, -1)) == :_x_m1_
        @test Dolang.normalize((:x, -100)) == :_x_m100_
    end
end

@testset "Dolang.time_shift" begin
    defs = Dict(:a=>:(b(-1)/c))
    funcs = [:foobar]
    for shift in [-1, 0, 1]
        have = Dolang.time_shift(:(a+b(1) + c), shift, variables=[:b])
        @test have == :(a+b($(shift+1)) + c)

        # with variables
        have = Dolang.time_shift(:(a+b(1) + c), shift, variables=[:b, :c])
        @test have == :(a+b($(shift+1)) + c($shift))

        # with defs
        have = Dolang.time_shift(:(a+b(1) + c), shift, defs=defs, variables=[:b])
        @test have == :(b($(shift-1))/c + b($(shift+1)) + c)

        # with defs + variables
        have = Dolang.time_shift(:(a+b(1) + c), shift,
                                 defs=defs, variables=[:b, :c])
        @test have == :(b($(shift-1))/c($(shift)) + b($(shift+1)) + c($(shift)))

        # unknown function
        @test_throws Dolang.UnknownFunctionError Dolang.time_shift(:(a+b(1) + foobar(c)), shift)

        # with functions
        have = Dolang.time_shift(:(a+b(1) + foobar(c)), shift, functions=funcs,
                                 variables=[:b])
        @test have == :(a+b($(shift+1)) + foobar(c))

        # functions + defs
        have = Dolang.time_shift(:(a+b(1) + foobar(c)), shift, variables=[:b],
                                 defs=defs, functions=funcs)
        @test have == :(b($(shift-1))/c + b($(shift+1)) + foobar(c))

        # functions + variables
        have = Dolang.time_shift(:(a+b(1) + foobar(c)), shift, variables=[:b],
                                 variables=[:b, :c], functions=funcs)
        @test have == :(a+b($(shift+1)) + foobar(c($shift)))

        # functions + variables + defs
        have = Dolang.time_shift(:(a+b(1) + foobar(c)), shift,
                                 variables=[:b, :c], functions=funcs,
                                 defs=defs)
        want = :(b($(shift-1))/c($(shift)) + b($(shift+1)) + foobar(c($(shift))))
        @test have == want

    end
end

@testset "Dolang.steady_state" begin
    @test Dolang.steady_state(:(a+b(1) + c)) == :(a+b+c)

    # with defs
    have = Dolang.steady_state(:(a+b(1) + c), defs=Dict(:a=>:(b(-1)/c)))
    @test have == :(b/c+b+c)

    # unknown function
    @test_throws Dolang.UnknownFunctionError Dolang.steady_state(:(a+b(1)+c+foobar(c)))

    # now let function be ok
    want = Dolang.steady_state(:(a+b(1) + foobar(c)), functions=[:foobar])
    @test want == :(a+b+foobar(c))
end

@testset "Dolang.list_symbols" begin
    out = Dolang.list_symbols(:(a+b(1)+c))
    want = Set{Tuple{Symbol,Int}}(); push!(want, (:b, 1))
    @test haskey(out, :variables)
    @test out[:variables] == want
    @test haskey(out, :parameters)
    @test out[:parameters] == Set{Symbol}([:a, :c])

    out = Dolang.list_symbols(:(a+b(1)+c), variables=[:c])
    want = Set{Tuple{Symbol,Int}}(); push!(want, (:b, 1)); push!(want, (:c, 0))
    @test haskey(out, :variables)
    @test out[:variables] == want
    @test haskey(out, :parameters)
    @test out[:parameters] == Set{Symbol}([:a])

    # Unknown function
    @test_throws Dolang.UnknownFunctionError Dolang.list_symbols(:(a+b(1)+c+foobar(c)))

    # now let the function be ok
    out = Dolang.list_symbols(:(a+b(1)+c + foobar(c)), functions=[:foobar])
    want = Set{Tuple{Symbol,Int}}(); push!(want, (:b, 1))
    @test haskey(out, :variables)
    @test out[:variables] == want
    @test haskey(out, :parameters)
    @test out[:parameters] == Set{Symbol}([:a, :c])
end

@testset " csubs()" begin
    d = Dict(:monty=> :python, :run=>:faster, :eat=>:more)
    @test Dolang.csubs(:monty, d) == :python
    @test Dolang.csubs(:Monty, d) == :Monty
    @test Dolang.csubs(1.0, d) == 1.0

    want = :(python(faster + more, eats))
    @test Dolang.csubs(:(monty(run + eat, eats)), d) == want

    d = Dict(:b => :(c + d(1)))
    ex = :(a + b + b(1))
    want = :(a + (c + d(1)) + b(1))
    @test Dolang.csubs(ex, d) == want

    d = Dict((:b, 0) => :(c + d(1)))
    ex = :(a + b + b(1))
    want = :(a + (c + d(1)) + b(1))
    @test Dolang.csubs(ex, d) == want

    d = Dict((:b, 0) => :(c + d(1)), (:b, 1) => :(c(1) + d(2)))
    ex = :(a + b + b(1))
    want = :(a + (c + d(1)) + (c(1) + d(2)))
    @test Dolang.csubs(ex, d) == want

    # case where subs and csubs aren't the same
    ex = :(a + b)
    d = Dict(:b => :(c/a), :c => :(2a))
    @test Dolang.subs(ex, d) == :(a + c/a)
    @test Dolang.csubs(ex, d) == :(a + (2a)/a)

end

end  # @testset "symbolic"
