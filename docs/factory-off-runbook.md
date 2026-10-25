# Factory off / on runbook

The executable companion to README's "Rebuild": the cheap pause. `tofu
destroy` is the off-switch that releases everything; `scripts/factory-off`
is the one that stops the main cost and keeps the cluster restorable as it
was. Written 2026-10-25; every command of the off path ran that day.

What off means for the bill: Hetzner bills a server that exists, running
or stopped, so a shutdown alone saves nothing. `scripts/factory-off`
deletes only the servers after one last backup round and disk snapshots.
Three cpx42 cost EUR 0.40 an hour, EUR 9.55 a day; that stops. The S3
buckets and the three primary IPv4s stay (a few cents to about EUR 2 a
month together), and the three disk snapshots stay (cents).

## Switch off: scripts/factory-off

Runs from the repo root, aborts before touching anything unless all three
nodes are Ready. In order:

1. One ad-hoc CNPG `Backup` (`factory-off-<stamp>`, barman plugin), waited
   to `completed`.
2. `pg_switch_wal()` on the primary, then 45 s for the archiver to ship
   the WAL to S3.
3. OpenBao: unsealed if sealed (the seed env's `OPENBAO_UNSEAL_KEY` is
   unpadded base64; the script pads it), then `bao operator raft snapshot
   save`, copied out and uploaded to
   `s3://aisoftwarefactory-backups/openbao/openbao-<stamp>.snap`.
4. One Forgejo dump job (`kubectl create job --from=cronjob/forgejo-dump`),
   waited to `complete`.
5. Shutdown of all three nodes, then a disk snapshot per node
   (`factory-off-<node>-<stamp>`), and only after all three snapshots are
   `available`, the servers are deleted. Older off-snapshots of a node are
   deleted; the primary IPv4s, the network and the firewall stay.

## Switch on: scripts/factory-on

Rebuilds one server per node from its newest `factory-off-` (or old
`sf-pause-`) snapshot, created powered off, given its old primary IPv4 at
create time, attached to the network with its old static private address,
then powered on. No address changes, so kubeconfig, talosconfig and the
DDNS records keep pointing correctly. Then the one hand step, the unseal:

```sh
python3 - <<'EOF' | kubectl exec -i -n platform openbao-0 -- sh -c 'k="$(cat)"; bao operator unseal "$k"'
import re, pathlib
k = re.match(r'OPENBAO_UNSEAL_KEY=(.*)', next(l for l in (pathlib.Path.home()
    / 'repos/ai-software-factory/.env.seed').read_text().splitlines()
    if l.startswith('OPENBAO_UNSEAL_KEY='))).group(1).strip()
print(k + '=' * (-len(k) % 4), end='')
EOF
```

Verified end to end on 2026-10-25: off (backup round, snapshots, server
deletion), then `scripts/factory-on` from the deleted state (three servers
rebuilt from the snapshots, same public and private addresses, nodes Ready,
OpenBao unsealed, Postgres healthy, Forgejo serving), then off again. The
fallback beyond the snapshots stays the full re-seed (README "Rebuild",
[reseed-runbook](reseed-runbook.md)), which restores from S3 plus Git plus
the seed bundle and has run twice.

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
