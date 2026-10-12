#!/bin/sh
# compare.sh PLAIN_OUT INST_OUT PLAIN_RC INST_RC -- the census validity check.
# Prints "instrumented-vs-plain stdout comparison = VALID" only when both runs
# exited 0, the plain stdout is non-empty, and the two stdouts are byte
# identical; "... = INVALID" otherwise (two runs that fail the same way agree
# on nothing). Always exits 0.
plain=${1:?plain output file}
inst=${2:?instrumented output file}
prc=${3:?plain exit code}
irc=${4:?instrumented exit code}
if [ "$prc" = 0 ] && [ "$irc" = 0 ] && [ -s "$plain" ] && cmp -s "$plain" "$inst"; then
  echo "instrumented-vs-plain stdout comparison = VALID"
else
  echo "instrumented-vs-plain stdout comparison = INVALID (census numbers are not trustworthy; plain rc=$prc, instrumented rc=$irc)"
fi
exit 0
