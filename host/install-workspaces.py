#!/usr/bin/env python3
"""Install the host-side workspace helper and macOS login recovery."""
import argparse, datetime, json, os, pathlib, plistlib, shutil, subprocess, sys

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--definition', type=pathlib.Path, help='Workspace JSON to cache and add to the Mac app')
p.add_argument('--adopt-session', help='Explicitly adopt and rename existing windows by index')
args = p.parse_args()
home = pathlib.Path.home()
root = home / '.config/bsns-ssh/workspaces'
bin_dir = home / '.local/bin'
backup = root / ('backup-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
root.mkdir(parents=True, exist_ok=True)
bin_dir.mkdir(parents=True, exist_ok=True)
backup.mkdir()
def write(path, content, executable=False):
    if path.exists():
        shutil.copy2(path, backup / path.name)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content if isinstance(content, bytes) else content.encode())
    if executable:
        path.chmod(0o755)
helper = bin_dir / 'bsns-workspace'
source = pathlib.Path(__file__).with_name('bsns-workspace').read_text()
# Pin the interpreter used during installation; launchd has a minimal PATH.
source = '#!' + sys.executable + '\n' + source.split('\n', 1)[1]
write(helper, source, True)
dev = bin_dir / 'dev'
wrapper = '#!/bin/sh\nexec "$HOME/.local/bin/bsns-workspace" "$@"\n'
if dev.exists() and dev.read_text() != wrapper:
    raise SystemExit('An unrelated dev command exists; helper installed without replacing it')
write(dev, wrapper, True)
config = home / '.tmux.conf'
block = '''# BEGIN BSNS workspace defaults
set -g automatic-rename off
set -g allow-rename off
set -g renumber-windows off
set -g window-size latest
set -g history-limit 50000
# END BSNS workspace defaults
'''
old = config.read_text() if config.exists() else ''
if '# BEGIN BSNS workspace defaults' not in old:
    write(config, old + '\n' + block)
# Apply defaults to an already-running server without reloading unrelated config.
tmux_binary = shutil.which('tmux') or '/opt/homebrew/bin/tmux'
for key, value in [('automatic-rename', 'off'), ('allow-rename', 'off'),
                   ('renumber-windows', 'off'), ('window-size', 'latest'), ('history-limit', '50000')]:
    subprocess.run([tmux_binary, 'set-option', '-g', key, value],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
# Validate data before touching any live windows.
if args.definition:
    import runpy
    module = runpy.run_path(str(helper), run_name='bsns_workspace_library')
    data = module['validate'](json.loads(args.definition.read_text()))
    if args.adopt_session:
        if data['sessionName'] != args.adopt_session:
            raise SystemExit('Adoption session differs from workspace')
        tmux = shutil.which('tmux') or '/opt/homebrew/bin/tmux'
        def tm(*a):
            return subprocess.check_output([tmux, *a], text=True).strip()
        rows = tm('list-windows', '-t', '=' + args.adopt_session, '-F', '#{window_id}\t#{window_index}\t#{window_name}\t#{pane_current_path}').splitlines()
        (backup / 'windows-before.json').write_text(json.dumps(rows, indent=2))
        by_index = {int(r.split('\t')[1]): r.split('\t') for r in rows}
        for w in data['windows']:
            row = by_index.get(w['index'])
            expected = module['directory'](data, w)
            if row is None or row[3] != expected:
                raise SystemExit('Window directory changed; refusing adoption at index ' + str(w['index']))
        for w in data['windows']:
            wid = by_index[w['index']][0]
            tm('rename-window', '-t', wid, w['name'])
            tm('set-option', '-w', '-t', wid, '@bsns_workspace_id', w['id'])
            tm('set-option', '-w', '-t', wid, 'automatic-rename', 'off')
            tm('set-option', '-w', '-t', wid, 'allow-rename', 'off')
    import base64
    subprocess.run([str(helper), 'apply', base64.b64encode(json.dumps(data).encode()).decode()], check=True)
    app_file = home / 'Library/Application Support/cc.bsns.ssh.mac/workspaces.json'
    existing = json.loads(app_file.read_text()) if app_file.exists() else []
    existing = [w for w in existing if w['id'] != data['id']]
    existing.append(data)
    write(app_file, json.dumps(existing, indent=2) + '\n')
# launchd starts with a minimal PATH. Give the login job the one in use right now,
# so the tools this user can run from a shell are the ones it finds.
login_path = ':'.join(dict.fromkeys(
    [str(bin_dir)] + [p for p in os.environ.get('PATH', '').split(':') if p]
    + ['/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin']))
logdir = home / 'Library/Logs/bsns-ssh'
logdir.mkdir(parents=True, exist_ok=True)
agent = home / 'Library/LaunchAgents/cc.bsns.ssh.workspaces.plist'
plist = dict(Label='cc.bsns.ssh.workspaces', ProgramArguments=[str(helper), 'up'], RunAtLoad=True,
             EnvironmentVariables={'PATH': login_path},
             StandardOutPath=str(logdir / 'workspaces.log'), StandardErrorPath=str(logdir / 'workspaces-error.log'))
write(agent, plistlib.dumps(plist))
domain = 'gui/' + str(os.getuid())
subprocess.run(['launchctl', 'bootout', domain + '/cc.bsns.ssh.workspaces'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
subprocess.run(['launchctl', 'bootstrap', domain, str(agent)], check=True)
print('Installed host helper and login recovery. Backup: ' + str(backup))
