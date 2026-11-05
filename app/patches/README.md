# Patches

Our changes to LiveContainer (`livecontainer/`) and SideStore (`sidestore/`, which includes its `Dependencies/SideSign`). `app/scripts/build.sh` applies them in name order to copies of the pinned sources, with `patch -p1` from the root of each project.

## Conventions

- Name: `NNNN-short-description.patch`, numbered in the order they apply.
- Make them with `git format-patch` from a checkout of the pinned commit, so that each keeps its author, date and explanation.
- One change per patch. A patch that would help the upstream project too should be offered to it; once upstream has it, move the submodule past it and drop the patch.

## Planned

| Project | Patch | Phase |
| --- | --- | --- |
| LiveContainer | Branding: identifiers, name, icon, URL schemes | 1 |
| SideStore | Request Increased Memory Limit on the App ID for free accounts ([SideStore#1616](https://github.com/SideStore/SideStore/issues/1616)) | 1 |
| LiveContainer | The launcher, in place of LiveContainer's app list | 1 |
