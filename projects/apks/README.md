# Per-Port Notes

One directory per package, named for the package:

```
projects/apks/<pkgname>/
├── PROJECT-INDEX.md        entry point: required reads, key links, the working rule
├── <pkgname>-README.md     living project doc: decisions and a running changelog
└── REPORT.md               after-action report for a human reviewer
```

Start a new one by copying `../PROJECT-INDEX-template.md` into the package's directory
and filling it in. The `qnx-port-reporting` skill defines the structure of `REPORT.md`;
`qnx-apk-packaging` step 8 explains how the three documents differ and why the README
and the report are not the same thing.

Keep package-specific detail here so the shared skills in `skills/` stay general. When a
port proves something that applies beyond that one package, that fact belongs in the
matching skill instead — see the capture-friction rule in `AGENTS.md`.

This directory is otherwise empty; ports populate it as they happen.
