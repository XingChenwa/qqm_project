import base64
import json
import os
from pathlib import Path
import tempfile
import subprocess
import sys
import io
import wave
from unittest.mock import patch
import unittest
from fastapi.testclient import TestClient
from service import create_app
from pipeline import inside, music_download_url, import_qq_music
from music import search_qq_music, selected_index


class LocalServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp_parent = Path(os.environ.get("TEMP", tempfile.gettempdir())).resolve()
        self.temp = tempfile.TemporaryDirectory(prefix="qqm-rvc-service-test-", dir=self.temp_parent)
        self.root = Path(self.temp.name).resolve()
        (self.root / "config.json").write_text(json.dumps({"instanceId":"fixture", "ffmpeg":"C:/ffmpeg/bin/ffmpeg.exe"}), encoding="utf-8")
        self.app = create_app(self.root)
        self.service = self.app.state.cover
        self.client = TestClient(self.app, base_url="http://127.0.0.1:23339")
        self.headers = {"X-QQM-Cover":"1"}

    def tearDown(self):
        self.client.close()
        self.assertEqual(self.root.parent, self.temp_parent)
        self.assertTrue(self.root.name.startswith("qqm-rvc-service-test-"))
        self.temp.cleanup()

    def call(self, action, args=None, scope="fixture-account-and-chat", caller=None):
        return self.client.post("/api/tool", json={"action":action,"args":args or {},"scope":scope,"caller":caller}, headers=self.headers)

    def caller(self, message="ask-1", text="唱一下唯一", user="asker-1"):
        return {"id":user,"messageId":message,"name":"原提问者","text":text}

    def candidates(self):
        return [{"mid":"001NgljR0RUhy1","name":"唯一","singer":"G.E.M.邓紫棋"},
                {"mid":"0023jgxa0Ym5yo","name":"唯一","singer":"告五人"},
                {"mid":"0031tvqb2vMdXU","name":"唯一 (Live)","singer":"王力宏"}]

    def search(self, candidates=None):
        with patch("service.search_qq_music",return_value=self.candidates() if candidates is None else candidates):
            return self.call("search_qq",{"query":"唯一"},caller=self.caller()).json()

    def test_health_truthfully_reports_no_voice_model(self):
        response = self.call("health")
        self.assertEqual(response.status_code,200)
        data = response.json()
        self.assertFalse(data["canCover"])
        self.assertTrue(any("音色" in item for item in data["missing"]))
        result = self.call("start", {"song":"missing","model":"missing"}).json()
        self.assertTrue(result["isError"])
        self.assertEqual(self.service.jobs,{})

    def test_origin_host_header_and_methods_guard(self):
        self.assertEqual(self.client.post("/api/tool",json={"action":"health"}).status_code,403)
        self.assertEqual(self.client.post("/api/tool",json={},headers={**self.headers,"Origin":"https://untrusted.fixture.test"}).status_code,403)
        self.assertEqual(self.client.get("/api/health",headers={"Host":"untrusted.fixture.test:23339"}).status_code,403)
        self.assertEqual(self.client.options("/api/tool").status_code,405)
        response = self.client.get("/api/health")
        self.assertNotIn("access-control-allow-origin",response.headers)

    def test_upload_stays_in_library_and_refuses_overwrite(self):
        response = self.client.post("/api/upload?kind=models",files={"file":("../../voice.pth",b"fixture-model-content")},headers=self.headers)
        self.assertEqual(response.status_code,200)
        self.assertEqual((self.root/"models"/"voice.pth").read_bytes(),b"fixture-model-content")
        again = self.client.post("/api/upload?kind=models",files={"file":("voice.pth",b"replacement-content")},headers=self.headers)
        self.assertEqual(again.status_code,409)
        self.assertEqual((self.root/"models"/"voice.pth").read_bytes(),b"fixture-model-content")
        self.assertFalse((self.root/"voice.pth").exists())
        bad = self.client.post("/api/upload?kind=models",files={"file":("malicious.py",b"not-a-model-file")},headers=self.headers)
        self.assertEqual(bad.status_code,400)

    def test_scope_checks_for_status_audio_and_cancel(self):
        job={"id":"a"*32,"scope":self.service.scope("other-account"),"status":"completed","stage":"completed","song":"fixture","model":"fixture"}
        self.service.jobs[job["id"]]=job
        for action in ("status","audio","cancel"):
            data=self.call(action,{"job_id":job["id"]}).json()
            self.assertTrue(data["isError"])
            self.assertNotIn("audioBase64",data)
        self.assertEqual(job["status"],"completed")
        result=self.call("status",{"job_id":job["id"]},scope="other-account").json()
        self.assertEqual(result["job"]["id"],job["id"])

    def test_failed_and_running_jobs_cannot_return_audio(self):
        for status in ("failed","running","queued","cancelled"):
            job={"id":"b"*32,"scope":self.service.scope("fixture-account-and-chat"),"status":status,"stage":status}
            self.service.jobs[job["id"]]=job
            result=self.call("audio",{"job_id":job["id"]}).json()
            self.assertTrue(result["isError"])
            self.assertNotIn("audioBase64",result)

    def test_restart_stops_stale_jobs_and_path_traversal_is_rejected(self):
        folder=self.root/"jobs"/("c"*32);folder.mkdir()
        job={"id":"c"*32,"scope":self.service.scope("fixture-account-and-chat"),"status":"running","stage":"converting"}
        (folder/"state.json").write_text(json.dumps(job),encoding="utf-8")
        restarted=create_app(self.root).state.cover
        self.assertEqual(restarted.jobs[job["id"]]["status"],"failed")
        with self.assertRaises(ValueError):
            inside(self.root/"outputs","../../outside-private")
        self.assertEqual(self.client.get("/audio/not-an-id/clip.mp3").status_code,404)

    def test_cancel_waits_for_owned_process_to_stop(self):
        process = subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"],
                                   creationflags=getattr(subprocess,"CREATE_NO_WINDOW",0),
                                   start_new_session=os.name!="nt")
        job={"id":"d"*32,"scope":self.service.scope("fixture-account-and-chat"),"status":"running","stage":"converting"}
        self.service.jobs[job["id"]]=job
        self.service.processes[job["id"]]=process
        try:
            result=self.call("cancel",{"job_id":job["id"]}).json()
            self.assertTrue(result["ok"])
            self.assertIsNotNone(process.poll())
            self.assertEqual(job["status"],"cancelled")
        finally:
            if process.poll() is None:
                process.kill();process.wait(timeout=5)

    def test_music_input_and_download_contract_stays_on_documented_route(self):
        self.assertEqual(self.service.song_mid("https://y.qq.com/n/ryqq/songDetail/0039MnYb0qxYhV"),"0039MnYb0qxYhV")
        self.assertEqual(self.service.song_mid("https://y.qq.com/n/yqq/song/0039MnYb0qxYhV.html"),"0039MnYb0qxYhV")
        self.assertEqual(self.service.song_mid("https://i.y.qq.com/a?songmid=0039MnYb0qxYhV"),"0039MnYb0qxYhV")
        for value in ("歌名", "https://private.fixture.test/songDetail/0039MnYb0qxYhV", "../../etc/passwd"):
            with self.assertRaises(ValueError): self.service.song_mid(value)
        self.assertEqual(music_download_url({"data":{"download_url":"/qmmer/file/fixture.mp3"}}),"https://api.avbvcv.xyz/qmmer/file/fixture.mp3")
        for url in ("http://api.avbvcv.xyz/qmmer/file/a", "https://127.0.0.1/qmmer/file/a", "https://api.avbvcv.xyz/private", "https://other.fixture.test/audio.mp3"):
            with self.assertRaises(ValueError): music_download_url({"download_url":url})

    def test_downloaded_original_cannot_be_sent_as_cover(self):
        job={"id":"e"*32,"scope":self.service.scope("fixture-account-and-chat"),"status":"completed","stage":"completed","type":"import"}
        self.service.jobs[job["id"]]=job
        result=self.call("audio",{"job_id":job["id"]}).json()
        self.assertTrue(result["isError"])
        self.assertNotIn("audioBase64",result)

    def test_qq_import_contract_uses_fixed_api_and_real_audio_decoding(self):
        buffer=io.BytesIO()
        with wave.open(buffer,"wb") as output:
            output.setnchannels(1);output.setsampwidth(2);output.setframerate(16000)
            output.writeframes(b"\x00\x00"*3200)
        class Reply:
            status_code=200
            def __init__(self,data):self.data=data;self.headers={"Content-Length":str(len(data))}
            def __enter__(self):return self
            def __exit__(self,*args):return False
            def iter_content(self,size):yield self.data
        class Session:
            trust_env=True
            def post(self,url,**kwargs):
                self.post_url=url;self.body=kwargs["json"]
                return Reply(json.dumps({"code":0,"data":{"download_url":"/qmmer/file/fixture.wav"}}).encode())
            def get(self,url,**kwargs):
                self.get_url=url
                return Reply(buffer.getvalue())
        session=Session();job={"id":"f"*32,"mid":"00000000000000","song_file":"fixture-import.mp3"}
        (self.root/"jobs"/job["id"]).mkdir()
        with patch("requests.Session",return_value=session):
            import_qq_music(self.root,job)
        self.assertFalse(session.trust_env)
        self.assertEqual(session.post_url,"https://api.avbvcv.xyz/")
        self.assertEqual(session.body,{"action":"qm_song_download","mid":"00000000000000"})
        self.assertEqual(session.get_url,"https://api.avbvcv.xyz/qmmer/file/fixture.wav")
        self.assertGreater((self.root/"songs"/job["song_file"]).stat().st_size,100)
        self.assertEqual(self.service.library("models"),[])

    def test_multiple_versions_are_only_listed_never_downloaded(self):
        with patch.object(self.service,"import_music") as download:
            result=self.search()
            self.assertEqual(result["status"],"needs_selection")
            self.assertEqual([row["number"] for row in result["candidates"]],[1,2,3])
            self.assertIn("原提问者",result["message"])
            self.assertIn("王力宏",result["message"])
            self.assertIn("Live",result["message"])
            self.assertEqual(self.service.jobs,{})
            download.assert_not_called()

    def test_same_turn_model_args_cannot_choose_or_bypass_ambiguity(self):
        result=self.search()
        with patch.object(self.service,"import_music") as download, patch("service.search_qq_music") as upstream:
            select=self.call("select_qq",{"search_id":result["search_id"],"choice":2},caller=self.caller()).json()
            self.assertTrue(select["isError"])
            direct=self.call("import_qq",{"song":self.candidates()[1]["mid"]},caller=self.caller()).json()
            self.assertTrue(direct["isError"])
            again=self.call("search_qq",{"query":"唯一 告五人"},caller=self.caller()).json()
            self.assertEqual(again["search_id"],result["search_id"])
            download.assert_not_called();upstream.assert_not_called()

    def test_real_new_message_selects_same_asker_version_exactly_once(self):
        result=self.search();caller=self.caller("ask-2","选2")
        with patch.object(self.service,"import_music",return_value={"ok":True,"message":"fixture queued"}) as download:
            selected=self.call("select_qq",{"search_id":result["search_id"]},caller=caller).json()
            self.assertTrue(selected["ok"])
            self.assertEqual(selected["selected"]["singer"],"告五人")
            download.assert_called_once_with({"song":"0023jgxa0Ym5yo"},self.service.scope("fixture-account-and-chat"))
            repeated=self.call("select_qq",{"search_id":result["search_id"]},caller=caller).json()
            self.assertEqual(repeated,selected)
            self.assertEqual(download.call_count,1)

    def test_next_turn_does_not_need_opaque_tool_result_in_chat_history(self):
        self.search()
        with patch.object(self.service,"import_music",return_value={"ok":True}) as download:
            result=self.call("select_qq",caller=self.caller("ask-2","告五人")).json()
            self.assertEqual(result["selected"]["singer"],"告五人")
            download.assert_called_once()

    def test_another_user_or_chat_cannot_choose_original_request(self):
        result=self.search()
        with patch.object(self.service,"import_music") as download:
            for kwargs in ({"caller":self.caller("other-1","选1","another-user")},
                           {"scope":"another-account-or-chat","caller":self.caller("ask-2","选1")}):
                response=self.call("select_qq",{"search_id":result["search_id"]},**kwargs).json()
                self.assertTrue(response["isError"])
            download.assert_not_called()

    def test_unclear_negative_invalid_and_stale_selection_never_download(self):
        result=self.search()
        with patch.object(self.service,"import_music") as download:
            for text in ("随便", "选8", "不要告五人", "告五人还是王力宏", "要告五人吗？"):
                self.assertTrue(self.call("select_qq",{"search_id":result["search_id"]},caller=self.caller("ask-2",text)).json()["isError"])
            self.assertTrue(self.call("select_qq",{"search_id":"stale"},caller=self.caller("ask-2","选1")).json()["isError"])
            for entry in self.service.searches.values():entry["expires"]=0
            self.assertTrue(self.call("select_qq",{"search_id":result["search_id"]},caller=self.caller("ask-2","选1")).json()["isError"])
            download.assert_not_called()

    def test_wrong_mid_does_not_start_any_download_before_validation(self):
        self.search()
        with patch.object(self.service,"import_music") as download:
            result=self.call("import_qq",{"song":self.candidates()[0]["mid"]},caller=self.caller("ask-2","选2")).json()
            self.assertTrue(result["isError"])
            download.assert_not_called()

    def test_choice_is_not_lost_if_model_searches_again(self):
        result=self.search()
        with patch("service.search_qq_music") as upstream:
            repeated=self.call("search_qq",{"query":"唯一"},caller=self.caller("ask-2","选2")).json()
            self.assertEqual(repeated["search_id"],result["search_id"])
            upstream.assert_not_called()

    def test_single_candidate_and_explicit_user_link_can_be_imported(self):
        result=self.search([self.candidates()[0]])
        with patch.object(self.service,"import_music",return_value={"ok":True}) as download:
            self.assertTrue(self.call("select_qq",{"search_id":result["search_id"]},caller=self.caller()).json()["ok"])
            download.assert_called_once()
        with patch.object(self.service,"import_music",return_value={"ok":True}) as download:
            url="https://y.qq.com/n/ryqq/songDetail/0023jgxa0Ym5yo"
            self.assertTrue(self.call("import_qq",{"song":url},caller=self.caller("ask-2","唱这首 "+url)).json()["ok"])
            download.assert_called_once()

    def test_missing_current_caller_does_not_download_and_desktop_choice_is_explicit(self):
        with patch.object(self.service,"import_music") as download:
            self.assertTrue(self.call("import_qq",{"song":self.candidates()[0]["mid"]}).json()["isError"])
            download.assert_not_called()
        with patch("service.search_qq_music",return_value=self.candidates()):
            result=self.call("search_qq",{"query":"唯一"},scope="desktop").json()
        with patch.object(self.service,"import_music",return_value={"ok":True}) as download:
            self.assertTrue(self.call("select_qq",{"search_id":result["search_id"]},scope="desktop").json()["isError"])
            self.assertTrue(self.call("select_qq",{"search_id":result["search_id"],"choice":3},scope="desktop").json()["ok"])
            download.assert_called_once_with({"song":"0031tvqb2vMdXU"},self.service.scope("desktop"))

    def test_no_results_clears_previous_list_instead_of_selecting_old_song(self):
        result=self.search()
        with patch("service.search_qq_music",return_value=[]):
            empty=self.call("search_qq",{"query":"无此歌"},caller=self.caller("ask-2","搜无此歌")).json()
        self.assertEqual(empty["status"],"not_found")
        self.assertTrue(self.call("select_qq",{"search_id":result["search_id"]},caller=self.caller("ask-3","选1")).json()["isError"])

    def test_singer_or_number_selection_is_unambiguous(self):
        choices=self.candidates()
        for text,index in (("选2",1),("第二个",1),("告五人",1),("用告五人版",1),("邓紫棋",0),("我想听邓紫棋版",0),("<qqbot-at-user id=\"bot\" /> 选3",2)):
            self.assertEqual(selected_index(text,choices),index)
        same_singer=[{**choices[1],"name":"唯一"},{**choices[1],"name":"唯一 (Live)"}]
        self.assertIsNone(selected_index("告五人",same_singer))

    def test_official_search_parses_only_songs_and_keeps_live_versions(self):
        payload=json.dumps({"code":0,"subcode":0,"data":{"song":{"itemlist":[
            *self.candidates(),{"mid":"0042khAn0far01","name":"唯一的偏爱","singer":"其他"},
            {"mid":"../../private","name":"唯一","singer":"bad"}]},"album":{"itemlist":[{"mid":"album-only"}]}}}).encode()
        class Reply:
            status_code=200
            def __enter__(self):return self
            def __exit__(self,*args):return False
            def iter_content(self,size):yield payload
        class Session:
            trust_env=True
            def __enter__(self):return self
            def __exit__(self,*args):return False
            def get(self,url,**kwargs):self.url=url;self.kwargs=kwargs;return Reply()
        session=Session()
        with patch("music.requests.Session",return_value=session):
            choices=search_qq_music("唯一")
        self.assertFalse(session.trust_env)
        self.assertEqual(session.url,"https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg")
        self.assertEqual(session.kwargs["params"],{"format":"json","key":"唯一"})
        self.assertFalse(session.kwargs["allow_redirects"])
        self.assertEqual(len(choices),3)
        self.assertEqual(choices[-1]["name"],"唯一 (Live)")
        self.assertTrue(all(row["url"].startswith("https://y.qq.com/n/ryqq/songDetail/") for row in choices))


if __name__ == "__main__":
    unittest.main(verbosity=2)
