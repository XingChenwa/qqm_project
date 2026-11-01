"use strict";
(() => {
  const node = (tag, text) => { const n = document.createElement(tag); if (text != null) n.textContent = text; return n; };
  const dialog = node("dialog"); dialog.className = "migration-dialog";
  document.body.append(dialog);
  let working = false, pending = false;
  dialog.addEventListener("cancel", e => { if (working || pending) e.preventDefault(); });
  function button(label, action) {
    const b = node("button", label); b.type = "button";
    b.onclick = async () => { if (working) return; b.disabled = true; try { await action(); } catch (e) { error.textContent = e.message || "迁移未完成，请稍后重试。"; } finally { b.disabled = false; } }; return b;
  }
  const error = node("p"); error.setAttribute("role", "alert");
  async function request(route, bytes, confirmed = false) {
    const res = await fetch(`./api/migration/${route}`, {
      method: bytes === undefined ? "GET" : "POST", credentials: "same-origin", cache: "no-store",
      headers: { "X-QQM-Request": "1", ...(bytes instanceof File || bytes instanceof Blob ? { "Content-Type": "application/zip" } : {}), ...(confirmed ? { "X-QQM-Confirm-Restore": "1" } : {}) },
      ...(bytes === undefined ? {} : { body: bytes }),
    });
    if (!res.ok) { let e; try { e = await res.json(); } catch {} throw Error(e?.error || `迁移请求失败（HTTP ${res.status}）`); }
    return res;
  }
  async function download(res, fallback) {
    const blob = await res.blob(), a = node("a"), url = URL.createObjectURL(blob);
    a.href = url; a.download = /filename="([^"]+)"/.exec(res.headers.get("Content-Disposition") || "")?.[1] || fallback;
    a.click(); setTimeout(() => URL.revokeObjectURL(url), 30000);
  }
  function restart() {
    pending = true; document.documentElement.dataset.migrationPending = "true";
    dialog.replaceChildren(node("h2", "重启后恢复完整数据"), node("p", "当前机器人与插件已停止。请重启 Linux 管理器服务，再刷新此页。恢复前完整备份已保存在服务器私有数据目录的 data-migration 中。"), node("p", "管理密码和安全入口保持不变。"));
    if (!dialog.open) dialog.showModal();
  }
  async function open() {
    error.textContent = "";
    const status = await (await request("status")).json();
    if (status.restartRequired) return restart();
    const title = node("h2", "完整数据迁移"), info = node("p", "导出全部机器人账号、密钥、聊天记录、插件、Skills、源码、配置及运行数据。ZIP含私有资料，请妥善保管。外部翻唱环境与模型需另行准备。"), actions = node("div"), input = node("input"), progress = node("p");
    input.type = "file"; input.accept = ".zip"; input.hidden = true;
    let confirmButton;
    const exportButton = button("导出完整 ZIP", async () => {
      working = true; importButton.disabled = close.disabled = true; progress.textContent = "正在生成完整备份…";
      try { await download(await request("export", ""), "qqbotmanager-backup.zip"); progress.textContent = "完整ZIP已下载。"; } finally { working = false; importButton.disabled = close.disabled = false; }
    });
    const importButton = button("导入 ZIP 恢复", () => input.click());
    input.onchange = async () => {
      const file = input.files[0]; if (!file) return;
      confirmButton?.remove(); confirmButton = undefined;
      working = true; exportButton.disabled = importButton.disabled = true; error.textContent = "";
      try {
        if (file.size > 128 * 1024 * 1024) throw Error("备份ZIP不能超过128MB。");
        progress.textContent = "正在上传并校验备份…";
        const data = await (await request("inspect", file)).json();
        progress.textContent = `来源：${data.metadata.appVersion || "未知版本"} · ${data.metadata.createdAt || ""}\n聊天消息 ${data.counts.messages} 条 · Agent连接 ${data.counts.agentConnections} 个 · 插件/Skill ${data.counts.agentExtensions} 个 · 工作区文件 ${data.counts.workspaceFiles} 个。恢复会替换当前全部应用数据，并自动备份当前数据。`;
        const confirm = button("备份当前数据并恢复", async () => {
          working = true; exportButton.disabled = importButton.disabled = true; close.disabled = true;
          progress.textContent = "正在停止任务并保存恢复前备份，请勿关闭服务…";
          try { await request("restore", file, true); restart(); } finally { working = false; if (!pending) { close.disabled = exportButton.disabled = importButton.disabled = false; } }
        });
        confirmButton = confirm; actions.append(confirm);
      } catch (e) { error.textContent = e.message; } finally { working = false; if (!pending) exportButton.disabled = importButton.disabled = false; input.value = ""; }
    };
    const close = button("关闭", () => { if (!working) dialog.close(); });
    actions.append(exportButton, importButton, close);
    const recovery = node("section");
    if (status.recovery?.length) {
      recovery.append(node("h3", "恢复前的本机备份"));
      for (const item of status.recovery) recovery.append(button(`下载 ${new Date(item.createdAt).toLocaleString()}`, async () => download(await request(`recovery?${new URLSearchParams({file:item.filename})}`), item.filename)));
    }
    dialog.replaceChildren(title, info, input, progress, error, actions, recovery);
    if (status.notice) dialog.append(node("p", status.notice));
    if (!dialog.open) dialog.showModal();
  }
  document.querySelectorAll("[data-migration]").forEach(b => b.onclick = () => open().catch(e => { dialog.replaceChildren(node("h2", "数据迁移"), node("p", e.message), button("关闭", () => dialog.close())); if (!dialog.open) dialog.showModal(); }));
  request("status").then(r => r.json()).then(s => { if (s.restartRequired) restart(); }).catch(() => {});
})();
