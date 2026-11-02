# 51. Keep Activity hidden by default

Date: 2026-11-02
Status: Accepted

## Context

During signed-app validation, the owner identified the Activity window as
unwanted automatic UI and asked to retain Flect's menu-first interaction.

## Decision

Default Show progress window to off, including Reset All Settings. Preserve
explicit saved preferences. Keep manual Activity access, progress, comparison,
retry, menu-bar status and notifications. The owner's current installation
also receives an explicit off preference at their request.

## Consequences

Ordinary processing does not open Activity unless enabled or explicitly opened.
Results remain available on demand; failures continue through existing
menu-bar and notification feedback. Required input panels are unchanged.
