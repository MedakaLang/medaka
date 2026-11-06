# Supervisor experiments

The Python stdlib experiment drives installed `medaka mcp` workers; its artifact
hash is inferred and matching mode is unavailable. The Medaka executable reports
its live-process capability failure. Both use an unchanged extracted distribution.
`exercise.py` accepts the extracted bundle directory and the compiled Medaka
supervisor path and the source checkout to rebuild. Python 3, the installed native runtime dependencies, and the
platform's usual process facilities are required. These are prototypes, not a
production service.

`process_contract_probe.py` replays the separate owned-process boundary spike:
native Medaka authority/policy probes and an independent C lifecycle model.
Run it after `make medaka`, with `--out` outside the checkout; the output directory
contains generated fixtures, binaries and the command transcript. It implements
no production process primitive. The [process contract](../../../docs/design/PROCESS-SUPERVISION.md)
records its measured controls, remaining VM ABI work and containment limits.

### Authority experiments

The independent `ownership_probe.py` and `stdio_authority_probe.py` require an
absolute `--root` and a fresh external `--out` directory. See the
[combined authority report](../../../docs/findings/mcp-runtime-authority/REPORT.md)
for replay requirements, measured blockers and the separate protected-host
qualification. Exit 77 means unavailable or blocked, not successful containment.
