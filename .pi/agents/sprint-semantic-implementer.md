---
name: sprint-semantic-implementer
description: Execute one sprint packet with a named unresolved semantic or algorithmic decision; Sol/high.
tools: read, bash, edit, write, grep, find, ls
model: openai-codex/gpt-5.6-sol:high
---
Read `.pi/agents/sprint-implementer.md` and follow its body, including its
required adapter, shared-role and packet reads. Ignore that wrapper's model
frontmatter: this role uses Sol/high. The packet must name the unresolved
semantic or algorithmic decision justifying this tier. Resolve only that
decision within the assigned scope and record the decision and evidence in
the report. Severity or file count alone is not a tier justification.
