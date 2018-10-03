const UNION    = 0b00000000 % Int8
const MISSING  = 0b10000000 % Int8
const INT      = 0b00000001 % Int8
const FLOAT    = 0b00000010 % Int8
const DATE     = 0b00000100 % Int8
const DATETIME = 0b00001000 % Int8
const BOOL     = 0b00010000 % Int8
const STRING   = 0b00100000 % Int8
const USER     = 0b01111111 % Int8

typecode(::Missing) = MISSING
typecode(::Int64) = INT
typecode(::Float64) = FLOAT
typecode(::Date) = DATE
typecode(::DateTime) = DATETIME
typecode(::Bool) = BOOL
typecode(::String) = STRING
typecode(::Tuple{Ptr{UInt8}, Int}) = STRING
typecode(::Type{Union{}}) = UNION
typecode(::Type{Missing}) = MISSING
typecode(x) = USER

const TYPEMAP = Dict(
    UNION    => Union{},
    MISSING  => Missing,
    INT      => Int64,
    FLOAT    => Float64,
    DATE     => Date,
    DATETIME => DateTime,
    BOOL     => Bool,
    STRING   => String,
    (INT | MISSING)      => Union{Int64, Missing},
    (FLOAT | MISSING)    => Union{Float64, Missing},
    (DATE | MISSING)     => Union{Date, Missing},
    (DATETIME | MISSING) => Union{DateTime, Missing},
    (BOOL | MISSING)     => Union{Bool, Missing},
    (STRING | MISSING)   => Union{String, Missing},
)

# initialization case
@inline function promote_typecode(T, S)
    if T === UNION || T === S
        return S
    elseif T === MISSING || S === MISSING
        return T | S
    elseif T === INT
        return S === FLOAT ? FLOAT : STRING
    elseif T === FLOAT
        return S === INT ? FLOAT : STRING
    elseif T === DATE
        return S === DATETIME ? DATETIME : STRING
    elseif T === DATETIME
        return S === DATE ? DATETIME : STRING
    elseif T === STRING
        return STRING
    else
        return S === STRING ? (STRING | MISSING) : (promote_typecode(T & ~MISSING, S) | MISSING)
    end
end

# providedtypes: Dict{String, Type}, Dict{Int, Type}, Vector{Type}
initialtype(allowmissing) = (allowmissing === :auto || allowmissing === :none) ? Union{} : Missing
initialtypes(T, ::Nothing, names) = Type[T for _ = 1:length(names)]
initialtypes(T, t::Dict{String, V}, names) where {V} = Type[get(t, string(nm), T) for nm in names]
initialtypes(T, t::Dict{Symbol, V}, names) where {V} = Type[get(t, nm, T) for nm in names]
initialtypes(T, t::Dict{Int, V}, names) where {V}    = Type[get(t, i, T) for i = 1:length(names)]

struct Fib{N}
    len::Int
end
Fib(len) = Fib{1024}(len)

@inline function Base.iterate(f::Fib)
    f.len == 0 && return nothing
    return 1, (1, 1, 1, 1)
end

@inline function Base.iterate(f::Fib{N}, (off, len, prevfib, fib)) where {N}
    (off + fib) > f.len && return nothing
    if rem(len, N) == 0
        prevfib, fib = fib, prevfib + fib
    end
    return off + fib, (off + fib, len + 1, prevfib, fib)
end

const EMPTY_LEVELS = Set{String}[]
const EMPTY_POOLS = CategoricalPool{String, UInt32, CatStr}[]

function detect(types, io, positions, parsinglayers, kwargs, typemap, categorical, transpose, ref, debug)
    len = transpose ? ref[] : length(positions)
    cols = length(types)
    typecodes = [typecode(T) for T in types]
    # @show typecodes

    # prep if categorical
    levels = categorical ? Set{String}[Set{String}() for _ = 1:cols] : EMPTY_LEVELS

    lastcode = Base.RefValue(Parsers.SUCCESS)
    rows = 0
    for row in Fib(len)
        rows += 1
        !transpose && seek(io, positions[row])
        lastcode[] = Parsers.SUCCESS
        for col = 1:cols
            if !transpose && newline(lastcode[])
                typecodes[col] = promote_typecode(typecodes[col], MISSING)
                continue
            end
            transpose && seek(io, positions[col])
            # if debug
            #     pos = position(io)
            #     result = Parsers.parse(parsinglayers, io, String)
            #     seek(io, pos)
            # end
            @inbounds T = typecodes[col]
            if T === USER
                detecttype(STRING, io, parsinglayers, kwargs, levels, row, col, categorical, lastcode)
            else
                S = detecttype(T & ~MISSING, io, parsinglayers, kwargs, levels, row, col, categorical, lastcode)
                typecodes[col] = promote_typecode(T, S)
                debug && (T !== typecodes[col]) && println("row: $row, col: $col, '$(result.result)', promoted to: $(TYPEMAP[typecodes[col]])")
            end
            transpose && setindex!(positions, position(io), col)
        end
    end
    debug && println("scanned $rows / $len = $((rows / len) * 100)% of file to infer types")

    pools = categorical ? Vector{CategoricalPool{String, UInt32, CatStr}}(undef, cols) : EMPTY_POOLS
    for (i, T) in enumerate(typecodes)
        if T < USER
            @inbounds S = TYPEMAP[T]
            if categorical && (T & STRING) > 0
                S = T < 0 ? Union{CatStr, Missing} : CatStr
                pools[i] = CategoricalPool{String, UInt32}(collect(levels[i]))
            end
            @inbounds types[i] = get(typemap, S, S)
        end
    end
    return types, pools
end

@inline function trytype(io, pos, layers, T, kwargs, lastcode)
    seek(io, pos)
    res = Parsers.parse(layers, io, T; kwargs...)
    lastcode[] = res.code
    return Parsers.ok(res.code) ? typecode(res.result) : UNION
end

function detecttype(prevT, io, layers, kwargs, levels, row, col, categorical, lastcode)
    pos = position(io)
    if categorical
        result = Parsers.parse(layers, io, Tuple{Ptr{UInt8}, Int})
        Parsers.ok(result.code) || throw(Error(Parsers.Error(io, result), row, col))
        lastcode[] = result.code
        # @debug "res = $result"
        result.result === missing && return MISSING
        # update levels
        s = result.result::Tuple{Ptr{UInt8}, Int}
        lev = levels[col]
        (s in lev) || push!(lev, unsafe_string(s[1], s[2]))
    end
    if prevT === UNION || prevT === INT
        int = trytype(io, pos, layers, Int64, kwargs, lastcode)
        int !== UNION && return int
    end
    if prevT === UNION || prevT === INT || prevT === FLOAT
        float = trytype(io, pos, layers, Float64, kwargs, lastcode)
        float !== UNION && return float
    end
    if prevT === UNION || prevT === DATE || prevT === DATETIME
        if !haskey(kwargs, :dateformat)
            try
                date = trytype(io, pos, layers, Date, kwargs, lastcode)
                date !== UNION && return date
            catch e
            end
            try
                datetime = trytype(io, pos, layers, DateTime, kwargs, lastcode)
                datetime !== UNION && return datetime
            catch e
            end
        else
            # use user-provided dateformat
            T = timetype(kwargs.dateformat)
            dt = trytype(io, pos, layers, T, kwargs, lastcode)
            dt !== UNION && return dt
        end
    end
    if prevT === UNION || prevT === BOOL
        bool = trytype(io, pos, layers, Bool, kwargs, lastcode)
        bool !== UNION && return bool
    end
    str = trytype(io, pos, layers, Tuple{Ptr{UInt8}, Int}, kwargs, lastcode)
    return str === MISSING ? MISSING : STRING
end

function timetype(df::Dates.DateFormat)
    date = false
    time = false
    for token in df.tokens
        T = typeof(token)
        if T == Dates.DatePart{'H'}
            time = true
        elseif T == Dates.DatePart{'y'} || T == Dates.DatePart{'Y'}
            date = true
        end
    end
    return ifelse(date & time, DateTime, ifelse(time, Time, Date))
end
