# Factory off / on runbook

The executable companion to README's "Rebuild": the cheap pause. `tofu
destroy` is the off-switch that releases everything; `scripts/factory-off`
is the one that stops the main cost and keeps the cluster restorable as it
was. Written 2026-10-25.

What off means for the bill: Hetzner bills a server that exists, running
or stopped, so a shutdown alone saves nothing. `scripts/factory-off`
deletes only the servers after one last backup round and disk snapshots.
Three cpx42 cost EUR 0.40 an hour, EUR 9.55 a day (gross, Hetzner's
pricing API on 2026-11-18); that stops. The three primary IPv4s stay at
EUR 0.60 a month each, and the three disk snapshots at EUR 0.017 per GB a
month: the 2026-11-04 set held 193 GB, EUR 3.28 a month. The S3 buckets
bill the same whether the factory runs or not.

## Switch off: scripts/factory-off

Runs from the repo root, aborts before touching anything unless all three
nodes are Ready. In order:

1. One ad-hoc CNPG `Backup` (`factory-off-<stamp>`, barman plugin), waited
   to `completed`.
2. OpenBao: unsealed if sealed (the seed env's `OPENBAO_UNSEAL_KEY` is
   unpadded base64; the script pads it), then `bao operator raft snapshot
   save`, copied out and uploaded to
   `s3://aisoftwarefactory-backups/openbao/openbao-<stamp>.snap`.
3. One Forgejo dump job (`kubectl create job --from=cronjob/forgejo-dump`),
   waited to `complete`.
4. A wait until no Forgejo Actions run is waiting, running or blocked
   (`action_run` in Forgejo's database on the CNPG primary, polled every
   30 s, listed as `owner/name run N (status)` whenever the list changes).
   A shutdown kills a run's runner, so this wait comes after the backup
   round and catches the runs its minutes let start. After 90 minutes the
   script stops with the list and the servers still run: cancel the runs
   in Forgejo, then run it again.
5. `pg_switch_wal()` on the primary, then 45 s for the archiver to ship
   the WAL to S3.
6. Shutdown of all three nodes. Hetzner's shutdown action succeeds once
   the ACPI request is sent, not once the server is off, so the script
   polls each server until Hetzner reports it `off`. A node still running
   15 minutes after the request gets a hard power-off. Then a disk
   snapshot per node (`factory-off-<node>-<stamp>`), and only after all
   three snapshots are `available`, the servers are deleted. Older
   off-snapshots of a node are deleted; the primary IPv4s, the network and
   the firewall stay.

## Switch on: scripts/factory-on

Rebuilds one server per node from its newest `factory-off-` snapshot,
created powered off, given its old primary IPv4 at create time, attached to
the network with its old static private address, then powered on. No
address changes, so kubeconfig, talosconfig and the DDNS records keep
pointing correctly. Once the three nodes are Ready it deletes the
shutdown's leftover pods and prints each as `namespace/name`: every pod in
phase `Succeeded` or `Failed` that no Job owns. The pods that ran at the
shutdown stay as objects next to their replacements, and a label selector
that takes the first match lands on them (forgejo-dump on 2026-10-28); a
Job's pods stay, their logs are evidence. Last, it waits up to 10 minutes
for `openbao-0` to answer and unseals it with the seed env's
`OPENBAO_UNSEAL_KEY`, as the switch-off does.

Verified end to end on 2026-10-25: off (backup round, snapshots, server
deletion), then `scripts/factory-on` from the deleted state (three servers
rebuilt from the snapshots, same public and private addresses, nodes Ready,
OpenBao unsealed, Postgres healthy, Forgejo serving), then off again. The
fallback beyond the snapshots stays the full re-seed (README "Rebuild",
[reseed-runbook](reseed-runbook.md)), which restores from S3 plus Git plus
the seed bundle and has run twice. The wait for open Actions runs, the
wait for each server to report `off` and the switch-on's unseal came on
2026-11-18 and have not run live yet. A dry run against a fake Hetzner API
and fake kubectl passed every path, including a node that ignores the
shutdown request and runs that stay open past 90 minutes.

After an off/on, tofu state is stale: the next `tofu apply` is only ever
part of a full re-seed, never of a switch-on, because a recreated server
has no user_data and apply would replace it with empty disks.

## Console trap

Hetzner's action history for these servers has shown only the 2026-10-13
create actions: the shutdown, snapshot and delete actions of 2026-10-24/25
never appeared in it. Trust `hcloud server list` / the API, not the event
pane, when checking what a script did.

## Receipts of the 2026-10-25 run

Off at 19:47 UTC (`factory-off-20261025t1947`): CNPG backup completed, WAL
switched on sf-cluster-1, raft snapshot `openbao-20261025t1947.snap` in S3,
Forgejo dump `forgejo-2026-10-25.zip` (1.9 GiB) in S3, snapshots
`factory-off-sf-{0,1,2}-20261025t1947` available, all three servers deleted.
API afterwards: servers none, primary IPv4s unassigned, network `sf` and
firewall `sf` intact.

On: sf-0 172401364, sf-1 172401553, sf-2 172401667 rebuilt from those
snapshots with the same addresses (sf-0 2.31.19.248 / 10.0.1.10, sf-1
2.28.135.189 / 10.0.1.11, sf-2 2.28.143.118 / 10.0.1.12), nodes 3x Ready,
OpenBao unsealed with the seed key, CNPG "Cluster in healthy state", Forgejo
API answering (15.0.9+gitea-1.22.0).

Off again at 20:18 UTC (`factory-off-20261025t2018`): the same round on the
restored cluster, snapshots `factory-off-sf-{0,1,2}-20261025t2018` available,
servers none, the 19:47 snapshots pruned.

Fixed on the way: the forgejo-dump job exec'd into a stale Completed forgejo
pod (it now selects `status.phase=Running`), the Hetzner API read the JSON
bodies as form data without a Content-Type header, and the exists-path of
factory-on asked "is it off" where it must ask "is it running".
