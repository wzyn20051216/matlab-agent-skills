# Contributing

Thanks for helping improve `matlab-r2026a-agent-skills`.

This project values practical MATLAB workflows that can be executed, inspected, and validated. A good contribution should make agent-driven MATLAB work more reliable, not just more verbose.

## Good Contributions

- New specialist skills for a concrete MATLAB workflow.
- Better validation scripts and smoke tests.
- Reproducible paper or toolbox examples using public data.
- GitHub Actions or self-hosted runner improvements.
- Documentation that clarifies setup, licensing, or failure modes.

## Skill Quality Bar

Every new or changed skill should answer:

- When should this skill trigger?
- Which MATLAB products or toolboxes does it need?
- What command should the agent run?
- Which artifacts should be saved?
- How does the agent know the task passed?

Avoid adding advice that cannot be verified locally or through official documentation.

## Development Loop

Run the local smoke test before opening a pull request:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Test-MatlabSkills.ps1
```

If your change does not require MATLAB execution, explain why in the pull request.

## Documentation Style

- Be direct and operational.
- Prefer small runnable examples.
- Mark license, toolbox, hardware, dataset, and platform assumptions clearly.
- Use community posts as clues, not as authority.
