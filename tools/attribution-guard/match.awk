# Attribution matcher of the CI checks, one file for all of them: .github/workflows/attribution-*.yml
# run it from their checkout, azure-devops/ado-pr-guard.sh reads it from here and gen.py embeds it
# in the generated pipelines. (The local hooks, attribution-guard.sh, match with sed and grep.)
# The pattern is ENVIRON["ATTRIB_RE"], the first line of patterns.ere.
#   awk -v mode=selftest -f match.awk </dev/null   exit 0, or 2 when the self-test fails
#   awk -v mode=report -f match.awk FILE           print the number of each line with a hit
#   awk -v mode=strip -f match.awk FILE            print the text without those lines (and without
#                                                   the blank and --- lines they leave at the end)
# Every mode runs the self-test first and exits 2 when the pattern is empty, does not compile,
# misses a known trailer (ENVIRON["ATTRIB_CANARY"] replaces it) or matches a plain word: some awks
# treat a pattern that does not compile as one that never matches, and a check must fail, never pass.
# Zero-width and invisible characters (U+00AD, U+034F, U+180E, U+200B-U+200D, U+2060-U+2064, U+FEFF,
# written as UTF-8 bytes) are removed before matching; attribution-guard.sh removes the same list.
BEGIN {
  re = tolower(ENVIRON["ATTRIB_RE"])
  zw = "\302\255|\315\217|\341\240\216|\342\200\213|\342\200\214|\342\200\215|\342\201\240|\342\201\241|\342\201\242|\342\201\243|\342\201\244|\357\273\277"
  canary = ENVIRON["ATTRIB_CANARY"]
  if (canary == "") canary = "Co-Authored-By: Claude <noreply@anthropic.com>"
  if (re == "" || tolower(canary) !~ re || "x" ~ re) {
    print "attribution-guard: the attribution pattern is empty, does not compile or fails its self-test" > "/dev/stderr"
    failed = 1
    exit 2
  }
  if (mode == "selftest") exit 0
}
{
  sub(/\r$/, "")
  s = $0
  gsub(zw, "", s)
  hit = tolower(s) ~ re
  if (mode == "report") { if (hit) print NR; next }
  if (!hit) out[++n] = $0
}
END {
  if (failed) exit 2
  if (mode != "strip") exit
  while (n > 0 && (out[n] ~ /^[[:space:]]*$/ || out[n] ~ /^[[:space:]]*---+[[:space:]]*$/)) n--
  for (i = 1; i <= n; i++) print out[i]
}
