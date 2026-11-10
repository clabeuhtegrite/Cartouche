# Branches

The [Branches workflow](../workflows/branches.yml) keeps the repository's branches to the ones in use. After every merge into main, every night and from the Actions tab, it deletes:

- the head branch of a closed pull request, merged or not, that is still at the commit the pull request ended on: the pull request keeps its commits, and **Restore branch** on its page brings the branch back;
- `release/v<version>`, once main's SideStore source lists that version or a later one: its release was merged, or a later one replaced it;
- what a workflow keeps for a branch (`launcher-screens/<branch>`, `builder-screens/<branch>`, `catalog-covers/<branch>`) once that branch is gone or goes.

It keeps main, the branches something reads (`gh-pages`, the site GitHub Pages serves, and `live-covers`, the covers Cartouche reads every day), the head of every open pull request, and every branch with commits that no pull request ended on: work in progress, which only its author deletes. A pull request's branch pushed to again after the merge, with new work, stays too.

[`clean_branches.py`](clean_branches.py) makes the list from the API's branches and pull requests, and writes every branch with the reason it goes or stays to the run's summary. The workflow's second job, which runs nothing from the repository, deletes each branch only if it is still at the commit listed (`git push --force-with-lease`), so that a push made in between keeps it. Run from the Actions tab with **Dry run** ticked, or from another branch than main, the workflow only lists them.

Tests, in the CI's Workflow audit: `python3 -m unittest discover -s .github/branches -v` (the workflow's own tests need PyYAML).
