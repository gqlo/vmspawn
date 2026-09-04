---
name: require-corresponding-tests
description: >-
  Enforce that every new or behavior-changing function in Python, JavaScript,
  Bash, or related vstorm code ships with a matching unit test. Use when writing
  or editing functions, helpers, API handlers, dashboard-lib.js, serve.py,
  vstorm/bash scripts, or when the user asks to add features without tests.
---

# Require Corresponding Tests

When implementing new behavior, **do not finish** until a corresponding test exists and passes.

## Workflow

1. Identify each new/changed **function** (or method / exported helper / significant bash function).
2. Add or update the matching test in the table below **in the same change**.
3. Run the relevant suite and fix failures (prefer fixing code over weakening tests).

## Where tests live

| Code | Tests | Run |
|---|---|---|
| `monitoring/data-collector/**/*.py`, `monitoring/scripts/*.py` | `monitoring/tests/test_*.py` | `python3 -m unittest discover -s monitoring/tests -v` |
| `monitoring/data-collector/static/dashboard-lib.js` | `monitoring/tests/test_dashboard_lib.js` | `node --test monitoring/tests/test_dashboard_lib.js` |
| Pure logic currently in `app.js` | Extract to `dashboard-lib.js`, then test there | same as above |
| `vstorm`, `helpers/`, `workload/`, bats helpers | `tests/*.bats` | `bats tests/` |

## What “corresponding” means

- Assert the function’s contract (return value, side effects that are part of the API, error cases).
- At least: one success case; for non-trivial logic, one edge or failure case.
- Name or place the test so it is obvious which function it covers.

## Do not

- Ship untested new helpers “for now”.
- Put complex logic only in DOM handlers or large untested bash blocks when it can be extracted.
- Change tests solely to make them pass when the code is wrong (see rule `test-fix-discipline.mdc`).

## Done checklist

- [ ] Every new/changed function has a test
- [ ] Relevant suite(s) run clean locally
- [ ] CI jobs that cover that language are expected to pass (`test`, `test-python`, `test-js`)
