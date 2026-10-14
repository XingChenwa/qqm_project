import 'package:flutter/material.dart';

class WeatherConfigDialog extends StatefulWidget {
  final Map<String, dynamic> config;
  const WeatherConfigDialog({super.key, required this.config});

  @override
  State<WeatherConfigDialog> createState() => _WeatherConfigDialogState();
}

class _WeatherConfigDialogState extends State<WeatherConfigDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _keyController;
  late final TextEditingController _cityController;
  bool _hideKey = true;

  @override
  void initState() {
    super.initState();
    _keyController = TextEditingController(
      text: widget.config['amap_key']?.toString() ?? '',
    );
    _cityController = TextEditingController(
      text: widget.config['default_city']?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _keyController.dispose();
    _cityController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('天气与 IP 查询配置'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _keyController,
                obscureText: _hideKey,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  labelText: '高德 Web 服务 Key',
                  helperText: '在高德开放平台申请“Web 服务”类型 Key',
                  helperMaxLines: 2,
                  prefixIcon: const Icon(Icons.key_rounded),
                  suffixIcon: IconButton(
                    tooltip: _hideKey ? '显示 Key' : '隐藏 Key',
                    icon: Icon(
                      _hideKey
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () => setState(() => _hideKey = !_hideKey),
                  ),
                ),
                validator: (value) =>
                    RegExp(r'\s').hasMatch(value?.trim() ?? '')
                    ? 'Key 内不能包含空格或换行'
                    : null,
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: _cityController,
                decoration: const InputDecoration(
                  labelText: '默认城市（可选）',
                  hintText: '例如：北京、深圳或 110105',
                  helperText: '仅发送“查询天气”或“天气”时使用此城市',
                  helperMaxLines: 2,
                  prefixIcon: Icon(Icons.location_city_rounded),
                ),
                validator: (value) =>
                    (value?.trim().length ?? 0) > 60 ? '城市名称不能超过 60 个字符' : null,
              ),
              const SizedBox(height: 16),
              const Text(
                '天气：天气 北京、查询天气 上海、/天气 深圳、/weather 北京。\nIP：查ip地址 114.114.114.114、/ip 114.114.114.114。',
                style: TextStyle(fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 10),
              const Text(
                'IP 定位仅支持国内 IPv4，不能获取 QQ 发送者的 IP。调用受高德账号权限、白名单和额度限制。当前使用普通 Key 鉴权，不支持数字签名。\nKey 保存在本机配置中，导出配置时会一并导出，请妥善保管。',
                style: TextStyle(fontSize: 11, height: 1.5),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (!_formKey.currentState!.validate()) return;
          Navigator.pop(context, {
            'amap_key': _keyController.text.trim(),
            'default_city': _cityController.text.trim(),
          });
        },
        child: const Text('保存'),
      ),
    ],
  );
}
