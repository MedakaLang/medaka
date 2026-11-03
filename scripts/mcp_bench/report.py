"""Aggregate run records without retaining transcripts."""
from collections import Counter
from schema import validate_run


def summarize(runs):
    records = [validate_run(run) for run in runs]
    metrics = {name: [] for name in ('wall_ns', 'cpu_ns', 'peak_rss_bytes')}
    for record in records:
        for name in metrics:
            if record['schema_version'] == 1:
                metrics[name].append({'value': None, 'scope': None, 'reason': 'not present in version 1'})
            elif name == 'wall_ns':
                metrics[name].append({'value': record[name], 'scope': 'elapsed observation', 'reason': None})
            else:
                metrics[name].append({'value': record[name], 'scope': record['resource_scope'],
                                      'reason': record['resource_reason'][name]})
    return {'runs': len(records), 'outcomes': dict(Counter(r['outcome'] for r in records)),
            **{name: sum(r[name] for r in records) for name in ('attempted', 'completed', 'passed', 'failed', 'skipped')},
            'metrics': metrics}


def load_budgets(path):
    """Load the single versioned budget document."""
    import json
    from pathlib import Path
    from schema import validate_budgets
    return validate_budgets(json.loads(Path(path).read_text()))
