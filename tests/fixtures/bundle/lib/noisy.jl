# Says when its __init__ runs, so a test can see when it starts
__init__() = println("noisy started")
noisy_value() = "noisy"
