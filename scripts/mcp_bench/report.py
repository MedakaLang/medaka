"""Aggregate run records without retaining transcripts."""
from collections import Counter
import hashlib
import json
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


def compact_measurements(raw, provenance):
    """Allowlist public observations; never copy response payloads or host paths."""
    samples = []
    for sample in raw['samples']:
        responses = []
        for response in sample['responses']:
            encoded = json.dumps(response, sort_keys=True, separators=(',', ':')).encode()
            result = response.get('result')
            responses.append({'id': response['id'], 'sha256': hashlib.sha256(encoded).hexdigest(),
                              'protocol_error': 'error' in response,
                              'tool_error': result.get('isError', False) if isinstance(result, dict) else False})
        samples.append({'record': sample['record'], 'exchanges': sample['exchanges'],
                        'resources': sample['resources'], 'responses': responses})
    return {'schema_version': 1, 'provenance': provenance, 'samples': samples}


def measurement_summary(document):
    """All retained samples contribute; paired deltas are signed and include noise."""
    samples = document['samples']
    pairs, query, first, cpu, memory = {}, [], [], [], []
    for sample in samples:
        record = sample['record']
        if record['outcome'] != 'success':
            continue
        exchanges = sample['exchanges']
        first.append(exchanges[0]['received_ns'])
        for exchange in exchanges[1:]:
            query.append(exchange['round_trip_ns'])
            key = (record['run_id'], exchange['id'])
            pair = pairs.setdefault(key, {})
            if record['arm'] in pair:
                raise ValueError('duplicate paired sample')
            pair[record['arm']] = exchange['round_trip_ns']
        resource = sample['resources'][0]
        cpu.append(resource['cpu_ns'])
        memory.append(resource['peak_memory_charge_bytes'])
    if any(set(pair) != {'trace-off', 'trace-on'} for pair in pairs.values()):
        raise ValueError('missing paired arm')
    deltas = [pair['trace-on'] - pair['trace-off'] for pair in pairs.values()]
    def bounds(values):
        if not values or any(type(value) is not int for value in values):
            raise ValueError('missing measurement')
        return {'samples': len(values), 'min': min(values), 'max': max(values)}
    return {'outcomes': dict(Counter(s['record']['outcome'] for s in samples)),
            'query_round_trip_ns': bounds(query), 'collector_first_response_ns': bounds(first),
            'paired_trace_delta_ns': bounds(deltas),
            'paired_absolute_trace_delta_ns': bounds([abs(value) for value in deltas]),
            'session_cpu_ns': bounds(cpu), 'peak_memory_charge_bytes': bounds(memory)}


if __name__ == '__main__':
    import argparse
    from pathlib import Path
    parser = argparse.ArgumentParser()
    parser.add_argument('--interactive-raw', required=True)
    parser.add_argument('--provenance', required=True)
    parser.add_argument('--pilot', required=True)
    parser.add_argument('--output', required=True)
    options = parser.parse_args()
    raw = Path(options.interactive_raw).read_bytes()
    provenance = json.loads(Path(options.provenance).read_text())
    provenance['raw_sha256'] = hashlib.sha256(raw).hexdigest()
    document = compact_measurements(json.loads(raw), provenance)
    document['summary'] = measurement_summary(document)
    pilot = Path(options.pilot).read_bytes()
    document['context_proxy'] = {
        'metric': 'host-accounted cumulative input tokens; proxy for context cost, not occupancy',
        'source_sha256': hashlib.sha256(pilot).hexdigest(),
        'rows': [{'index': row['index'], 'task': row['task'], 'arm': row['arm'],
                  'input_tokens': row['usage']['inputTokens'], 'host_evidence_ref': row['host_evidence_ref']}
                 for row in json.loads(pilot)['rows']]}
    with open(options.output, 'x', encoding='utf-8') as stream:
        json.dump(document, stream, indent=2)
        stream.write('\n')
