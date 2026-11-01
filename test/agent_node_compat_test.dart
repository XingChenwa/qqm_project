import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/js_packages.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/store.dart';

import 'agent_js_packages_test.dart' show bundle;

class NodeHttpFixture extends AgentHttp {
  final calls = <Json>[];
  @override
  Future<({Uint8List bytes, int status, Map<String, String> headers})>
  fetchNodeBytes(
    Uri uri, {
    String method = 'GET',
    Map<String, String> headers = const {},
    Object? body,
    CancelToken? cancel,
    int maxBytes = 12 * 1024 * 1024,
    int timeoutSeconds = 15,
  }) async {
    calls.add({
      'uri': uri.toString(),
      'method': method,
      'headers': headers,
      'body': body,
    });
    if (uri.path == '/slow') {
      await cancel!.whenCancel;
      throw const AgentException('请求已取消。');
    }
    if (uri.path == '/fail') throw const AgentException('模拟连接失败。');
    return (
      bytes: Uint8List.fromList(
        utf8.encode(
          uri.path == '/large'
              ? List.filled(20000, '中文🙂').join()
              : uri.path == '/redirect'
              ? ''
              : '你好，语音',
        ),
      ),
      status: uri.path == '/redirect' ? 302 : 200,
      headers: {
        'content-type': 'text/plain; charset=utf-8',
        if (uri.path == '/redirect') 'location': 'http://127.0.0.1/private',
      },
    );
  }
}

void main() {
  test('Node HTTP 仍拒绝本地、保留地址、凭证和非HTTP协议，旧fetch仍只支持HTTPS', () async {
    final http = AgentHttp();
    try {
      for (final url in [
        'http://127.0.0.1/x',
        'http://[::1]/x',
        'http://192.168.1.1/x',
        'http://169.254.169.254/x',
        'http://198.18.0.1/x',
        'http://user:pass@example.com/x',
        'file:///tmp/x',
        'http://example.com/x#fragment',
      ]) {
        await expectLater(
          http.fetchNodeBytes(Uri.parse(url)),
          throwsA(isA<AgentException>()),
        );
      }
      await expectLater(
        http.fetchBytes(Uri.parse('http://example.com')),
        throwsA(isA<AgentException>()),
      );
    } finally {
      http.close();
    }
  });

  group(
    '内嵌Node基础模块的真实工具执行',
    () {
      late AgentController agent;
      late NodeHttpFixture http;
      late AgentJsPackages runner;
      setUp(() async {
        http = NodeHttpFixture();
        agent = AgentController(store: AgentStore.memory(), http: http);
        await agent.initialize();
        runner = AgentJsPackages(agent.store, http);
      });
      tearDown(() async {
        await runner.drain();
        await agent.shutdown();
        agent.dispose();
      });
      Future<Json> run(String source, {bool permission = true}) async {
        final extension = AgentExtension.fromPackage(
          bundle(
            source: source,
            extra: {
              'permissions': permission ? ['web_fetch'] : <String>[],
            },
          ),
        );
        return runner.run(
          manifest: extension.manifest,
          settings: {},
          operation: 'tool',
          args: {'id': 'probe'},
          active: () => true,
        );
      }

      test('http和https具名/默认导入，GET自动结束，response/data/end接收真实字节', () async {
        final result = await run(r'''
        import http, {get as httpGet} from 'node:http';
        import https, {request as httpsRequest} from 'https';
        export function setup(api){api.registerTool({id:'probe',parameters:{type:'object',properties:{}},async execute(){
          const get=(fn,url)=>new Promise((resolve,reject)=>{fn(url,res=>{const chunks=[];res.on('data',v=>chunks.push(v));res.on('end',()=>resolve([res.statusCode,Buffer.concat(chunks).toString()]));res.on('error',reject);}).on('error',reject);});
          return {http:await get(httpGet,'http://public.fixture.test/get?q=1'),https:await get(https.get,'https://public.fixture.test/get'),same:http.get===httpGet&&https.request===httpsRequest};
        }});}
      ''');
        expect(result['http'], [200, '你好，语音']);
        expect(result['https'], [200, '你好，语音']);
        expect(result['same'], true);
        expect(http.calls.map((c) => c['uri']), [
          'http://public.fixture.test/get?q=1',
          'https://public.fixture.test/get',
        ]);
      });
      test('request分段写入UTF8正文、Header接口和PUT参数正确传输', () async {
        final result = await run(r'''
        import {request} from 'node:https';
        export function setup(api){api.registerTool({id:'probe',parameters:{type:'object',properties:{}},execute(){return new Promise((resolve,reject)=>{
          const body='测试正文';const req=request(new URL('https://public.fixture.test/original'),{path:'/post?x=2',method:'PUT',headers:{'Content-Length':Buffer.byteLength(body),'Connection':'keep-alive','X-Probe':'ok'}},res=>{res.setEncoding('utf8');let value='';res.on('data',c=>value+=c);res.on('end',()=>resolve({content:value,header:req.getHeader('x-probe'),names:req.getHeaderNames(),finished:req.finished}));});
          req.on('error',reject);req.setHeader('X-Remove','gone');req.removeHeader('x-remove');req.write('测试');req.end('正文');
        });}});}
      ''');
        expect(result['content'], '你好，语音');
        expect(result['finished'], true);
        expect(result['header'], 'ok');
        expect(
          http.calls.single['uri'],
          'https://public.fixture.test/post?x=2',
        );
        expect(http.calls.single['method'], 'PUT');
        expect(utf8.decode(http.calls.single['body'] as Uint8List), '测试正文');
        expect(http.calls.single['headers'], {'x-probe': 'ok'});
      });
      test('响应pipe至VFS文件，pipeline/finished和分块中文编码不丢数据', () async {
        final result = await run(r'''
        import https from 'https';import fs,{createWriteStream,createReadStream} from 'node:fs';
        import {pipeline,finished} from 'node:stream/promises';import {Transform,PassThrough} from 'node:stream';
        export function setup(api){api.registerTool({id:'probe',parameters:{type:'object',properties:{}},async execute(){
          const response=await new Promise((resolve,reject)=>https.get('https://public.fixture.test/large',resolve).on('error',reject));
          await pipeline(response,new PassThrough(),createWriteStream('/tmp/voice.txt'));
          const reader=createReadStream('/tmp/voice.txt',{highWaterMark:17});reader.setEncoding('utf8');let value='';for await(const text of reader)value+=text;await finished(reader);
          return {equal:value==='中文🙂'.repeat(20000),bytes:fs.statSync('/tmp/voice.txt').size,transform:typeof Transform};
        }});}
      ''');
        expect(result, {
          'equal': true,
          'bytes': utf8.encode(List.filled(20000, '中文🙂').join()).length,
          'transform': 'function',
        });
      });
      test('timeout只触发通知，由destroy取消宿主请求并返回错误，不残留网络任务', () async {
        final result = await run(r'''
        import https from 'node:https';
        export function setup(api){api.registerTool({id:'probe',parameters:{type:'object',properties:{}},execute(){return new Promise(resolve=>{
          let timed=false;const req=https.get('https://public.fixture.test/slow',()=>resolve({bad:true}));req.setTimeout(5,()=>{timed=true;req.destroy(new Error('超时主动取消'));});req.on('error',e=>resolve({timed,error:e.message}));
        });}});}
      ''');
        expect(result, {'timed': true, 'error': '超时主动取消'});
        expect(http.calls, hasLength(1));
      });
      test('AbortSignal终止请求，传输错误经error事件返回', () async {
        final result = await run(r'''
        import https from 'node:https';
        export function setup(api){api.registerTool({id:'probe',parameters:{type:'object',properties:{}},async execute(){
          const controller=new AbortController();const aborted=new Promise(resolve=>{const req=https.get('https://public.fixture.test/slow',{signal:controller.signal});req.on('error',e=>resolve(e.code));});setTimeout(()=>controller.abort(),5);
          const failure=await new Promise(resolve=>https.get('https://public.fixture.test/fail').on('error',e=>resolve(e.message)));return {aborted:await aborted,failure};
        }});}
      ''');
        expect(result, {'aborted': 'ABORT_ERR', 'failure': '模拟连接失败。'});
      });
      test('重定向只返回302，不转发请求到Location指定的内网', () async {
        final result = await run(r'''
        import https from 'https';export function setup(api){api.registerTool({id:'probe',parameters:{type:'object',properties:{}},execute(){return new Promise((resolve,reject)=>https.get('https://public.fixture.test/redirect',res=>{res.resume();res.on('end',()=>resolve({status:res.statusCode,location:res.headers.location}));}).on('error',reject));}});}
      ''');
        expect(result, {'status': 302, 'location': 'http://127.0.0.1/private'});
        expect(http.calls, hasLength(1));
      });
      test('未知来源的鉴权、伪造Host、错误Content-Length和越权请求均被拒绝', () async {
        final result = await run(r'''
        import https from 'https';export function setup(api){api.registerTool({id:'probe',parameters:{type:'object',properties:{}},async execute(){const results=[];
          for(const headers of [{Authorization:'Bearer not-allowed'}, {Host:'internal.invalid'}, {'Content-Length':100}])results.push(await new Promise(resolve=>{const req=https.request('https://public.fixture.test/get',{method:'POST',headers});req.on('error',e=>resolve(e.message));req.end('a');}));return {errors:results};
        }});}
      ''');
        expect(
          (result['errors'] as List).every((e) => e.toString().isNotEmpty),
          true,
        );
        expect(http.calls, isEmpty);
        await expectLater(
          run(r'''
        import http from 'node:http';export function setup(api){api.registerTool({id:'probe',parameters:{type:'object',properties:{}},execute(){return new Promise((resolve,reject)=>http.get('http://public.fixture.test/get',resolve).on('error',reject));}});}
      ''', permission: false),
          throwsA(isA<AgentException>()),
        );
      });
      test('EventEmitter、StringDecoder、querystring、util和timers可实际调用', () async {
        final result = await run(r'''
        import Emitter,{EventEmitter,once} from 'node:events';import {StringDecoder} from 'string_decoder';import qs from 'node:querystring';import {promisify,format} from 'util';import {setTimeout as delay} from 'node:timers/promises';
        export function setup(api){api.registerTool({id:'probe',parameters:{type:'object',properties:{}},async execute(){
          const emitter=new EventEmitter();let count=0;emitter.once('value',()=>count++);const event=once(emitter,'value');emitter.emit('value',7);emitter.emit('value',9);
          const decoder=new StringDecoder('utf8'),bytes=Buffer.from('你好🙂');const value=decoder.write(bytes.subarray(0,2))+decoder.write(bytes.subarray(2,8))+decoder.end(bytes.subarray(8));
          const add=promisify((a,b,callback)=>callback(null,a+b));return {same:Emitter===EventEmitter,event:await event,count,value,sum:await add(2,3),formatted:format('%s=%d','n',5),query:qs.parse(qs.stringify({q:'中文 空格',id:['a','b']})),timer:await delay(1,'done')};
        }});}
      ''');
        expect(result, {
          'same': true,
          'event': [7],
          'count': 1,
          'value': '你好🙂',
          'sum': 5,
          'formatted': 'n=5',
          'query': {
            'q': '中文 空格',
            'id': ['a', 'b'],
          },
          'timer': 'done',
        });
      });
      test('Readable/Transform异步迭代，管道写入失败按真实失败返回', () async {
        final result = await run(r'''
        import {Readable,Transform,Writable} from 'stream';import {pipeline} from 'stream/promises';
        export function setup(api){api.registerTool({id:'probe',parameters:{type:'object',properties:{}},async execute(){
          const chunks=[];await pipeline(Readable.from(['a','b'],{objectMode:false}),new Transform({transform(chunk,enc,cb){cb(null,Buffer.from(chunk.toString().toUpperCase()));}}),new Writable({write(chunk,enc,cb){chunks.push(chunk.toString());cb();}}));
          let failure='';try{await pipeline(Readable.from(['x'],{objectMode:false}),new Writable({write(chunk,enc,cb){cb(new Error('不能写入'));}}));}catch(e){failure=e.message;}return {chunks,failure};
        }});}
      ''');
        expect(result, {
          'chunks': ['A', 'B'],
          'failure': '不能写入',
        });
      });

      final original = File(
        'C:/Users/Administrator/Downloads/112/skills-rvc-sing.zip',
      );
      test(
        '用户原始RVC包可导入并注册工具，不开启端口、不启动Python，具体缺项可见',
        () async {
          final before = await original.readAsBytes();
          await agent.importPackage(before);
          final extension = agent.extensions.singleWhere(
            (e) => e.id == 'rvc-sing',
          );
          expect(extension.enabled, false);
          expect(extension.tools.map((t) => t['name']), [
            'rvc-sing__sing',
            'rvc-sing__sing_status',
          ]);
          expect(extension.compatibility['state'], 'blocked');
          final details = extension.compatibilityDetails.join('\n');
          expect(details, contains('Python'));
          expect(details, contains('本地 HTTP 服务'));
          expect(details, isNot(contains('could not load module')));
          expect(
            extension.manifest['files'],
            AgentExtension.fromPackage(before).manifest['files'],
          );
          expect(await original.readAsBytes(), before);
          expect(http.calls, isEmpty);
          await expectLater(
            agent.saveExtension(extension.copyWith(enabled: true)),
            throwsA(isA<AgentException>()),
          );
        },
        skip: original.existsSync() ? false : '需提供原始rvc-sing ZIP',
      );
    },
    skip: Platform.environment['FLUTTER_QJS_NEXT_LIBRARY'] == null
        ? '需内嵌JavaScript引擎'
        : false,
  );
}
