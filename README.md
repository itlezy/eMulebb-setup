# eMulebb-setup

This repository is obsolete.

Workspace materialization, repo/worktree sync, status, dependency update
reporting, comparison launchers, validation, and build/test orchestration now
live in `EMULE_WORKSPACE_ROOT\repos\eMule-build` and are run through:

```powershell
python -m emule_workspace materialize
python -m emule_workspace sync
python -m emule_workspace validate
```

The canonical bootstrap layout is:

```text
<EMULE_WORKSPACE_ROOT>\
  repos\
    eMule-build\
```

Clone `eMule-build` into `repos\eMule-build`, then run `materialize` from that
repo. The generated workspace contract is `workspaces\v0.72a\deps.json`.
