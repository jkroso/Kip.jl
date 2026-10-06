# A plain file: a struct, a function, and a file it includes
include("a_part.jl")
struct Point
  x::Int
  y::Int
end
greet(who) = "hello $who"
const here = basename(@dirname)
