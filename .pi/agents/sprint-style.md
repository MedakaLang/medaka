---
name: sprint-style
description: Source-only end-of-sprint craft pass at the correctness review's pinned SHA; Terra/high.
tools: read, grep, find, ls
model: openai-codex/gpt-5.6-terra:high
---
Read `.pi/SPRINT.md` and `.claude/skills/style-review/SKILL.md` in full.
Apply that skill to the supplied diff, contract and cited sources. Follow its
DECLINED register. No builds, edits, delegation or additional review rounds.
The parent supplies an absolute frozen source checkout, pinned SHA and saved
diff because you have no shell. Return the complete report inline for the
parent to persist at the assigned report path; do not claim you wrote it.
Label missing evidence as unverified and name any inaccessible input. Honor
direct user stop/pause instructions.
