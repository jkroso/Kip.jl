# Exports names, and sets `ready` in __init__
@use "./a" greet
export ready, shout
const ready = Ref(false)
__init__() = (ready[] = true)
shout(who) = uppercase(greet(who))
