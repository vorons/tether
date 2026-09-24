# Spec Delta: tui

## ADDED Requirements

### Requirement: Login picker lists full catalog

The bare-`/login` provider picker SHALL list every provider-catalog id (not a hardcoded triple), derived from the same catalog the dispatcher uses, so picker and dispatcher can never disagree.

#### Scenario: New preset appears in picker

- **WHEN** the catalog contains `deepseek`
- **THEN** bare `/login` lists `deepseek` and selecting it enters secret mode for `deepseek`
