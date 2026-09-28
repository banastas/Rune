# Fidelity harness (PRD HL7, S3)

Nib's highlighting against Sublime's, on the reference files, with An Old Hope · Nib in both:
at least 98% of non-whitespace characters must get the same foreground color.

- `reference/`: the six files (HTML, CSS, JavaScript, JSON, Markdown with fenced code, zsh),
  generated, until real files from the user's work replace them.
- `NibFidelity.py`: the Sublime plugin. It opens each reference file in a window of its own,
  sets An Old Hope · Nib on those views only, and writes every token's scope and color to
  `sublime/<file>.json`, then closes them. Installed in `Packages/User` with the scheme by
  `run.sh`; Sublime's own settings and files are only read.
- `run.sh`: installs both, asks Sublime for the dump, and runs Nib's comparison.
