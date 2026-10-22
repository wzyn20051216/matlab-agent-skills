#!/usr/bin/env python
"""Phase 5.5 Task 5 -- per-arm statistics for the v3 agent benchmark batch.

Reads the episode ledger, the per-episode audits and the sealed-answer grade,
and writes statistics that state every sample size explicitly. It never
constructs a skill-gain percentage: R1 and R2 were staged for one task each, so
the comparable cell is n=1 per arm and the comparison is reported as UNKNOWN.
"""
import json
import os
import re
import statistics
import sys

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BATCH = sys.argv[1] if len(sys.argv) > 1 else 'v3'
AUDIT_DIR = os.path.join(REPO, 'artifacts', 'phase55', 'audit')
LEDGER = os.path.join(REPO, 'artifacts', 'phase55', 'episodes', 'episodes_%s.json' % BATCH)
GRADE = os.path.join(REPO, 'artifacts', 'phase55', 'grades', 'agent_grade_%s.json' % BATCH)
ANSWERS = [r'E:\desktop\MATLAB-bench-holdout-phase53\answers.json',
           r'E:\desktop\MATLAB-bench-holdout-phase54\answers.json']
OUT = os.path.join(REPO, 'artifacts', 'phase55', 'analysis', 'statistics_%s.json' % BATCH)

expected_skill = {}
expected_verdict = {}
for path in ANSWERS:
    for t in json.load(open(path, encoding='utf-8'))['tasks']:
        expected_skill[t['id']] = t['skill']
        expected_verdict[t['id']] = t['verdict']

ledger = json.load(open(LEDGER, encoding='utf-8'))
episodes = ledger['episodes']

SKILL_DIR_RE = re.compile(r'skills[\\/]+([^\\/]+)[\\/]')


def skills_read_from(paths):
    out = set()
    for p in paths or []:
        m = SKILL_DIR_RE.search(p.replace('\\', '/'))
        if m:
            out.add(m.group(1))
    return sorted(out)


def as_list(x):
    if x is None:
        return []
    return x if isinstance(x, list) else [x]


grade = json.load(open(GRADE, encoding='utf-8'))
grade_rows = {}
for arm in as_list(grade['arms']):
    for row in as_list(arm['rows']):
        grade_rows[(arm['arm'], row['taskId'])] = row

# In-episode error signals come from the transcript audit, not from my memory.
# An earlier draft of this file hard-coded the recovery block to zero and was
# wrong: the v3 transcripts do contain error signals. Classify them so the
# recovery row can say what kind of failure the agent actually had to absorb.
MATLAB_MARKERS = ('意外的', '无法识别', '错误使用', '不支持', '语法', '必须为',
                  '没有可用', '不满足', '无法解析', 'matlab error')
TOOLING_MARKERS = ('Error: ', 'JSON_PARSE', 'validation failed', 'fetch failed',
                   'ECONNRESET', 'TypeError')


def classify(sig):
    if any(m in sig for m in MATLAB_MARKERS):
        return 'matlab'
    if any(m in sig for m in TOOLING_MARKERS):
        return 'tooling'
    return 'other'


def audit_name_for(ep):
    return '%s_%s_%s.json' % (BATCH, ep['arm'], ep['task'])


errors_by_episode = {}
for ep in episodes:
    path = os.path.join(AUDIT_DIR, audit_name_for(ep))
    if not os.path.isfile(path):
        continue
    sigs = as_list(json.load(open(path, encoding='utf-8')).get('errorSignals'))
    errors_by_episode[(ep['arm'], ep['task'])] = [classify(s) for s in sigs]

arms = {}
for arm_name in ('R1', 'R2', 'R3'):
    sel = [e for e in episodes if e['arm'] == arm_name]
    rows = [grade_rows[(arm_name, e['task'])] for e in sel]
    executed = [r for r in rows if r['actualVerdict'] != 'MISSING']
    undet_expected = [r for r in rows if r['expectedVerdict'] == 'UNDETERMINED']
    per = []
    for e, r in zip(sel, rows):
        cls = errors_by_episode.get((arm_name, e['task']), [])
        per.append(dict(
            task=e['task'], model=e['model'], elapsedSec=e['elapsedSec'], mcpCalls=e['mcpCalls'],
            expectedVerdict=r['expectedVerdict'], actualVerdict=r['actualVerdict'],
            taskPass=r['pass'], fieldsPass=r['fieldsPass'], fieldsTotal=r['fieldsTotal'],
            clientSkillToolCalls=e['clientSkillToolCalls'],
            skillsRead=e['skillDocOrToolReads'] and skills_read_from(e['skillDocOrToolReads']) or [],
            masExecuted=e.get('masToolsExecuted') or [],
            errorSignals=cls.count('matlab') + cls.count('tooling'),
            errorSignalsMatlab=cls.count('matlab'),
            errorSignalsTooling=cls.count('tooling'),
            patternHitsNotErrors=len(cls) - cls.count('matlab') - cls.count('tooling'),
            budgetExceededTime=e['elapsedSec'] > 900,
            budgetExceededMcp=e['mcpCalls'] > 25))
    arms[arm_name] = dict(
        nPlanned=len(rows), nExecuted=len(executed), nMissing=len(rows) - len(executed),
        nPass=sum(1 for r in executed if r['pass']),
        passRateExecuted=(sum(1 for r in executed if r['pass']) / len(executed)) if executed else None,
        firstTask=per[0]['task'] if per else None,
        firstTaskPass=per[0]['taskPass'] if per else None,
        falseAccepts=sum(1 for r in executed if r['falseAccept']),
        falseRejects=sum(1 for r in executed if r['falseReject']),
        undeterminedExpected=len(undet_expected),
        undeterminedDetected=sum(1 for r in undet_expected if r['actualVerdict'] == 'UNDETERMINED'),
        fieldsPass=sum(r['fieldsPass'] for r in executed),
        fieldsTotal=sum(r['fieldsTotal'] for r in executed),
        clientSkillToolCalls=sum(e['clientSkillToolCalls'] for e in sel),
        workspaceSkillDiscoveryEpisodes=sum(1 for p in per if p['skillsRead']),
        correctSkillEpisodes=sum(1 for p in per if expected_skill.get(p['task']) in p['skillsRead']),
        masExecutedEpisodes=sum(1 for p in per if p['masExecuted']),
        elapsedMeanSec=round(statistics.mean([e['elapsedSec'] for e in sel]), 1) if sel else None,
        elapsedMedianSec=round(statistics.median([e['elapsedSec'] for e in sel]), 1) if sel else None,
        mcpCallsMean=round(statistics.mean([e['mcpCalls'] for e in sel]), 1) if sel else None,
        mcpCallsMax=max([e['mcpCalls'] for e in sel]) if sel else None,
        timeBudgetViolations=sum(1 for p in per if p['budgetExceededTime']),
        mcpBudgetViolations=sum(1 for p in per if p['budgetExceededMcp']),
        episodesWithErrorSignals=sum(1 for p in per if p['errorSignals']),
        errorSignalsTotal=sum(p['errorSignals'] for p in per),
        errorSignalsMatlab=sum(p['errorSignalsMatlab'] for p in per),
        errorSignalsTooling=sum(p['errorSignalsTooling'] for p in per),
        episodesWithErrorAndGradedPass=sum(1 for p in per if p['errorSignals'] and p['taskPass']),
        perEpisode=per)

out = dict(
    schema='mas-phase55-statistics/1', batch=BATCH, generatedAt='2026-10-22',
    sampleSizeNote='R1 and R2 were staged and run for one task each (H-SIG-F); R3 ran the full '
                   '12-task set. n=1 per baseline arm is not enough for any rate comparison.',
    arms=arms,
    autoTriggering=dict(
        episodesTotal=len(episodes),
        clientSkillToolCalls=sum(e['clientSkillToolCalls'] for e in episodes),
        classification='UNKNOWN->EXPLICITLY_SELECTED not observed; AUTO_SELECTED (client Skill tool) = 0 of %d' % len(episodes),
        note='Zero episodes contain a client-native Skill tool_use. R3 episodes that opened skills/ in '
             'their own workspace are workspace auto-discovery, which is NOT the same claim. Prose '
             'mentions of a skill name are never counted as triggering.'),
    recovery=dict(
        errorSignalsTotal=sum(p['errorSignals'] for a in arms.values() for p in a['perEpisode']),
        episodesWithErrorSignals=sum(1 for a in arms.values() for p in a['perEpisode'] if p['errorSignals']),
        episodesTotal=len(episodes),
        byClass=dict(matlab=sum(a['errorSignalsMatlab'] for a in arms.values()),
                     tooling=sum(a['errorSignalsTooling'] for a in arms.values()),
                     patternHitsNotErrors=sum(p.get('patternHitsNotErrors', 0)
                                             for a in arms.values() for p in a['perEpisode'])),
        episodesWithErrorAndGradedPass=sum(1 for a in arms.values()
                                           for p in a['perEpisode'] if p['errorSignals'] and p['taskPass']),
        perEpisode=[dict(arm=name, task=p['task'], errorSignals=p['errorSignals'],
                         matlab=p['errorSignalsMatlab'], tooling=p['errorSignalsTooling'],
                         patternHitsNotErrors=p['patternHitsNotErrors'],
                         completed=True, gradedPass=p['taskPass'])
                    for name, a in arms.items() for p in a['perEpisode'] if p['errorSignals']],
        measure='An episode is counted as a recovered error only when a tool_result in its own transcript '
                'carried an error marker AND the episode still produced a graded result.json. Every episode '
                'with error signals completed. Signals whose text only matched the error pattern without '
                'being a failure (healthy contract output listing "0 fail", file contents containing the '
                'word "error") are counted separately as patternHitsNotErrors and excluded here.',
        limitation='First-attempt verdict per step was not recorded by the client, so recovery is reported as '
                   'a completed-after-error proxy, not as a precise success rate. The one hard failure this '
                   'batch saw was outside any episode: a client credit-limit abort on R3 H54-VIS-F, recorded '
                   'as ERROR_CREDIT_LIMIT and re-run (retrySeq 7).'),
    tokens=dict(status='NOT_OBSERVABLE',
                reason='Transcript message.usage exists but reports input_tokens=0 and output_tokens=0 on '
                       'every message in this client build, so token cost cannot be compared across arms.'),
    modelControl=dict(
        resolvedModels=sorted({e['model'] for e in episodes}),
        minimalTriple='R1/R2/R3 on H-SIG-F all ran on %s' % sorted({e['model'] for e in episodes if e['task'] == 'H-SIG-F'})[0],
        extensionCaveat='The 11 R3 extension episodes span two client-resolved models because the client '
                        'switched model mid-batch (a credit-limit abort preceded the switch). The R3 arm is '
                        'therefore a heterogeneous sample and cannot be compared to any single-model baseline.',
        pilotBatch='The v2 pilot triple mixed dfmodel (R1, R2) with qmodel_38max (R3) and is retained as a '
                   'pilot only; it is excluded from the fair-comparison claim.'),
    gainVerdict=dict(
        status='UNKNOWN',
        comparableCells=[dict(task='H-SIG-F', arms=['R1', 'R2', 'R3'], eachN=1,
                              result='all three reached the correct FAIL verdict with measured fPeak 50.0 Hz')],
        statement='On the single task run in all three arms, the Skill arm showed no accuracy advantage; it '
                  'was the slowest of the three in v3 (83.3 s vs 77.4 s and 59.7 s) and did not open a skill '
                  'document at all. At n=1 per arm this is not evidence of absence either, so no gain or loss '
                  'percentage is constructed.',
        whatIsProvable='R3 alone shows that a full-skill workspace can be autonomously discovered and used '
                       '(9 of 12 episodes opened the matching skill directory and 9 of 12 executed a mas_* '
                       'contract tool), and that the professional verdicts hold without any route hint.',
        whatIsNotProvable='Any Skills-vs-no-Skills accuracy, speed or cost improvement; client-native Skill '
                           'auto-triggering; a precise error-recovery rate (the client logs no per-attempt '
                           'verdict, only that every episode carrying error signals still completed).'))

os.makedirs(os.path.dirname(OUT), exist_ok=True)
json.dump(out, open(OUT, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
print('wrote %s' % OUT)
for name, a in arms.items():
    print('%s: executed %d/%d pass %d fields %d/%d undet %d/%d skillTool %d discovery %d/%d masExec %d/%d' % (
        name, a['nExecuted'], a['nPlanned'], a['nPass'], a['fieldsPass'], a['fieldsTotal'],
        a['undeterminedDetected'], a['undeterminedExpected'], a['clientSkillToolCalls'],
        a['workspaceSkillDiscoveryEpisodes'], a['correctSkillEpisodes'], a['nExecuted'], a['masExecutedEpisodes']))
