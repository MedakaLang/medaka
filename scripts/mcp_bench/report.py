"""Aggregate run records without retaining transcripts."""
from collections import Counter
from schema import validate_run


def summarize(runs):
    records = [validate_run(run) for run in runs]
    return {'runs': len(records), 'outcomes': dict(Counter(r['outcome'] for r in records)),
            **{name: sum(r[name] for r in records) for name in ('attempted', 'completed', 'passed', 'failed', 'skipped')}}
