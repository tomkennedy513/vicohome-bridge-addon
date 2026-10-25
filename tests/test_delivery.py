import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.data = Path(self.tmp.name)
        self.log = self.data / 'mqtt'
        self.shell('init_event_store')

    def shell(self, command, events=None, fail=''):
        (self.data / 'input').write_text(json.dumps(events or []))
        script = r'''
source "$ROOT/vicohome_bridge/run.sh"
bashio::log.warning() { echo "$*" >&2; }
bashio::log.debug() { :; }
bashio::log.info() { :; }
ensure_discovery_published() { return 0; }
mqtt_publish() {
 python3 -c 'import json,os,sys; open(os.environ["LOG"],"a").write(json.dumps(sys.argv[1:])+"\n")' "$@"
 [[ "$*" != *"$FAIL"* || -z "$FAIL" ]]
}
DATA_DIR="$DATA"; BASE_TOPIC=vicohome; MQTT_ARGS=(); POLL_INTERVAL=60
BRIDGE_NOW=2000000000
init_event_store || exit 1
''' + command
        env = dict(os.environ, ROOT=str(ROOT), DATA=str(self.data), LOG=str(self.log), FAIL=fail)
        return subprocess.run(['bash', '-c', script], env=env, text=True, capture_output=True)

    def batch(self, events, mode='live', fail=''):
        result=self.shell('process_events "$(cat "$DATA/input")" '+mode, events, fail)
        self.assertEqual(result.returncode,0,result.stderr)
        return self.messages()

    def messages(self):
        rows=[json.loads(x) for x in self.log.read_text().splitlines()] if self.log.exists() else []
        return [(r[r.index('-t')+1],r[r.index('-m')+1]) for r in rows]

    def event(self, n, camera='A', ts=None):
        return dict(traceId=str(n), serialNumber=camera, timestamp=ts or 2000000000+n, eventType='motion')

    def test_initial_latest_per_camera_and_restart(self):
        old=[self.event(i,c,1999999900+i) for c in ['A','B'] for i in range(10)]
        self.batch(old[::-1])
        states=[json.loads(p) for t,p in self.messages() if t.endswith('/state')]
        self.assertEqual([(x['serialNumber'],x['traceId']) for x in states],[('A','9'),('B','9')])
        self.assertFalse(any(t.endswith(('/events','/motion')) for t,p in self.messages()))
        before=len(self.messages());self.batch(old)
        self.assertEqual(len(self.messages()),before)

    def test_order_multiple_cameras_and_no_replay(self):
        events=[self.event(3),self.event(2,'B'),self.event(1)]
        self.batch(events)
        sent=[json.loads(p)['traceId'] for t,p in self.messages() if t.endswith('/events')]
        self.assertEqual(sent,['1','2','3'])
        before=len(self.messages());self.batch(events)
        self.assertEqual(len(self.messages()),before)

    def test_large_backlog_bounded_and_drains(self):
        events=[self.event(i) for i in range(1,151)]
        self.batch(events[::-1]);self.assertEqual(sum(t.endswith('/events') for t,p in self.messages()),60)
        self.batch(events);self.batch(events)
        self.assertEqual(sum(t.endswith('/events') for t,p in self.messages()),150)
        self.batch(events);self.assertEqual(sum(t.endswith('/events') for t,p in self.messages()),150)

    def test_failed_publication_retryable(self):
        self.batch([self.event(1)],fail='/state')
        ledger=json.loads((self.data/'delivery.json').read_text())
        self.assertEqual(ledger['seen'],{})
        self.batch([self.event(1)])
        self.assertEqual(len(json.loads((self.data/'delivery.json').read_text())['seen']),1)

    def test_failed_initial_state_retryable(self):
        old=[self.event(1,ts=1999999900)]
        self.batch(old,fail='/state');self.batch(old)
        self.assertEqual(sum(t.endswith('/state') for t,p in self.messages()),2)
        self.assertFalse(any(t.endswith('/motion') for t,p in self.messages()))

    def test_empty_malformed_and_missing_fields(self):
        self.batch([]);self.batch([{},None,'bad',{'serialNumber':'A'}])
        result=self.shell('process_events "broken" live; process_events "[]" live')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.messages(),[])
        event=self.event(1);del event['eventType'];self.batch([event])
        self.assertFalse(any(t.endswith('/motion') for t,p in self.messages()))

    def test_late_event_does_not_regress_state(self):
        self.batch([self.event(3)]);self.batch([self.event(1)])
        states=[json.loads(p)['traceId'] for t,p in self.messages() if t.endswith('/state')]
        self.assertEqual(states,['3'])

    def test_bootstrap_bounded_no_motion(self):
        self.batch([self.event(i,c,1999999900+i) for c in ['A','B'] for i in range(80)],'history')
        self.assertEqual(sum(t.endswith('/state') for t,p in self.messages()),2)
        self.assertFalse(any(t.endswith(('/events','/motion')) for t,p in self.messages()))

    def test_history_more_than_batch_limit_cameras(self):
        events=[self.event(1,'camera'+str(i),1999999900) for i in range(65)]
        self.batch(events,'history')
        self.assertEqual(sum(t.endswith('/state') for t,p in self.messages()),60)
        self.batch(events,'history')
        self.assertEqual(sum(t.endswith('/state') for t,p in self.messages()),65)

    def test_same_timestamp_and_ids_are_scoped_to_camera(self):
        events=[self.event(1,c,2000000001) for c in ['A','B']]+[self.event(2,'A',2000000001)]
        self.batch(events);before=len(self.messages());self.batch(events[::-1])
        self.assertEqual(before,len(self.messages()))
        self.assertEqual(sum(t.endswith('/events') for t,p in self.messages()),3)

    def test_expired_ids_cannot_replay_after_pruning(self):
        self.batch([self.event(1)])
        result=self.shell('BRIDGE_NOW=2000600000; process_events "$(cat "$DATA/input")" live',[self.event(1),self.event(2,ts=2000600000)])
        self.assertEqual(result.returncode,0,result.stderr)
        ledger=json.loads((self.data/'delivery.json').read_text())
        self.assertEqual(len(ledger['seen']),1)
        self.assertEqual(sum(t.endswith('/events') for t,p in self.messages()),2)

    def test_empty_trace_ids_use_stable_fallback(self):
        events=[dict(self.event(i),traceId='') for i in [1,2]]
        self.batch(events)
        self.batch([dict(self.event(3),traceId='')])
        sent=[json.loads(p)['timestamp'] for t,p in self.messages() if t.endswith('/events')]
        self.assertEqual(sent,[2000000001,2000000002,2000000003])
        before=len(self.messages());self.batch(events)
        self.assertEqual(len(self.messages()),before)

    def test_large_persistent_ledger_does_not_hit_argv_limit(self):
        path=self.data/'delivery.json';ledger=json.loads(path.read_text())
        ledger['seen']={json.dumps(['A','old-event-'+str(i)]):2000000000 for i in range(50000)}
        path.write_text(json.dumps(ledger))
        self.batch([self.event(1)])
        self.assertEqual(sum(t.endswith('/events') for t,p in self.messages()),1)

    def test_nested_ledger_corruption_fails_closed(self):
        path=self.data/'delivery.json';original=json.loads(path.read_text())
        for field,value in [('seen',{'key':None}),('latest',{'A':{'ts':None,'key':'id'}}),('motion',{'A':'bad'}),('images',{'A':{'ts':2000000000,'key':'id','url':None}})]:
            ledger=dict(original);ledger[field]=value;path.write_text(json.dumps(ledger))
            self.assertNotEqual(self.shell('init_event_store').returncode,0,field)
        self.assertEqual(self.messages(),[])

    def images(self,events,fail=''):
        result=self.shell('publish_latest_images "$(cat "$DATA/input")"',events,fail)
        self.assertEqual(result.returncode,0,result.stderr)
        return [(t,p) for t,p in self.messages() if t.endswith('/image/url')]

    def test_image_latest_per_camera_and_restart(self):
        events=[dict(self.event(i,c),imageUrl='https://example.invalid/'+c+str(i)+'.jpg') for c in ['A','B'] for i in [1,2]]
        self.images(events[::-1])
        self.assertEqual(self.messages(),[('vicohome/a/image/url','https://example.invalid/A2.jpg'),('vicohome/b/image/url','https://example.invalid/B2.jpg')])
        self.images(events)
        self.assertEqual(len(self.messages()),2)

    def test_image_primary_keyshot_fallback_and_missing(self):
        events=[dict(self.event(1,'A'),imageUrl='https://example.invalid/primary.jpg',keyShotUrl='https://example.invalid/key.jpg'),dict(self.event(1,'B'),imageUrl='',keyShotUrl='https://example.invalid/key.jpg'),self.event(1,'C'),dict(self.event(1,'D'),imageUrl='javascript:bad')]
        self.images(events)
        self.assertEqual(self.messages(),[('vicohome/a/image/url','https://example.invalid/primary.jpg'),('vicohome/b/image/url','https://example.invalid/key.jpg')])

    def test_image_seen_events_seed_without_motion_replay(self):
        events=[dict(self.event(1),imageUrl='https://example.invalid/bird.jpg')]
        self.batch(events);self.log.unlink()
        self.images(events)
        self.assertEqual(self.messages(),[('vicohome/a/image/url','https://example.invalid/bird.jpg')])

    def test_image_failure_is_retryable(self):
        events=[dict(self.event(1),imageUrl='https://example.invalid/bird.jpg')]
        self.images(events,fail='/image/url')
        self.assertEqual(json.loads((self.data/'delivery.json').read_text()).get('images',{}),{})
        self.images(events)
        self.assertEqual(len(self.messages()),2)
        self.assertEqual(json.loads((self.data/'delivery.json').read_text())['images']['A']['url'],'https://example.invalid/bird.jpg')

    def test_image_history_cannot_regress_newer_image(self):
        self.images([dict(self.event(3),imageUrl='https://example.invalid/new.jpg')])
        self.images([dict(self.event(1,ts=1999999900),imageUrl='https://example.invalid/old.jpg')])
        self.assertEqual(len(self.messages()),1)

    def test_image_rotated_url_refreshes_same_seen_event(self):
        self.images([dict(self.event(1),imageUrl='https://example.invalid/bird.jpg?sig=old')])
        self.images([dict(self.event(1),imageUrl='https://example.invalid/bird.jpg?sig=new')])
        self.assertEqual(len(self.messages()),2)
        self.assertTrue(self.messages()[-1][1].endswith('sig=new'))

    def test_image_backlog_is_bounded_and_drains(self):
        events=[dict(self.event(1,'camera'+str(i)),imageUrl='https://example.invalid/'+str(i)+'.jpg') for i in range(65)]
        self.images(events);self.assertEqual(len(self.messages()),60)
        self.images(events);self.assertEqual(len(self.messages()),65)

    def test_history_image_failure_remains_retryable(self):
        cli=self.data/'history-cli'
        cli.write_text('#!/bin/bash\nif [[ "$*" == *--startTime* ]]; then cat "'+str(self.data/'input')+'"; else echo "[]"; fi\n')
        cli.chmod(0o755)
        events=[dict(self.event(1,ts=1999999900),imageUrl='https://example.invalid/history.jpg')]
        cmd='VICO_CLI="$DATA/history-cli"; BOOTSTRAP_HISTORY=true; fetch_events live'
        result=self.shell(cmd,events,fail='/image/url')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse(json.loads((self.data/'delivery.json').read_text()).get('history_complete',False))
        result=self.shell(cmd,events)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(json.loads((self.data/'delivery.json').read_text())['history_complete'])
        self.assertEqual(sum(t.endswith('/image/url') for t,p in self.messages()),2)

    def test_corrupt_store_fails_closed(self):
        (self.data/'delivery.json').write_text('broken')
        self.assertNotEqual(self.shell('init_event_store').returncode,0)
        self.assertEqual(self.messages(),[])

    def test_motion_reset_and_stale_events(self):
        self.batch([self.event(1)])
        result=self.shell('BRIDGE_NOW=2000000010; reset_motion')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn(('vicohome/a/motion','OFF'),self.messages())
        self.assertEqual(json.loads((self.data/'delivery.json').read_text())['motion'],{})
        self.shell('BRIDGE_NOW=2000000500; process_events "$(cat "$DATA/input")" live',[self.event(2)])
        self.assertEqual(sum(p=='ON' for t,p in self.messages()),1)

    def test_bootstrap_arguments_and_cli_failures(self):
        cli=self.data/'cli'
        cli.write_text('#!/bin/bash\nprintf "%s\\n" "$@" >> "'+str(self.data/'args')+'"\necho "${RESPONSE:-[]}"\nexit "${STATUS:-0}"\n')
        cli.chmod(0o755)
        command='VICO_CLI="$DATA/cli"; BOOTSTRAP_HISTORY=true; fetch_events live'
        result=self.shell(command)
        self.assertEqual(result.returncode,0,result.stderr)
        args=(self.data/'args').read_text()
        self.assertIn('--startTime',args);self.assertIn('--endTime',args);self.assertNotIn('--since',args)
        self.assertTrue(json.loads((self.data/'delivery.json').read_text())['history_complete'])
        for response,status in [('bad',0),('[]',1),('null',0),('{"error":"auth"}',0)]:
            result=self.shell('export RESPONSE='+json.dumps(response)+'; export STATUS='+str(status)+'; '+command)
            self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(self.messages(),[])

if __name__=='__main__': unittest.main()
