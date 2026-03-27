# Contributing

Thank you for your interest in improving this project.

## Before You Start

- Search existing issues and pull requests before opening a new one.
- For larger changes, open an issue first so the direction can be aligned early.
- Keep proposals practical and production-oriented.

## Development Guidelines

- Keep changes focused and easy to review.
- Update documentation, examples, and comments when behavior changes.
- Avoid unrelated refactors in the same pull request.
- Preserve backward compatibility unless the breaking change is clearly documented.

## Validation

Before submitting a pull request, run the checks relevant to your change:

- validate `JSON`, `YAML`, and `XML` files
- run `bash -n` for shell scripts
- validate PowerShell syntax for `.ps1`, `.psm1`, and `.psd1` files
- test the actual workflow when the repository contains executable scripts or deployment steps

## Pull Requests

Please include:

- a short summary of what changed
- why the change is needed
- testing notes
- screenshots or sample output when useful

Small, well-scoped pull requests are preferred.

## Licensing

By submitting a contribution, you agree that your work may be distributed under the license used by this repository.
