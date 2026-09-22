# PLAN: Infomarchy fleet desk — completion

Started: 2026-09-06
Root: finish the missing work from the Infomarchy fleet desk session with testable outcomes.

## Tree (depth 3)

```
root
├── leaf-1  Survival: git fork + commit + push + PR  [ OWNS: infomarchy-fork/ ]
├── leaf-2  Nexus local desk verify + fix             [ OWNS: SSH nexus ~/.config/omarchy/plugins/nixfred.infomarchy/ ]
├── leaf-3  Sentry local desk verify + fix             [ OWNS: SSH sentry ~/.config/omarchy/plugins/nixfred.infomarchy/ ]
├── leaf-4  Host filter: heatmap + usage + counts     [ OWNS: InfoView.qml, fleet.ts ]
├── leaf-5  Prompt redaction audit (fleet merge)      [ OWNS: audit only ]
└── leaf-6  README + screenshot                       [ OWNS: README.md, docs/ ]
```

## Dependencies

| leaf | depends on | blocks |
|---|---|---|
| 1 | — | — |
| 2 | — | — |
| 3 | — | — |
| 4 | 1 (git state clean) | — |
| 5 | — | — |
| 6 | 1,2,3,4 | — |

All leaves 1,2,3,5 can start immediately. 4 waits on 1 (so changes land in git first). 6 waits on everything.

## Status log

- 2026-09-06T16:50 — plan written. Dispatching leaves 1,2,3,5 in parallel.
