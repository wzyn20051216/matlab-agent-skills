# S2 independent acceptance A-J

- overall: **FAIL**
- checks: 4 PASS / 6 FAIL / 0 SKIP
- repository: E:\desktop\MATLAB
- git: phase5.1-audit @ 876a2b0c67dae275c199415752226ed71c9c344f
- scope: isolated simulated installation; no real user-level Skill directory was read or written

| id | check | status | detail |
|---|---|---|---|
| A | first install of nine Skills | FAIL | exit=; installed=9; missing= |
| B | installed resource and SHA-256 parity | PASS | files=119; failures=0; forbidden=0; payloadConfigSha256=2914FF29FA3CEEE65990E6C6F35C8AA6ACB47289695D3DA1BB4AA8D2962065CA |
| F | repeat install is zero-write | FAIL | exit=; unchanged=9; diff=0; manifestEqual=True; backupSessions=1->1 |
| G | failed upgrade restores the pre-upgrade tree | PASS | exit=; decision=error; restored=True; diff=0; staging=0 |
| D | MCP session check runs from the installed Skill | PASS | probe produced a staged verdict: overall=SKIP, achieved=L0, exit= |
| C | commands run outside the repository and Skill root | FAIL | module modules=4; outside=0; cwd=D:\Temp\mas-s2-acceptance-e7de31f2477d473da80cc4847fd37bb2\clean-install\project |
| E | no source-repository fallback | FAIL | cleanRootHasRepo=False; moduleOutside=0; fallbackHits=0 |
| H | S1 credential protection in the installed layout | FAIL | sanitizerRedacted=False; sessionPresent=True; keyAvailable=True; scanned=22; leaks=0 |
| I | uninstall leaves no payload residue | FAIL | exit=; removed=9; preserved=0; residualSkills=0; residualPayload=0 |
| J | sandbox cleanup | PASS | sandboxRemoved=True |

Raw evidence: A-install.*, B-installed-sha256.json, D-probe.*, E-module-resolution.*, F-repeat.*, G-upgrade.*, H-*, I-uninstall.*, acceptance-report.json