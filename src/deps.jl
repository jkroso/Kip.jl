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
  best_i = 0
  i = 0
  for v in enumerable
    i += 1
    if ismatch(q, v) && v > best_v
      best_v = v
      best_i = i
    end
  end
  return best_v, best_i
end

##
# coiljl/URI
#
const control = (map(UInt8, 0:parse(Int,"1f",16)) |> collect |> String) * "\x7f"
const blacklist = Set("<>\",;+\$![]'* {}|\\^`" * control)

encode_match(substr) = string('%', uppercase(hex(substr[1], 2)))

"""
Hex encode characters which might be dangerous in certain contexts without
obfuscating it so much that it loses its structure as a uri string
"""
encode(str::AbstractString) = replace(str, blacklist, encode_match)
