#!/bin/sh
# compare.sh PLAIN_OUT INST_OUT -- the census validity check. Prints
# "instrumented-vs-plain stdout comparison = VALID" when the two files are byte
# identical and "... = INVALID" otherwise. Always exits 0.
plain=${1:?plain output file}
inst=${2:?instrumented output file}
if cmp -s "$plain" "$inst"; then
  echo "instrumented-vs-plain stdout comparison = VALID"
else
  echo "instrumented-vs-plain stdout comparison = INVALID (census numbers are not trustworthy)"
fi
exit 0
