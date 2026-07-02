# Fills a seam owned by seam_lib at top level — the canonical cross-module
# side effect that a compile cache silently discards.
@use "./seam_lib" SEAM
SEAM[] = () -> 42
