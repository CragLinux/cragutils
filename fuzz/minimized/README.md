# Minimized fuzz reproducers

`sedcompile-timeout-min` (1290 bytes) is the minimized form of
`timeout-f02e889b4e745065fc0a7bfe8ea94930328ce988`, the sedcompile
campaign's one timeout artifact.  It is NOT a bug: a chain of `s///`
commands whose replacements plant matches for the next legitimately
amplifies one input character `o` to ~96 MB of output (GNU sed 4.9
does the same on the equivalent canonical script).  See the
"ANALYZED, not ours — sed s///g output amplification" entry in
SECURITY-FINDINGS.md for the full verdict and measurements.

Kept out of `fuzz/corpus/` on purpose: any run of it takes tens of
seconds (that is the finding), which would fail the `-timeout=25`
campaign replay and the 15 s corpus suite.  The live copy for triage
purposes is `fuzz/artifacts/slow-unit-f02e889b…` (gitignored).
