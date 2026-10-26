import json, os, pathlib, shutil, subprocess, tempfile, unittest
ROOT=pathlib.Path(__file__).resolve().parents[1]
class SetupTests(unittest.TestCase):
 def test_selection_and_defaults(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=pathlib.Path(tmp)
   for f in ['setup.sh','config.json.example']: shutil.copy(ROOT/f,p/f)
   (p/'discover.sh').write_text('''#!/bin/bash
api_init() { :; }
api_auth() { :; }
discover_ptz_cameras() { echo '[{"preset_count":3}]'; }
''')
   (p/'curl').write_text('''#!/bin/bash
while (( $# )); do
 if [[ "$1" == -o ]]; then shift; output=$1; fi
 shift
done
printf '%s' '{"data":[{"id":"first","reportedState":{"name":"Other"}},{"id":"second","reportedState":{"name":"UDM"}}]}' > "$output"
'''); (p/'curl').chmod(0o700)
   env=dict(os.environ,PATH=str(p)+':'+os.environ['PATH'])
   r=subprocess.run(['bash',str(p/'setup.sh')],input='1\ntest-key\n9\n2\ny\n',text=True,capture_output=True,env=env)
   self.assertEqual(r.returncode,0,r.stderr)
   c=json.loads((p/'config.json').read_text())
   self.assertEqual(c['console_id'],'second');self.assertTrue(c['defaults']['dynamic_auto_tracking']);self.assertEqual(c['camera_overrides'],{})
   self.assertNotIn('test-key',r.stdout+r.stderr)
   self.assertEqual((p/'config.json').stat().st_mode & 0o777,0o600)
   original=(p/'config.json').read_bytes()
   r=subprocess.run(['bash',str(p/'setup.sh')],input='y\n',text=True,capture_output=True,env=env)
   self.assertEqual(r.returncode,0,r.stderr);self.assertEqual(original,(p/'config.json').read_bytes())
 def test_local_credentials(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=pathlib.Path(tmp)
   for f in ['setup.sh','config.json.example']: shutil.copy(ROOT/f,p/f)
   (p/'discover.sh').write_text("api_init() { :; }\napi_auth() { :; }\ndiscover_ptz_cameras() { echo '[{\"preset_count\":2}]'; }\n")
   r=subprocess.run(['bash',str(p/'setup.sh')],input='2\nhttps://127.0.0.1\npatrol\nsecret-test\ny\n',text=True,capture_output=True)
   self.assertEqual(r.returncode,0,r.stderr)
   c=json.loads((p/'config.json').read_text())
   self.assertEqual(c['auth_mode'],'local');self.assertEqual(c['password'],'secret-test')
   self.assertNotIn('api_key',c);self.assertNotIn('secret-test',r.stdout+r.stderr)
if __name__=='__main__': unittest.main()
