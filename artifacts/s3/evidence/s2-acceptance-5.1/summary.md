# S2 independent acceptance A-J

- overall: **PASS**
- checks: 10 PASS / 0 FAIL / 0 SKIP
- repository: E:\desktop\MATLAB
- git: phase5.1-audit @ 876a2b0c67dae275c199415752226ed71c9c344f
- scope: isolated simulated installation; no real user-level Skill directory was read or written

| id | check | status | detail |
|---|---|---|---|
| A | first install of nine Skills | PASS | exit=0; installed=9; missing= |
| B | installed resource and SHA-256 parity | PASS | files=123; failures=0; forbidden=0; payloadConfigSha256=B73926D4B8EE959FDA78ED854511B071D45CD59F750DBB97397EC63B57E2161F |
| F | repeat install is zero-write | PASS | exit=0; unchanged=9; diff=0; manifestEqual=True; backupSessions=1->1 |
| G | failed upgrade restores the pre-upgrade tree | PASS | exit=1; decision=error; restored=True; diff=0; staging=0 |
| D | MCP session check runs from the installed Skill | PASS | probe produced a staged verdict: overall=FAIL, achieved=L0, exit=1 |
| C | commands run outside the repository and Skill root | PASS | module modules=4; outside=0; cwd=D:\Temp\mas-s2-acceptance-a24e97b786a341b291ca69714d89c32b\clean-install\project |
| E | no source-repository fallback | PASS | cleanRootHasRepo=False; moduleOutside=0; fallbackHits=0 |
| H | S1 credential protection in the installed layout | PASS | sanitizerRedacted=True; sessionPresent=True; keyAvailable=True; scanned=21; leaks=0 |
| I | uninstall leaves no payload residue | PASS | exit=0; removed=9; preserved=0; residualSkills=0; residualPayload=0 |
| J | sandbox cleanup | PASS | sandboxRemoved=True |

Raw evidence: A-install.*, B-installed-sha256.json, D-probe.*, E-module-resolution.*, F-repeat.*, G-upgrade.*, H-*, I-uninstall.*, acceptance-report.json