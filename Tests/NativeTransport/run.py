#!/usr/bin/env python3
"""Exercise the rebuilt static transport against a disposable loopback sshd."""
import getpass, pathlib, socket, subprocess, tempfile, time
root = pathlib.Path(__file__).resolve().parents[2]
framework = root / 'app/vendor/CSSH/CSSH.xcframework'
libs = list(framework.glob('macos-*/libssh2.a'))
assert len(libs) == 1, 'Build the Apple native libraries first'
with tempfile.TemporaryDirectory(prefix='bsns-native-') as directory:
    work = pathlib.Path(directory)
    for name, kind in [('host', 'ed25519'), ('client', 'ed25519'), ('ecdsa', 'ecdsa')]:
        subprocess.run(['ssh-keygen','-q','-t',kind,'-N','','-f',str(work/name)],check=True)
    (work/'authorized_keys').write_text((work/'client.pub').read_text() + (work/'ecdsa.pub').read_text())
    with socket.socket() as probe:
        probe.bind(('127.0.0.1',0))
        port = probe.getsockname()[1]
    config = work/'sshd_config'
    config.write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {work}/host
PidFile {work}/sshd.pid
AuthorizedKeysFile {work}/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers {getpass.getuser()}
Subsystem sftp internal-sftp
''')
    executable = work/'smoke'
    subprocess.run(['xcrun','clang','-I',str(libs[0].parent/'Headers'),str(pathlib.Path(__file__).with_name('smoke.c')),str(libs[0]),'-lz','-framework','Security','-o',str(executable)],check=True)
    with (work/'sshd.log').open('w+') as log:
        server = subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(config)],stdout=log,stderr=log)
        try:
            for attempt in range(50):
                if server.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(log.read())
                try:
                    with socket.create_connection(('127.0.0.1',port),timeout=.2): break
                except OSError: time.sleep(.1)
            for key in ['client', 'ecdsa']:
                print(f'Testing {key} authentication', flush=True)
                result = subprocess.run([str(executable),str(port),getpass.getuser(),str(work/(key+'.pub')),str(work/key),str(work)],timeout=30)
                if result.returncode:
                    log.seek(0)
                    print(log.read())
                    raise SystemExit(result.returncode)
        finally:
            server.terminate()
            server.wait(timeout=10)
