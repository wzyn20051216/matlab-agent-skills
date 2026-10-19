---
name: matlab-data-analysis
description: MATLAB R2026a data analysis workflow for tables, timetables, statistics, fitting, optimization-assisted analysis, visualization, report artifacts, and reproducible paper figures. Use whenever the user asks MATLAB to analyze data, plot results, fit models, process CSV/Excel/MAT files, or reproduce figures.
---

# MATLAB Data Analysis

Use this skill for MATLAB analysis pipelines that start with data and end with validated numbers, figures, or reports.

## Workflow

1. Inventory input files and schemas before coding.
2. Load data with typed APIs: `readtable`, `readtimetable`, `matfile`, `datastore`, or toolbox importers.
3. Normalize units, time zones, missing values, categorical fields, and outliers explicitly.
4. Build analysis as functions plus a thin runner script.
5. Save clean data, figures, and summary metrics under `artifacts/`.
6. Validate with shape checks, range checks, and at least one numerical assertion.

## API Preferences

- Tables and timetables for labeled data.
- `groupsummary`, `rowfun`, `varfun`, `synchronize`, and `retime` for structured transformations.
- `fitlm`, `fitnlm`, `fitrgp`, `fitcsvm`, or `fitcensemble` only after checking toolbox availability.
- `optimproblem` or solver APIs for constrained fitting when simple regression is not enough.
- Export figures with explicit size, resolution, and format.

## Reproducible Figures

Every reproduced paper figure should include:

- Source data provenance.
- Script name and command used.
- Random seed if applicable.
- Axis labels, units, legend, and saved image path.
- A simple metric comparing reproduced result with reference when possible.

## Validation

Use checks such as:

```matlab
assert(height(T) > 0)
assert(all(isfinite(metrics.rmse)))
assert(isfile(fullfile(outDir, "figure_1.png")))
```

Do not accept a plot as "done" unless the underlying numerical summary also looks sane.

## Cleaning That Accounts For Every Row

```matlab
r = mas_table_audit(T, struct('missing','drop','duplicates','drop', ...
    'outliers', struct('method','iqr','factor',1.5,'action','remove')));
r.balanced    % nRowsIn == nRowsOut + nDropped, and every dropped row has a reason
r.audit       % per rule: before, after, dropped, filled
r.dropped     % the removed rows WITH the rule that removed each one
```

The failure this prevents is not a crash, it is arithmetic that does not add up: three
rules that each drop their own rows will double-count a row that qualifies for two,
and "40 in, 30 out, dropped 3+4+4" reads fine and is wrong by one.

So every row gets exactly ONE verdict, from the first rule that matches, and the
balance identity is checked. Rule order (missing -> duplicates -> outliers) is part of
the contract and is printed, because changing it changes the counts.

Non-numeric columns are reported in `typeWarnings` and preserved; they are never
silently converted or dropped. `tests/test_table_audit.m` covers the nominal fixture,
a row that qualifies for two rules, fill-vs-drop, mixed types, an empty table and a
non-table input.
