import base64, json, os, pathlib, subprocess, sys, tempfile, unittest, uuid

HELPER = pathlib.Path(__file__).with_name('bsns-workspace')
class WorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.socket = 'bsns-test-' + uuid.uuid4().hex[:12]
        self.env = dict(os.environ, BSNS_WORKSPACE_CONFIG=self.temp.name, BSNS_WORKSPACE_SOCKET=self.socket)
        self.data = dict(id=str(uuid.uuid4()), name='Testing', sessionName='testing', path=self.temp.name,
                         hosts=[], windows=[dict(id=str(uuid.uuid4()), name='shell', index=0),
                                            dict(id=str(uuid.uuid4()), name='review', index=1, tool='review')])
        # Beside the workspace cache, not inside it — as on a real host.
        self.tools_dir = tempfile.TemporaryDirectory()
        self.tools = pathlib.Path(self.tools_dir.name) / 'tools.json'
        self.env['BSNS_WORKSPACE_TOOLS'] = str(self.tools)
    def tearDown(self):
        self.tm('kill-server', check=False)
        self.temp.cleanup()
        self.tools_dir.cleanup()
    def tm(self, *args, check=True):
        return subprocess.run(['/opt/homebrew/bin/tmux', '-L', self.socket, *args], text=True, capture_output=True, check=check).stdout.strip()
    def run_helper(self, *args, check=True):
        return subprocess.run([sys.executable, str(HELPER), *args], env=self.env, text=True, capture_output=True, check=check)
    def apply(self, check=True):
        return self.run_helper('apply', base64.b64encode(json.dumps(self.data).encode()).decode(), check=check)
    def test_repeat_and_reboot(self):
        self.apply()
        before = self.tm('list-panes','-a','-F','#{pane_pid}')
        self.apply()
        self.assertEqual(before, self.tm('list-panes','-a','-F','#{pane_pid}'))
        self.tm('kill-server')
        self.run_helper('up')
        self.assertEqual(self.tm('list-windows','-t','testing','-F','#{window_name}').splitlines(), ['shell','review'])
    def test_missing_and_temporary(self):
        self.apply()
        pid = self.tm('display-message','-p','-t','testing:0','#{pane_pid}')
        self.tm('kill-window','-t','testing:1')
        self.tm('new-window','-d','-t','testing:20','-n','scratch')
        self.run_helper('up')
        self.assertEqual(pid,self.tm('display-message','-p','-t','testing:0','#{pane_pid}'))
        self.assertIn('scratch',self.tm('list-windows','-t','testing','-F','#{window_name}'))
    def test_rename_keeps_process(self):
        self.apply()
        pid = self.tm('display-message','-p','-t','testing:1','#{pane_pid}')
        self.data['windows'][1]['name'] = 'review-new'
        self.apply()
        self.assertEqual(pid,self.tm('display-message','-p','-t','testing:1','#{pane_pid}'))
        self.assertEqual('review-new',self.tm('display-message','-p','-t','testing:1','#{window_name}'))
    def test_conflict_preserved(self):
        self.tm('new-session','-d','-s','testing','-n','unrelated')
        pid = self.tm('display-message','-p','-t','testing:0','#{pane_pid}')
        self.assertNotEqual(0,self.apply(check=False).returncode)
        self.assertEqual(pid,self.tm('display-message','-p','-t','testing:0','#{pane_pid}'))
    def test_invalid_never_runs(self):
        self.data['windows'][0]['name'] = '$(touch hacked)'
        self.assertNotEqual(0,self.apply(check=False).returncode)
        self.assertEqual([],list(pathlib.Path(self.temp.name).glob('*.json')))
    def test_stale_definition_does_not_undo_rename(self):
        self.data['modifiedAt'] = 20
        self.apply()
        self.data['modifiedAt'] = 10
        self.data['windows'][0]['name'] = 'old-name'
        self.apply()
        self.assertEqual('shell', self.tm('display-message','-p','-t','testing:0','#{window_name}'))
    def test_two_workspaces_cannot_own_one_session(self):
        self.apply()
        self.data['id'] = str(uuid.uuid4())
        self.assertNotEqual(0,self.apply(check=False).returncode)
    def test_missing_directory_does_not_create_session(self):
        self.data['path'] += '/missing'
        self.assertNotEqual(0,self.apply(check=False).returncode)
        self.assertEqual('',self.tm('list-sessions',check=False))
    def test_a_tool_is_a_label_defined_on_the_host(self):
        self.apply()
        # Used by a window but not defined here: reported, never guessed.
        missing = self.run_helper('doctor', 'Testing', check=False)
        self.assertNotEqual(0, missing.returncode)
        self.assertIn('tool "review"', missing.stderr)
        self.tools.write_text(json.dumps({'review': {'resume': ['true']}}))
        self.assertEqual(0, self.run_helper('doctor', 'Testing', check=False).returncode)
        self.assertIn('review', self.run_helper('list', 'Testing').stdout)
    def test_resume_runs_only_what_the_host_defines(self):
        self.apply()
        marker = pathlib.Path(self.temp.name) / 'ran'
        pane = self.tm('display-message', '-p', '-t', 'testing:1', '#{pane_id}')
        env = dict(self.env, TMUX_PANE=pane)
        undefined = subprocess.run([sys.executable, str(HELPER), 'resume'], env=env, text=True, capture_output=True)
        self.assertNotEqual(0, undefined.returncode)
        self.assertIn('No tool named "review"', undefined.stderr)
        self.tools.write_text(json.dumps({'review': {'resume': ['touch', str(marker)]}}))
        self.assertEqual(0, subprocess.run([sys.executable, str(HELPER), 'resume'], env=env).returncode)
        self.assertTrue(marker.exists())
        # A plain window has nothing to resume.
        shell = dict(self.env, TMUX_PANE=self.tm('display-message', '-p', '-t', 'testing:0', '#{pane_id}'))
        self.assertNotEqual(0, subprocess.run([sys.executable, str(HELPER), 'resume'], env=shell, capture_output=True).returncode)
    def test_the_fields_earlier_name_and_bad_labels(self):
        del self.data['windows'][1]['tool']
        self.data['windows'][1]['agent'] = 'review'
        self.apply()
        saved = json.loads(next(pathlib.Path(self.temp.name).glob('*-*.json')).read_text())
        self.assertEqual('review', saved['windows'][1].get('tool'))
        self.assertNotIn('agent', saved['windows'][1])
        self.data['windows'][1]['agent'] = 'rm -rf /'
        self.assertNotEqual(0, self.apply(check=False).returncode)
if __name__ == '__main__':
    unittest.main()
