import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qq_bot_manager/agent/controller.dart';
import 'package:qq_bot_manager/agent/extensions.dart';
import 'package:qq_bot_manager/agent/http.dart';
import 'package:qq_bot_manager/agent/js_packages.dart';
import 'package:qq_bot_manager/agent/models.dart';
import 'package:qq_bot_manager/agent/package_bundle.dart';
import 'package:qq_bot_manager/agent/store.dart';
import 'package:qq_bot_manager/agent/ui/editor.dart';
import 'package:flutter/material.dart';

Uint8List bundle({
  String source = '',
  String root = 'nested/pkg/',
  Json extra = const {},
  Map<String, String> files = const {},
}) {
  final archive = Archive();
  final entries = {
    'skill.json': jsonEncode({
      'id': 'fixture',
      'name': '测试原包',
      'apiVersion': 1,
      'settings': {'greeting': '你好'},
      ...extra,
    }),
    'index.js': source,
    ...files,
  };
  for (final e in entries.entries) {
    final bytes = utf8.encode(e.value);
    archive.addFile(ArchiveFile('$root${e.key}', bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

class ModelListHttp extends AgentHttp {
  Uri? requested;
  Map<String, String>? requestHeaders;
  @override
  Future<dynamic> request(
    Uri uri, {
    String method = 'GET',
    Json? body,
    Map<String, String> headers = const {},
    Json? query,
    CancelToken? cancel,
    int timeoutSeconds = 60,
    int maxBytes = 1048576,
  }) async {
    requested = uri;
    requestHeaders = headers;
    return {
      'data': [
        {'id': 'model-alpha'},
        {'id': 'model-beta'},
      ],
    };
  }
}

void main() {
  test('嵌套原包保留所有原始字节，导入关闭，导出 ZIP 可再次导入', () {
    final e = AgentExtension.fromPackage(
      bundle(
        source: 'export const n=42;',
        extra: {'enabledByDefault': true},
        files: {'kb/a.json': '{"词":"解释"}'},
      ),
    );
    expect(e.enabled, false);
    expect(e.isJavaScript, true);
    expect(e.config['greeting'], '你好');
    expect(
      utf8.decode(base64Decode(object(e.manifest['files'])['index.js'])),
      'export const n=42;',
    );
    final exported = AgentPackageBundle.encode(e.manifest, {
      'greeting': '修改配置',
    });
    final again = AgentExtension.fromPackage(exported);
    expect(again.config['greeting'], '修改配置');
    expect(
      object(again.manifest['files'])['index.js'],
      object(e.manifest['files'])['index.js'],
    );
    e.toJson(includeFiles: false);
    expect(object(e.manifest['files']).length, 3);
    expect(
      e.toJson(includeFiles: false)['manifest'].containsKey('files'),
      false,
    );
  });
  test('拒绝路径穿越、多个清单、原生依赖、损坏 ZIP 和伪造膨胀大小', () {
    expect(
      () => AgentExtension.fromPackage(bundle(files: {'../outside': 'bad'})),
      throwsA(isA<AgentException>()),
    );
    expect(
      () => AgentExtension.fromPackage(bundle(files: {'plugin.json': '{}'})),
      throwsA(isA<AgentException>()),
    );
    expect(
      () => AgentExtension.fromPackage(bundle(files: {'native.dll': 'bad'})),
      throwsA(isA<AgentException>()),
    );
    expect(
      () => AgentExtension.fromPackage(
        bundle(files: {'package.json': '{"dependencies":{"x":"1"}}'}),
      ),
      throwsA(isA<AgentException>()),
    );
    expect(
      () => AgentExtension.fromPackage([1, 2, 3]),
      throwsA(isA<AgentException>()),
    );
    final bytes = bundle();
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < bytes.length - 46; i++) {
      if (data.getUint32(i, Endian.little) == 0x02014b50) {
        data.setUint32(i + 24, 100 * 1024 * 1024, Endian.little);
        break;
      }
    }
    expect(
      () => AgentExtension.fromPackage(bytes),
      throwsA(isA<AgentException>()),
    );
  });
  test('无需模型 ID 或先保存，也能使用当前草稿凭证获取模型列表', () async {
    final http = ModelListHttp();
    final agent = AgentController(store: AgentStore.memory(), http: http);
    await agent.initialize();
    final models = await agent.listModels(
      AgentProvider(
        id: 'draft',
        name: '草稿',
        baseUrl: 'https://model.example/v1',
        model: '',
        apiKey: 'draft-only-key',
      ),
    );
    expect(models, ['model-alpha', 'model-beta']);
    expect(http.requested.toString(), 'https://model.example/v1/models');
    expect(http.requestHeaders?['Authorization'], 'Bearer draft-only-key');
    expect(agent.providers, isEmpty);
    expect(jsonEncode(agent.snapshot()), isNot(contains('draft-only-key')));
    await agent.shutdown();
  });
  testWidgets('模型编辑器用未保存的地址和 Key 获取列表，搜索并填回选择值', (tester) async {
    Json? received, saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => editAgent(
                context,
                title: '模型',
                initial: {'baseUrl': '', 'apiKey': '', 'model': ''},
                fields: [
                  const AgentField('baseUrl', '接口地址'),
                  const AgentField('apiKey', 'API Key', type: 'secret'),
                  AgentField(
                    'model',
                    '模型 ID',
                    loadOptions: (j) async {
                      received = j;
                      return ['alpha', 'beta'];
                    },
                  ),
                ],
                save: (j) async {
                  saved = j;
                },
              ),
              child: const Text('编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, '接口地址'),
      'https://draft.example/v1',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'API Key'),
      'typed-key',
    );
    await tester.tap(find.text('获取并选择模型'));
    await tester.pumpAndSettle();
    expect(received?['apiKey'], 'typed-key');
    expect(received?['model'], '');
    await tester.enterText(find.widgetWithText(TextField, '搜索模型 ID'), 'beta');
    await tester.pump();
    await tester.tap(find.widgetWithText(ListTile, 'beta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(saved?['model'], 'beta');
  });

  group(
    '嵌入式 QuickJS 跨平台核心',
    () {
      late AgentStore store;
      late AgentHttp http;
      late AgentJsPackages packages;
      setUp(() async {
        store = AgentStore.memory();
        await store.open();
        http = AgentHttp();
        packages = AgentJsPackages(store, http);
      });
      tearDown(() async {
        http.close();
        await store.close();
      });
      test('ESM、import.meta、Node 文件/路径/哈希/Buffer，读写隔离且持久化', () async {
        final e = AgentExtension.fromPackage(
          bundle(
            source: r'''
        import fs from 'node:fs'; import path from 'node:path';
        import {fileURLToPath} from 'node:url'; import crypto from 'node:crypto';
        import {greeting} from './lib/helper.js?v=1';
        export function setup(api) { api.registerTool({id:'run',name:'run',parameters:{type:'object',properties:{}},
          execute(ctx,args) { const file=path.join(process.env.QQ_AGENT_DATA_DIR,'value.json');
            if(args.value) {fs.mkdirSync(path.dirname(file),{recursive:true});fs.writeFileSync(file,JSON.stringify(args.value));}
            let denied=false;try{fs.readFileSync('/official/config.json','utf8')}catch{denied=true;}
            return {content:JSON.stringify({greeting,value:fs.existsSync(file)?JSON.parse(fs.readFileSync(file,'utf8')):null,
              denied,hash:crypto.createHash('sha256').update(Buffer.from('你好')).digest('hex'),
              file:fileURLToPath(import.meta.url),binary:Buffer.from([0,1,254,255]).toString('base64')})};}
        }); }
      ''',
            files: {'lib/helper.js': "export const greeting='原包 ESM';"},
          ),
        );
        Future<Json> run(String scope, {String? value}) async {
          final r = await packages.run(
            manifest: e.manifest,
            settings: e.config,
            operation: 'tool',
            scope: scope,
            args: {
              'id': 'run',
              'args': {'value': ?value},
            },
            active: () => true,
          );
          return object(jsonDecode(text(r['content'])));
        }

        final a = await run('account-a', value: '保存成功');
        expect(a['greeting'], '原包 ESM');
        expect(a['hash'], sha256.convert(utf8.encode('你好')).toString());
        expect(a['denied'], true);
        expect(a['file'], '/packages/fixture/index.js');
        expect(a['binary'], 'AAH+/w==');
        expect((await run('account-a'))['value'], '保存成功');
        expect((await run('account-b'))['value'], null);
      });
      test('系统模块可检查依赖，但执行外部程序始终被拒绝', () async {
        final e = AgentExtension.fromPackage(
          bundle(
            source:
                "import cp from 'node:child_process'; export function setup(api){api.registerTool({id:'run',parameters:{type:'object',properties:{}},execute(){cp.spawn('powershell',[]);return {content:'不应成功'};}});}",
          ),
        );
        await expectLater(
          packages.run(
            manifest: e.manifest,
            settings: e.config,
            operation: 'tool',
            args: {'id': 'run', 'args': {}},
            active: () => true,
          ),
          throwsA(isA<AgentException>()),
        );
      });
      test('大于真实图库索引的 UTF-8 与二进制通过批量桥接，不被逐字节转换卡住', () async {
        final e = AgentExtension.fromPackage(
          bundle(
            source: r'''
        import fs from 'node:fs';import crypto from 'node:crypto';
        export function setup(api){api.registerTool({id:'large',name:'large',parameters:{type:'object',properties:{}},execute(){
          const text='中文'.repeat(250000),b=Buffer.from(text);fs.writeFileSync('/data/large',b);
          const restored=fs.readFileSync('/data/large','utf8');
          return {content:JSON.stringify({same:restored===text,bytes:b.length,hash:crypto.createHash('sha256').update(b).digest('hex')})};
        }});}
      ''',
          ),
        );
        final r = await packages.run(
          manifest: e.manifest,
          settings: {},
          operation: 'tool',
          args: {'id': 'large'},
          active: () => true,
        );
        final result = object(jsonDecode(text(r['content'])));
        expect(result['same'], true);
        expect(result['bytes'], 1500000);
        expect(
          result['hash'],
          sha256
              .convert(utf8.encode(List.filled(250000, '中文').join()))
              .toString(),
        );
      });
      test('无限循环被原生中断，取消旧任务不会落盘', () async {
        final bad = AgentExtension.fromPackage(bundle(source: 'while(true){}'));
        final timer = Stopwatch()..start();
        await expectLater(
          packages.run(
            manifest: bad.manifest,
            settings: {},
            operation: 'inspect',
            active: () => true,
          ),
          throwsA(isA<AgentException>()),
        );
        expect(timer.elapsed.inSeconds, lessThan(5));
        final waiting = AgentExtension.fromPackage(
          bundle(
            source: r'''
        import fs from 'node:fs';export function setup(api){api.registerTool({id:'wait',name:'wait',parameters:{type:'object',properties:{}},async execute(){fs.writeFileSync('/data/late','bad');await new Promise(r=>setTimeout(r,10000));return {content:'late'};}})}
      ''',
          ),
        );
        var current = true;
        final result = packages.run(
          manifest: waiting.manifest,
          settings: {},
          operation: 'tool',
          args: {'id': 'wait'},
          scope: 'cancelled',
          active: () => current,
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        current = false;
        await expectLater(result, throwsA(isA<AgentException>()));
        expect(store.keys.where((k) => k.startsWith('js-volume:')), isEmpty);
      });
      test('原包注册的工具经 Controller 导入后可用，默认关闭', () async {
        final agent = AgentController(store: store, http: http);
        await agent.initialize();
        await agent.importPackage(
          bundle(
            source:
                "export function setup(api){api.registerTool({id:'lookup',description:'查询',parameters:{type:'object',properties:{}},execute(){return {content:'ok'}}});}",
          ),
        );
        final e = agent.extensions.singleWhere((e) => e.id == 'fixture');
        expect(e.enabled, false);
        expect(e.tools.single['name'], 'fixture__lookup');
        expect(
          jsonEncode(agent.snapshot()),
          isNot(contains('export function setup')),
        );
        await agent.shutdown();
      });
    },
    skip: Platform.environment['FLUTTER_QJS_NEXT_LIBRARY'] == null
        ? '需要先构建 tool/native_agent，并设置测试原生库路径。'
        : false,
  );
}
