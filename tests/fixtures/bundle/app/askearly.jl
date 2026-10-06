# Uses a file that calls its own include function as it loads
using Kip
@use "../lib/early" early_value
println(early_value())
