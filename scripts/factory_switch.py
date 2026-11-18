# The Hetzner API, kubectl and OpenBao calls that scripts/factory-off and
# scripts/factory-on share. The Hetzner token comes from terraform.tfvars,
# the OpenBao key from ~/repos/ai-software-factory/.env.seed; neither is
# ever printed.
import json, re, subprocess, sys, time, urllib.error, urllib.request
from pathlib import Path

API = 'https://api.hetzner.cloud/v1'
ROOT = Path(__file__).resolve().parent.parent
SEED = Path.home() / 'repos/ai-software-factory'
NODES = {'sf-0': '10.0.1.10', 'sf-1': '10.0.1.11', 'sf-2': '10.0.1.12'}
PREFIX = 'factory-off-'  # factory-on takes the newest snapshot per node

tok = re.search(r'hcloud_token\s*=\s*"([^"]+)"',
                (ROOT / 'terraform.tfvars').read_text()).group(1)


def run(args, **kw):
    r = subprocess.run(args, capture_output=True, text=True, **kw)
    if r.returncode:
        sys.exit(f"{' '.join(args[:4])}... failed: {(r.stderr or r.stdout).strip()[:300]}")
    return r.stdout.strip()


def api(method, path, body=None):
    headers = {'Authorization': 'Bearer ' + tok}
    data = None
    if body is not None:
        headers['Content-Type'] = 'application/json'  # without it Hetzner reads form data
        data = json.dumps(body).encode()
    req = urllib.request.Request(API + path, method=method, headers=headers, data=data)
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        sys.exit(f'{method} {path}: HTTP {e.code} {e.read().decode()[:300]}')


def wait_action(action, timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        a = api('GET', f"/actions/{action['id']}")['action']
        if a['status'] == 'success':
            return
        if a['status'] == 'error':
            sys.exit(f"action {a['command']} failed: {a['error']}")
        time.sleep(10)
    sys.exit(f"action {action['command']} timed out")


def env_file_vars(path):
    out = {}
    for line in path.read_text().splitlines():
        m = re.match(r'^([A-Z0-9_]+)=(.*)$', line)
        if m:
            out[m.group(1)] = m.group(2).strip()
    return out


def unseal_openbao(timeout):
    status = ['kubectl', '-n', 'platform', 'exec', 'openbao-0', '--', 'bao', 'status', '-format=json']
    t0 = time.time()
    while (r := subprocess.run(status, capture_output=True, text=True)).returncode not in (0, 2):
        if time.time() - t0 > timeout:  # bao status exits 0 unsealed, 2 sealed, 1 on error
            sys.exit(f'OpenBao does not answer: {(r.stderr or r.stdout).strip()[:300]}')
        time.sleep(10)
    if not json.loads(r.stdout)['sealed']:
        return
    key = env_file_vars(SEED / '.env.seed')['OPENBAO_UNSEAL_KEY']
    key += '=' * (-len(key) % 4)  # the seed file keeps it unpadded
    out = run(['kubectl', 'exec', '-i', '-n', 'platform', 'openbao-0', '--', 'sh', '-c',
               'k="$(cat)"; bao operator unseal -format=json "$k"'], input=key)
    if json.loads(out)['sealed']:
        sys.exit('OpenBao is still sealed after the unseal')
    print('OpenBao unsealed', flush=True)
