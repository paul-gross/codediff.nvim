applyTo:
  - tests/**
---

# Test Directory Guidelines

When working with tests in this directory:

- **Extend existing tests**: Add new test cases to existing test files whenever possible; only create new test files when covering genuinely distinct functionality
- **Test runner auto-discovers specs**: `tests/run_plenary_tests.sh` finds all `*_spec.lua` files automatically via `find tests -name '*_spec.lua'` — no registration needed when adding new spec files
- **No legacy API in tests**: When fixing tests, always update them to use the latest API; never add backward compatibility or reintroduce removed APIs for test compatibility—tests must use current production APIs
