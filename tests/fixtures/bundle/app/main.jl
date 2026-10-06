# The entry script for the bundle tests. It uses each form of @use.
using Kip
@use "../lib/a" greet Point here part
@use "../lib/a" greet => hello
@use "../lib/a" => A
@use "../lib/b"...
@use "../lib/c" exports...
@use "../lib/m" @twice
@use "../lib" ["utils" which => which1] ["sub/utils" which => which2]
@use Dates: Date

function (@main)(args)
  println(greet("bundle"))
  println(hello("again"))
  println(Point(1, 2).y)
  println(A.greet === greet)
  println(shout("loud"))
  println(ready[])
  println(cname())
  println(@twice 21)
  println(which1(), " ", which2())
  println(Date(2026, 10, 6))
  println(here, " ", part)
  println(join(args, ","))
  # Not compared with Kip: a bundle never loads Kip or LibGit2
  println(stderr, "LibGit2 loaded: ", any(k -> k.name == "LibGit2", keys(Base.loaded_modules)))
  return 3
end
