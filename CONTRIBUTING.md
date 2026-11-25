# Contributing

Thanks for helping! Small PRs are great. Turkish or English is fine everywhere.

## Setup

```bash
./scripts/build-app.sh && open build/InklingLab.app   # or: swift build
```

You need macOS 15+, Apple Silicon and the Swift 6 toolchain. The app does not need a model to build, but to try a change you need `llama-server` and one GGUF file (any small model works, it does not have to be Inkling).

## Guidelines

- Keep the UI consistent: colors, fonts and spacing come from `Design/Theme.swift`. Do not hard-code values in views.
- Swift 6 strict concurrency: UI state is `@MainActor`. Keep blocking work out of the main actor.
- Agent tools must stay sandboxed to the working folder. Anything that writes or executes must go through the approval flow.
- Benchmark numbers in PRs: say the chip, RAM, model file, context size and engine.
- One topic per PR, with a short description and a screenshot for UI changes.

## Good places to start

Look for issues labeled `good first issue`. Ideas:

- English localization (String Catalog)
- Syntax highlighting in code blocks
- Fix the needle-in-a-haystack test wording (the model refuses because the text says "don't share it")
- Add your Mac's benchmark results to `docs/benchmarks/`
- A bundle identifier and the `~/models` path as user settings
