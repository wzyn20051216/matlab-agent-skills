# Routing output contract (schema 1.1)

`mas_route(prompt)` returns a struct with a stable, versioned shape. Consumers
must branch on `decision` before doing anything else. The scoring is lexical,
not semantic: the contract says what the router can promise, and where it can
only ask.

## Required fields

| Field | Type | Meaning |
| --- | --- | --- |
| `schemaVersion` | char | `'1.1'`. A consumer that needs a different major version must stop. |
| `decision` | char | `ROUTE`, `CLARIFY`, `AMBIGUOUS`, or `BLOCKED`. |
| `primary` | char | Primary domain, `''` unless `ROUTE`. |
| `secondary` | cell | Score-based secondary domains; never dependencies. |
| `loadOrder` | cell | Topological order, dependencies first. Empty when not `ROUTE`. |
| `matched` | struct array | `skill`, `term`, `weight` for each scored hit. |
| `missing` | struct array | `kind`, `name`, `detail`, `hard` for each blocker. |
| `reason` | char | Human-readable explanation of the decision. |
| `nextAction` | char | `load`, `ask`, or `stop`. |
| `available` | struct array | `id`, `installed`, `loadable`, `problem` per selected skill. |
| `alwaysLoaded` | cell | Skills loaded on every route (currently `matlab-runner`). |
| `ranked` | struct array | `id`, `score`, `hits`, `priority`, highest first. |
| `notes` | cell | Non-blocking warnings, e.g. an unlicensed soft toolbox. |
| `prompt` | char | Original prompt, case preserved. |
| `tableSource` | char | Routing table path, or `opts.table` in tests. |
| `tableVersion` | char | Version of the table that produced the decision. |

The pre-1.0 fields `decision`, `primary`, `loadOrder`, `ranked`, `matched`,
`reason` and `prompt` are unchanged. Everything else is additive, so a caller
written against the old shape keeps working; a caller that never checked
`decision` was already wrong.

## Decisions

| Decision | `nextAction` | What the agent does |
| --- | --- | --- |
| `ROUTE` | `load` | Load `loadOrder` in order, then execute the primary skill's workflow. |
| `CLARIFY` | `ask` | Ask one question. Do not pick a domain from the top-ranked guess. |
| `AMBIGUOUS` | `ask` | Ask which of the tied domains carries the core work. |
| `BLOCKED` | `stop` | Stop. Report `missing` verbatim. Do not substitute another skill. |

`CLARIFY` and `AMBIGUOUS` still fill `loadOrder` with the always-loaded skills
so that a caller can prepare the execution layer, but `primary` stays empty.

`BLOCKED` clears `primary`, `secondary`, and `loadOrder`. A blocked pipeline
must not run a partial workflow: a route that cannot load the skill that owns
the work has no honest partial answer.

## Scoring and refusals

- Each domain sums the weights of its matched terms from
  `assets/routing.json`. `matched` lists exactly those terms and weights, and
  their sum equals `ranked(k).score` for that skill.
- A score below `minScore` is `CLARIFY`, even if one term matched.
- A tie at the top is `AMBIGUOUS`, evaluated before secondary selection.
- Secondary skills join at `score >= multiSkillRatio * top`.
- `matlab-testing-ci` joins when the prompt asks for acceptance/regression or
  when a secondary already includes it.
- `matlab-runner` is always loaded and is never scored.

### Negation and short tokens

A term preceded by a negator in the same clause does not score. The lookback is
24 characters, cut at clause separators (`，`, `,`, `。`, `;`, `而是`, `只做`,
`仅做`, ...), so `不做图像处理，只做 PID 控制` keeps PID and drops image
processing. This is a lexical guard for the common misleading keyword, not
natural-language understanding; a negator outside the window is still missed.

ASCII terms of three characters or fewer (`ci`, `ros`, `dh`, `mex`) match on
word boundaries, so `specific` does not activate CI.

## Dependencies and availability

`dependsOn` in the routing table declares execution dependencies. The router
takes the closure of the selected skills, orders it topologically, and places
dependencies before dependents. `matlab-runner` is normally first because every
non-runner skill declares it.

Before returning `ROUTE`, the router checks every skill in the closure:

| `missing.kind` | Cause | Result |
| --- | --- | --- |
| `skill` | skill directory absent | `BLOCKED` |
| `content` | `SKILL.md` absent or empty | `BLOCKED` |
| `toolbox` | hard requirement fails `license('test', feature)` | `BLOCKED` |
| `dependency` | `dependsOn` names a skill not in the table | `BLOCKED` |
| `dependency_cycle` | topological sort finds a cycle | `BLOCKED` |

A soft requirement (`"hard": false`) that is unlicensed does not block; its
warning goes into `notes`. `available(k).loadable` is `false` for both missing
and damaged skills, so a consumer can inspect availability even when the
decision is `ROUTE` in a test fixture.

The router never invents a skill name. Test fixtures are the only place where
skill ids such as `alpha`/`beta` exist, and they are passed through `opts.table`
and `opts.skillStatus` rather than being added to `routing.json`.

## Consumer recipe

```matlab
r = mas_route(prompt);
switch r.decision
    case 'ROUTE'
        for k = 1:numel(r.loadOrder)
            load_skill(r.loadOrder{k});   % dependency order is already correct
        end
    case {'CLARIFY', 'AMBIGUOUS'}
        ask_one_question(r.reason);       % do not guess
    case 'BLOCKED'
        report_and_stop(r.missing);       % do not fall back to another domain
end
```

Never override a `BLOCKED`, never reorder `loadOrder`, and never treat
`CLARIFY` as permission to use `ranked(1)`.

## Coverage

`tests/test_routing_contract.m` 16/16 pins the contract: real route, single
domain, multi-skill, similar-domain ambiguity, unknown prompt, negation and
clause scope, short-token boundaries, missing toolbox, uninstalled skill,
damaged skill, dependency order, missing dependency, dependency cycle, blocked
output shape, and the `matched`-sum invariant.

`tests/test_routing.m` 9/9 is the historical regression, unchanged: the Phase 4
brief examples, the two must-not-guess cases, and the runner-always-first rule.

## Known limits

- The table is curated. A domain with no terms cannot be routed even if the
  request is plainly in that domain; the honest output is `CLARIFY`.
- Negation is clause-local and lexical; double negation and indirect phrasing
  are outside the contract.
- Availability is checked from the filesystem and license features, not by
  loading the skill. A skill that is present but internally broken is only
  caught when its own tests or prechecks run.
- The router validates `dependsOn` against the routing table, not against the
  SKILL.md prose. Keep the two in sync; `mas_skill_graph` checks the call graph.
