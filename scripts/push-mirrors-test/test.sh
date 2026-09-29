#!/bin/sh
# Offline test of k8s/platform/forgejo/push-mirrors.sh against a stub curl, in the CronJob image:
#   docker run --rm --user 1000:1000 -v "$PWD/scripts/push-mirrors-test:/t:ro" -v "$PWD/k8s/platform/forgejo:/s:ro" --entrypoint sh alpine/k8s:1.36.1@sha256:692239d739589247c4a791205ed9619c28ae85a21286e19a6211c04a62c56668 /t/test.sh
# recorded: AUTH is GitHub's stderr for a bad token (git push, 2026-09-29) in
# Forgejo 15.0.9's "push failed: %w - %s" with "exit status N - " stripped;
# GH007's first line is the live last_error (rebuild-stage9-report.md)
AUTH="push failed: remote: Invalid username or token. Password authentication is not supported for Git operations.
fatal: Authentication failed for 'https://github.com/sebastianrueckerai/REPO.git/'
"
GH007="PushRejected Error: remote: error: GH007: Your push would publish a private email address.
remote: You can make your email public or disable this protection by visiting:
remote: https://github.com/settings/emails
To https://github.com/sebastianrueckerai/REPO.git
 ! [remote rejected] main -> main (push declined due to email privacy restrictions)
error: failed to push some refs to 'https://github.com/sebastianrueckerai/REPO.git'
"
NET="push failed: fatal: unable to access 'https://github.com/sebastianrueckerai/REPO.git/': Could not resolve host: github.com
"
DENY="push failed: remote: Permission to sebastianrueckerai/REPO.git denied to sebastianrueckerai.
fatal: unable to access 'https://github.com/sebastianrueckerai/REPO.git/': The requested URL returned error: 403
"
export PATH="/t/bin:$PATH" GITHUB_TOKEN=tok FORGEJO_USER=u FORGEJO_PASSWORD=p
pass=0; fail=0
m() { jq -nc --arg n "$1" --arg e "$2" --arg r "$3" '{remote_name: $n, remote_address: ("https://github.com/sebastianrueckerai/" + $r + ".git"), last_error: $e}'; }
# case NAME CODE_MIRRORS INFRA_MIRRORS CODE_SYNCERR WANT_EXIT WANT_LOG WANT_CALLS
case_() {
  STATE=$(mktemp -d); export STATE
  echo "$2" > "$STATE"/ai-software-factory-code.json; echo "$3" > "$STATE"/ai-software-factory-infra.json
  [ -z "$4" ] || printf '%s' "$4" > "$STATE"/ai-software-factory-code.syncerr
  : > "$STATE"/calls
  out=$(sh /s/push-mirrors.sh 2>&1); rc=$?
  calls=$(grep -v '^GET' "$STATE"/calls | tr '\n' ';')
  if [ "$rc" = "$5" ] && [ "$out" = "$6" ] && [ "$calls" = "$7" ]; then pass=$((pass+1)); echo "PASS $1"
  else fail=$((fail+1)); printf 'FAIL %s\n  rc=%s want %s\n  out=%s\n want=%s\n  calls=%s\n want=%s\n' "$1" "$rc" "$5" "$out" "$6" "$calls" "$7"; fi
}
C=ai-software-factory-code; I=ai-software-factory-infra
ok_i="[$(m mi '' $I)]"
case_ gh007-both "[$(m mc "$GH007" $C)]" "[$(m mi "$GH007" $I)]" "" 0 \
  "push-mirrors: $C: mc left alone, sync failing: PushRejected Error: remote: error: GH007: Your push would publish a private email address.; $I: mi left alone, sync failing: PushRejected Error: remote: error: GH007: Your push would publish a private email address.;" ""
case_ healthy "[$(m mc '' $C)]" "$ok_i" "" 0 "push-mirrors: no change" ""
case_ auth-recreate "[$(m mc "$AUTH" $C)]" "$ok_i" "" 0 \
  "push-mirrors: $C: deleted mc created, synced;" \
  "DELETE /repos/sf/$C/push_mirrors/mc;POST /repos/sf/$C/push_mirrors;POST /repos/sf/$C/push_mirrors-sync;"
case_ auth-then-gh007 "[$(m mc "$AUTH" $C)]" "$ok_i" "$GH007" 0 \
  "push-mirrors: $C: deleted mc created, sync failed: PushRejected Error: remote: error: GH007: Your push would publish a private email address.;" \
  "DELETE /repos/sf/$C/push_mirrors/mc;POST /repos/sf/$C/push_mirrors;POST /repos/sf/$C/push_mirrors-sync;"
case_ auth-then-auth "[$(m mc "$AUTH" $C)]" "$ok_i" "$AUTH" 1 \
  "push-mirrors: $C: deleted mc created, sync failed: push failed: remote: Invalid username or token. Password authentication is not supported for Git operations.;" \
  "DELETE /repos/sf/$C/push_mirrors/mc;POST /repos/sf/$C/push_mirrors;POST /repos/sf/$C/push_mirrors-sync;"
case_ network "[$(m mc "$NET" $C)]" "$ok_i" "" 0 \
  "push-mirrors: $C: mc left alone, sync failing: push failed: fatal: unable to access 'https://github.com/sebastianrueckerai/REPO.git/': Could not resolve host: github.com;" ""
case_ denied-403 "[$(m mc "$DENY" $C)]" "$ok_i" "" 0 \
  "push-mirrors: $C: deleted mc created, synced;" \
  "DELETE /repos/sf/$C/push_mirrors/mc;POST /repos/sf/$C/push_mirrors;POST /repos/sf/$C/push_mirrors-sync;"
case_ dup-prefers-healthy "[$(m m1 "$GH007" $C),$(m m2 '' $C),$(m m3 "$AUTH" $C)]" "$ok_i" "" 0 \
  "push-mirrors: $C: deleted m1 deleted m3;" \
  "DELETE /repos/sf/$C/push_mirrors/m1;DELETE /repos/sf/$C/push_mirrors/m3;"
case_ none "[]" "$ok_i" "" 0 \
  "push-mirrors: $C: created, synced;" \
  "POST /repos/sf/$C/push_mirrors;POST /repos/sf/$C/push_mirrors-sync;"
echo "pass=$pass fail=$fail"; [ $fail = 0 ]
