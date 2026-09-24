# Talos configs

secrets.yaml is generated per cluster and lives in the seed bundle,
never here. The generated controlplane-<N>.yaml files, worker.yaml and
talosconfig embed the cluster secrets too, so they are gitignored and
regenerated on demand from secrets.yaml, patches.yaml and node-<N>.yaml
with the commands in docs/plans/2026-09-24-build-plan.md Task 7 Step 4.
