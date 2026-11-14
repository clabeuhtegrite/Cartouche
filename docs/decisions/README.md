# Decisions, a file each

Each decision that [decisions.md](../decisions.md) does not have as a row is a file of this folder, named by its number on three digits: `095.md` for decision 95, `109.md` for decision 109. Two pull requests that each add a decision add two files, and no longer conflict over the end of a table ([decision 109](109.md)). Two that take the same number meet on the same file name: the one that reaches main second takes the next free number.

A decision's file has its number and the decision in a line as its title, then its date, what was decided and why, as a row of the table did:

```markdown
# 109. A new decision is a file of its own

2026-11-14

What was decided.

**Why.** Its reasons.
```

A decision that amends, narrows or reverses an earlier one says so, and marks the earlier one where it is: in its file, or in its row of decisions.md ("Reversed by 112").

Link to a decision by its file: `[decision 109](decisions/109.md)` from `docs/`, `[decision 109](../docs/decisions/109.md)` from a folder beside it.
