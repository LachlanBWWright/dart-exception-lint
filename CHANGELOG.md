# Changelog

## 0.1.0-dev.1

- Added production-readiness documentation, published-package installation
  guidance, and CI validation including example analysis and publish dry-run.
- Added intent-aware inference for synchronous and asynchronous throw sources.
- Added manifest-backed third-party API matching.
- Added visible `invalid_exception_analysis_config` warnings for malformed
  plugin configuration and throwing API manifests.
- Deduplicated inferred reports when a call is already covered by the
  manifest-backed diagnostic.
- Added typed async-producer effects, stored-future tracking, correct
  awaited-versus-unawaited protection, and local function tear-off inference.
- Added class-level exception boundaries and conservative block reachability
  for inferred summaries.
