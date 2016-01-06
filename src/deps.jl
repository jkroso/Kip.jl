##
# To avoid a circular dependencies I've copy and pasted all 3rd party
# code into this file
#
# jkroso/SemverQuery.jl
#

const semver_regex = r"^
  ([<>]=?)?    # operator (optional)
  v?           # prefix   (optional)
  (\d{1,4})    # major    (required)
  (?:\.(\d+))? # minor    (optional)
  (?:\.(\d+))? # patch    (optional)
$"x

abstract VersionQuery

immutable VersionRestriction{operator} <: VersionQuery
  value::VersionNumber
end

toInt(s::AbstractString) = parse(Int, s)
toInt(n::Number) = round(Int, n)

immutable VersionGlob <: VersionQuery
  major::Int
  minor::Int
  patch::Int
  VersionGlob(a,b,c) = begin
    a ≡ nothing && return new(-1,-1,-1)
    b ≡ nothing && return new(toInt(a),-1,-1)
    c ≡ nothing && return new(toInt(a),toInt(b),-1)
    return new(toInt(a),toInt(b),toInt(c))
  end
end

immutable Conjunction <: VersionQuery
  queries::Tuple{Vararg{VersionQuery}}
end

##
# Parse a SemverQuery from a string
#
function semver_query(s::AbstractString)
  s == "*" && return VersionGlob(-1,-1,-1)
  queries = map(eachmatch(semver_regex, s)) do match
    op,major,minor,patch = match.captures
    op ≡ nothing && return VersionGlob(major,minor,patch)
    version = convert(VersionNumber, match.match[length(op) + 1:end])
    VersionRestriction{symbol(op)}(version)
  end
  @assert !isempty(queries) "\"$s\" is not a valid semver query"
  length(queries) > 1 ? Conjunction(tuple(queries...)) : queries[1]
end

##
# Test if a version satisfies a SemverQuery
#
Base.ismatch(q::VersionRestriction{:<}, v::VersionNumber) = v < q.value
Base.ismatch(q::VersionRestriction{:>}, v::VersionNumber) = v > q.value
Base.ismatch(q::VersionRestriction{:>=}, v::VersionNumber) = v >= q.value
Base.ismatch(q::VersionRestriction{:<=}, v::VersionNumber) = v <= q.value

Base.ismatch(q::VersionGlob, v::VersionNumber) = begin
  q.patch ≡ -1 || q.patch ≡ v.patch || return false
  q.minor ≡ -1 || q.minor ≡ v.minor || return false
  q.major ≡ -1 || q.major ≡ v.major || return false
  return true
end

Base.ismatch(q::Conjunction, v::VersionNumber) = all(q-> ismatch(q, v), q.queries)

##
# Find the best match from a collection of versions
#
Base.findmax(q::VersionQuery, enumerable) = begin
  best_v = typemin(VersionNumber)
  for v in enumerable
    if ismatch(q, v) && v > best_v
      best_v = v
    end
  end
  return best_v
end


##
# jkroso/prospects.jl
#

const undefined = Dict()

##
# An unsafe get
#
function getKey(a, key)
  a = get(a, key, undefined)
  a ≡ undefined && error("can't get property: $key")
  return a
end

get_in(a, path) = foldl(getKey, a, path)
