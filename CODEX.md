# Codex Context

## Project

`Match Point GPT` is Codex' independent experiment track for a native macOS ATP
tennis sidekick. It is separate from Magnus' controlled `match-point` project.

The race is intentional:

- Magnus drives `/Users/magnus/Documents/GitHub/match-point`.
- Codex may experiment freely in `/Users/magnus/Documents/GitHub/match-point-gpt`.
- Useful ideas can be discussed and manually moved into `match-point`, but the
  projects must not be coupled at runtime.

## Product Direction

This app should behave less like a database browser and more like a scout radar:
graphics first, explanation second. Prefer compact visual signals over large
tables when the goal is to understand a matchup quickly.

Important principle: odds are extremely hard to beat. Oddset/market price is the
baseline, not a weak signal. ATP data, model output, form bars, warnings, and
surface context should help explain a match and identify what to watch, not claim
free edge.

Good signal language:

- `Överens`: market and model point in the same direction.
- `Konflikt`: market and model disagree; investigate why.
- `Stabil`, `Skör`, `Het`, `Röd zon`: form/readiness shorthand.
- `Skrällar`, `Varningsflaggor`, `Att bevaka`: curated scout cues.

Keep labels clear and non-magical. Avoid betting certainty language.

## Data

Oddset/Kambi provides live and upcoming matches. The local ATP database provides
player, form, rating, and model context. Runtime database credentials live in:

```text
~/Library/Application Support/Match Point GPT/.env
```

Do not commit credentials.
