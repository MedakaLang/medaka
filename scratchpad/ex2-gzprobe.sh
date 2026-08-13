#!/bin/sh
# Does `gzip -9 -c <file>` embed the file mtime (making the .gz non-reproducible
# for identical content)? Derive it rather than assert it.
cd /root/medaka/.claude/worktrees/giggly-tinkering-rainbow/scratchpad || exit 1
printf 'identical content\n' > gzp.bin
touch -t 202601010000 gzp.bin; gzip -9 -c gzp.bin > gzp.a.gz
touch -t 202602020000 gzp.bin; gzip -9 -c gzp.bin > gzp.b.gz
echo "content md5s (must match):"; md5sum gzp.bin
echo "gz md5s:"; md5sum gzp.a.gz gzp.b.gz
echo "header bytes 5-8 (MTIME field, LE):"
od -An -tx1 -N8 gzp.a.gz
od -An -tx1 -N8 gzp.b.gz
cmp gzp.a.gz gzp.b.gz && echo "SAME gz" || echo "DIFFERENT gz for identical content => mtime is in the header"
rm -f gzp.bin gzp.a.gz gzp.b.gz
