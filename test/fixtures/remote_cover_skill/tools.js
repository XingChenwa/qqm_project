// Generated from CoverLink's HTTP Skill protocol. No credentials.
export const tools = [
  {
    "id": "remote_cover_search_qq",
    "name": "搜索歌曲（跟随服务端来源）",
    "description": "按歌名和歌手搜索服务端当前所选的QQ音乐或网易云。多版本须展示歌名、歌手给原提问者，等本人新消息确认，不下载、不擅自选版本。",
    "parameters": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "用户想唱的歌名，可带歌手或版本，最多100字"
        }
      },
      "required": [
        "query"
      ],
      "additionalProperties": false
    },
    "action": "search_qq"
  },
  {
    "id": "remote_cover_select_qq",
    "name": "确认歌曲版本",
    "description": "确认导入原提问者在本会话的上次QQ音乐搜索结果。直接调用即可，不必重新搜索或记住列表ID。多版本只接受本人新消息中的序号或歌手；不能传选择数字，宿主读取真实消息。只有一个候选时可直接确认。",
    "parameters": {
      "type": "object",
      "properties": {
        "search_id": {
          "type": "string",
          "description": "可选：上次搜索返回的search_id；省略时使用当前提问者本会话最近的列表"
        }
      },
      "required": [],
      "additionalProperties": false
    },
    "action": "select_qq"
  },
  {
    "id": "remote_cover_import_qq",
    "name": "导入 QQ / 网易云链接",
    "description": "导入用户明确给出的QQ音乐/网易云详情链接或来源ID。只给歌名时先搜歌，多版本须本人确认。客户端下载并回传原曲，服务器确认后才算导入完成。",
    "parameters": {
      "type": "object",
      "properties": {
        "song": {
          "type": "string",
          "description": "用户提供的QQ/网易云歌曲详情链接，或QQ MID、qq:MID、netease:数字歌曲ID。不能混淆平台ID。"
        }
      },
      "required": [
        "song"
      ],
      "additionalProperties": false
    },
    "action": "import_qq"
  },
  {
    "id": "remote_cover_health",
    "name": "检查翻唱环境",
    "description": "检查调度服务、家用执行端CPU/NVIDIA GPU、基础模型和音色缺项。",
    "parameters": {
      "type": "object",
      "properties": {},
      "additionalProperties": false
    },
    "action": "health"
  },
  {
    "id": "remote_cover_models",
    "name": "查询实际音色",
    "description": "列出用户实际导入的RVC音色模型名称和ID；没有模型时不能翻唱。",
    "parameters": {
      "type": "object",
      "properties": {},
      "additionalProperties": false
    },
    "action": "models"
  },
  {
    "id": "remote_cover_songs",
    "name": "查询已有歌曲",
    "description": "列出本地歌曲。用户已提供歌名时传query，按服务端选择的QQ/网易云查询并用真实ID识别已有文件。不能让用户在不明文件名中选歌；多个版本仍需原提问者确认。",
    "parameters": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "description": "可选：用户已说出的歌名，可带歌手；最多100字。为旧曲库恢复名称，不自动选择或下载。"
        }
      },
      "additionalProperties": false
    },
    "action": "songs"
  },
  {
    "id": "remote_cover_start",
    "name": "提交范围翻唱",
    "description": "选择整首、自动高潮或指定时间段，按范围创建家用电脑翻唱任务；片段只处理选中部分。完成回传后再发送，不重复提交。。以auto_send和delivery的真实登记结果为准，不能仅凭排队承诺自动发送。",
    "parameters": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "song": {
          "type": "string",
          "description": "必须使用remote_rvc_cover__remote_cover_songs列表返回的歌曲id，不能直接填歌名。"
        },
        "model": {
          "type": "string",
          "description": "必须使用remote_rvc_cover__remote_cover_models列表返回的音色id，不能直接填音色名称。"
        },
        "pitch": {
          "type": "integer",
          "description": "可选：升降调半音，-24至24，默认0"
        },
        "mode": {
          "type": "string",
          "enum": [
            "whole",
            "chorus",
            "range"
          ],
          "description": "whole整首；chorus自动高潮；range指定时间段。按用户要求选择，未说明范围先询问。"
        },
        "start_seconds": {
          "type": "number",
          "description": "仅range使用，起点秒数0至7200。例如1分20秒为80。其他模式不传。"
        },
        "duration_seconds": {
          "type": "integer",
          "description": "0表示自动高潮随歌曲段落确定起止和长度（chorus默认0）；正整数5至600为自选片段长度，range默认60；whole忽略。"
        }
      },
      "required": [
        "song",
        "model",
        "mode"
      ]
    },
    "action": "start_selected"
  },
  {
    "id": "remote_cover_status",
    "name": "查询翻唱进度",
    "description": "查询当前会话的翻唱任务真实状态。job_id省略时查询本会话最近一次任务。 新客户端会为本会话已有翻唱补登记完成后发送；读取delivery区分待发送、已发、等待新消息及回执不明。",
    "parameters": {
      "type": "object",
      "properties": {
        "job_id": {
          "type": "string"
        }
      },
      "additionalProperties": false
    },
    "action": "status"
  },
  {
    "id": "remote_cover_cancel",
    "name": "取消翻唱",
    "description": "用户要求停止时取消当前会话的翻唱任务。job_id可省略，不能取消其他会话任务。",
    "parameters": {
      "type": "object",
      "properties": {
        "job_id": {
          "type": "string"
        }
      },
      "additionalProperties": false
    },
    "action": "cancel"
  },
  {
    "id": "remote_cover_send",
    "name": "发送完整翻唱成品",
    "description": "发送已回传、所选范围的完整翻唱成品到当前QQ会话，等待真实消息回执。不是固定30秒试听；超出音频大小限制会明确报错。",
    "parameters": {
      "type": "object",
      "properties": {
        "job_id": {
          "type": "string"
        }
      },
      "additionalProperties": false
    },
    "action": "audio"
  }
];
