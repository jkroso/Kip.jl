# Imports the filler (transitively a foreign-mutator) — must never be
# cache-loaded either, or its cached dep chain binds an unfilled seam_lib.
@use "./seam_filler"
@use "./seam_lib" SEAM
seam_value() = SEAM[]()
export seam_value
