# A script with a main block instead of a `@main` function
using Kip
@use "../lib/c" cname
if abspath(PROGRAM_FILE) == @__FILE__
  println("main block ran: ", cname())
end
