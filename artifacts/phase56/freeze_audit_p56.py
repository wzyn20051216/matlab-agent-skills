#!/usr/bin/env python
"""Phase 5.6 Task 0 -- read-only freeze audit of the Phase 5.5 evidence base.

Everything here is verification, never mutation: it re-hashes the frozen
holdouts, walks the Phase 5.5 episode ledger and confirms that each recorded
transcript, prompt, result and sha256 still exists and still matches, recomputes
the isolation summary from the individual audit files instead of trusting it, and
recounts which client-resolved model each episode really used. It writes one JSON
report and touches nothing else.
"""
import hashlib
import json
import os
import subprocess
import sys

REPO = r'E:\desktop\MATLAB'
P55 = os.path.join(REPO, 'artifacts', 'phase55')
OUT_DIR = os.path.join(REPO, 'artifacts', 'phase56', 'freeze')
V3_ROOT = r'E:\desktop\MATLAB-bench-phase55-v3'
HOLDOUTS = [r'E:\desktop\MATLAB-bench-holdout-phase53',
            r'E:\desktop\MATLAB-bench-holdout-phase54']


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def git(*args):
    return subprocess.run(['git', '-C', REPO] + list(args), capture_output=True,
                          text=True, encoding='utf-8', errors='replace').stdout.strip()


R = {'schema': 'mas-phase56-freeze-audit/1', 'generatedAt': '2026-10-22', 'readOnly': True}

# 1. Git state -----------------------------------------------------------------
R['git'] = {
    'branch': git('rev-parse', '--abbrev-ref', 'HEAD'),
    'head': git('rev-parse', 'HEAD'),
    'worktreeClean': git('status', '--porcelain') == '',
    'tagsAtHead': git('tag', '--points-at', 'HEAD'),
    'existingTags': git('tag').splitlines(),
    'p55Commit': {'c052ecd': git('log', '-1', '--format=%H|%ad|%s', '--date=iso-strict', 'c052ecd'),
                  'followup': git('log', '-1', '--format=%H|%ad|%s', '--date=iso-strict', '572641c')},
    'p55Numstat': git('show', '--numstat', '--format=', 'c052ecd').count('\n') + 1,
    'phase55BlobDrift': git('diff', '--name-only', 'HEAD', '--', 'artifacts/phase55')
                        or git('status', '--porcelain', '--', 'artifacts/phase55'),
    'skillsSourceDrift': git('diff', '--name-only', 'HEAD', '--', 'skills'),
}

# 2. Baseline regression claimed by Phase 5.5 ----------------------------------
gate_json = json.load(open(os.path.join(P55, 'regression', 'final', 'phase4_all.json'), encoding='utf-8'))
R['baselineRegression'] = {
    'source': 'artifacts/phase55/regression/final/phase4_all.json (final_gate3_console.log)',
    'skillPass': gate_json['skillPass'], 'skillTotal': gate_json['skillTotal'],
    'suitesRun': gate_json['suitesRun'], 'suitesErrored': gate_json['suitesErrored'],
    'allSuitesOk': gate_json['allSuitesOk'], 'references': gate_json['references'],
    'crossdomain': gate_json['crossdomain'], 'pipeline': gate_json['pipeline'],
    'timestamp': gate_json['timestamp'], 'matlabVersion': gate_json['matlabVersion'],
    'logTail': [l for l in open(os.path.join(P55, 'regression', 'final_gate3_console.log'),
                                encoding='utf-8', errors='replace').read().replace('\x00', '').splitlines()
                if 'HEADLINE' in l or '====' in l],
    'reRunScheduled': 'Task 7 re-runs the whole gate in a fresh process after this phase edits code',
}

# 3. Frozen references ---------------------------------------------------------
prev_freeze = json.load(open(os.path.join(P55, 'freeze', 'freeze_report.json'), encoding='utf-8'))
recorded = {h['file']: h for h in prev_freeze['holdouts']}
rows = []
for root in HOLDOUTS:
    for name in sorted(os.listdir(root)):
        if not name.endswith('.json'):
            continue
        path = os.path.join(root, name)
        rec = recorded.get(path) or recorded.get(path.replace('/', '\\'))
        rows.append({'file': path, 'sha256Now': sha256(path),
                     'sha256Phase55': (rec or {}).get('sha256'),
                     'unchangedSincePhase55': bool(rec) and rec['sha256'] == sha256(path)})
R['frozenReferences'] = {'files': rows,
                         'allUnchanged': all(r['unchangedSincePhase55'] for r in rows if r['sha256Phase55']),
                         'note': 'Phase 5.3/5.4 holdouts stay read-only; Phase 5.6 adds its own sealed set.'}

# 4. Episode ledger ------------------------------------------------------------
ledger = json.load(open(os.path.join(P55, 'episodes', 'episodes_v3.json'), encoding='utf-8'))
episodes = ledger['episodes']
SUBAGENT_DIR = os.path.expanduser(r'~\.qoder-cn\projects\E--desktop-MATLAB\subagents')
ep_rows, model_counts = [], {}
for e in episodes:
    d = os.path.join(V3_ROOT, e['arm'], e['task'])
    tp = e.get('transcript') or ''
    tp_abs = tp if os.path.isabs(tp) else os.path.join(SUBAGENT_DIR, os.path.basename(tp))
    rp = os.path.join(d, 'result.json')
    pp = os.path.join(d, 'prompt.md')
    row = {
        'seq': e['seq'], 'arm': e['arm'], 'task': e['task'], 'model': e['model'],
        'episodeStatus': e['episodeStatus'], 'elapsedSec': e['elapsedSec'], 'mcpCalls': e['mcpCalls'],
        'transcriptExists': os.path.isfile(tp_abs),
        'resultExists': os.path.isfile(rp),
        'resultShaMatches': os.path.isfile(rp) and sha256(rp) == e.get('resultSha256'),
        'promptExists': os.path.isfile(pp),
        'promptShaMatches': os.path.isfile(pp) and sha256(pp) == e.get('promptSha256', ledger.get('promptSha256')),
        'expectedVerdict': e['expectedVerdict'], 'actualVerdict': e['actualVerdict'],
        'taskPass': e['taskPass'], 'fieldsPass': e['fieldsPass'], 'fieldsTotal': e['fieldsTotal'],
        'clientSkillToolCalls': e['clientSkillToolCalls'],
        'violations': e['violations'], 'invalid': e['invalid'],
    }
    ep_rows.append(row)
    model_counts[e['model']] = model_counts.get(e['model'], 0) + 1
R['episodes'] = {'count': len(ep_rows), 'ledgerPromptSha256': ledger.get('promptSha256'),
                 'executionOrderNote': ledger.get('executionOrderNote'),
                 'allArtifactsIntact': all(r['transcriptExists'] and r['resultExists'] and r['resultShaMatches']
                                           and r['promptExists'] for r in ep_rows),
                 'modelUsage': model_counts, 'rows': ep_rows,
                 'failedEpisodeRecord': [f for f in os.listdir(os.path.join(P55, 'audit'))
                                         if 'FAILED' in f],
                 'creditLimitRecord': ledger.get('failedEpisodes')}

# 5. Isolation summary recomputed from the per-episode audits ------------------
audit_dir = os.path.join(P55, 'audit')
summ = json.load(open(os.path.join(audit_dir, 'isolation_audit.json'), encoding='utf-8'))['summary']
recomputed = {'episodes': 0, 'withViolations': 0, 'invalid': 0, 'skillToolCalls': 0}
kinds = {}
for name in sorted(os.listdir(audit_dir)):
    if not name.endswith('.json') or name == 'isolation_audit.json':
        continue
    # *_FAILED.json is the credit-limit abort with an empty transcript. It is kept
    # as evidence but was never an audited episode, so including it here would
    # misreport the audit coverage as 21 instead of 20.
    if 'FAILED' in name:
        continue
    a = json.load(open(os.path.join(audit_dir, name), encoding='utf-8'))
    recomputed['episodes'] += 1
    v = a.get('violations') or []
    if v:
        recomputed['withViolations'] += 1
    for x in v:
        kinds[x if isinstance(x, str) else json.dumps(x, ensure_ascii=False)] = 1
    recomputed['invalid'] += 1 if a.get('invalid') else 0
    recomputed['skillToolCalls'] += len(a.get('skillToolCalls') or [])
R['isolation'] = {
    'auditFilesOnDisk': sorted(n for n in os.listdir(audit_dir)
                               if n.endswith('.json') and n != 'isolation_audit.json'),
    'excludedFromAuditCount': [n for n in os.listdir(audit_dir) if 'FAILED' in n],
    'recordedSummary': {'episodesAudited': summ['episodesAudited'],
                        'episodesWithViolations': summ['episodesWithViolations'],
                        'invalidEpisodes': len(summ['invalidEpisodes']),
                        'clientSkillToolCallEpisodes': len(summ['clientSkillToolCallEpisodes'])},
    'recomputedFromFiles': {k: v for k, v in recomputed.items() if k != 'invalid'} |
                          {'invalidEpisodes': recomputed['invalid'], 'violationKinds': sorted(kinds)},
    'summaryMatchesFiles': (recomputed['episodes'] == summ['episodesAudited']
                            and recomputed['withViolations'] == summ['episodesWithViolations']
                            and recomputed['invalid'] == len(summ['invalidEpisodes'])),
    'adversarialProbe': summ['isolationProbe'],
    'residualLimits': summ['residualLimits'],
    'phase56Verdict': 'Enforcement was NOT achieved in Phase 5.5: the probe read the sealed answers, '
                      'listed the user-level skill tree and ran local matlab -batch. Phase 5.6 Task 1 '
                      'must change that or keep the causal comparison BLOCKED.',
}

# 6. The two engineering-judgement defects ------------------------------------
grade = json.load(open(os.path.join(P55, 'grades', 'agent_grade_v3.json'), encoding='utf-8'))
misses = []
for arm in grade['arms']:
    if arm['arm'] != 'R3':
        continue
    for row in arm['rows']:
        if not row['pass'] and row['actualVerdict'] != 'MISSING':
            misses.append({'taskId': row['taskId'], 'expectedVerdict': row['expectedVerdict'],
                           'actualVerdict': row['actualVerdict'],
                           'fieldDetail': row['fieldDetail'], 'resultFile': row['resultFile'],
                           'resultSha256': row['resultSha256'],
                           'resultStillExists': os.path.isfile(row['resultFile'])})
R['judgementDefects'] = {'evidence': misses,
                         'frozenAnswersUntouched': R['frozenReferences']['allUnchanged'],
                         'classification': {
                             'H-SIG-B': 'Verdict-category defect: insufficient evidence was reported as '
                                        'the claim being refuted. Real agent-side defect.',
                             'H54-ODE-N': 'Field-definition ambiguity in the contract: verdict right, '
                                          'error.maxScaled computed on the solver tolerance grid instead of '
                                          'the acceptance tolerance. Real contract defect, not a tolerance problem.'}}

# 7. Tools ---------------------------------------------------------------------
R['tools'] = {n: {'exists': os.path.isfile(os.path.join(P55, n)), 'sha256': sha256(os.path.join(P55, n))}
              for n in ['stage_phase55.m', 'grade_phase55.m', 'audit_subagent.py', 'analyze_v3.py',
                        'score_spec.json']}

os.makedirs(OUT_DIR, exist_ok=True)
out = os.path.join(OUT_DIR, 'freeze_report.json')
json.dump(R, open(out, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
print('wrote', out)
print('worktreeClean', R['git']['worktreeClean'], 'phase55 drift', repr(R['git']['phase55BlobDrift']),
      'skills drift', repr(R['git']['skillsSourceDrift']))
print('frozen allUnchanged', R['frozenReferences']['allUnchanged'])
print('episodes', R['episodes']['count'], 'intact', R['episodes']['allArtifactsIntact'],
      'models', R['episodes']['modelUsage'])
print('isolation summary matches files', R['isolation']['summaryMatchesFiles'],
      R['isolation']['recomputedFromFiles'])
print('defect evidence exists', [(m['taskId'], m['resultStillExists']) for m in misses])
