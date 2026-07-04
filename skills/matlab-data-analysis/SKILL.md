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
