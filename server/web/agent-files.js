"use strict";
(() => {
  const node = (tag, text, cls) => { const n = document.createElement(tag); if (text != null) n.textContent = text; if (cls) n.className = cls; return n; };
  const bytes = base64 => Uint8Array.from(atob(base64), c => c.charCodeAt(0));
  function encoded(value) { let s = ""; for (let i = 0; i < value.length; i += 16384) s += String.fromCharCode(...value.subarray(i, i + 16384)); return btoa(s); }
  function valid(path) { if (!path || path.length > 256 || /[\\\x00-\x1f:<>"|?*]/.test(path) || path.split("/").some(p => !p || p === "." || p === ".." || /[. ]$/.test(p))) throw Error("包内路径无效，请使用 / 分隔目录。"); return path; }
  globalThis.qqmOpenExtensionFiles = async (api, id, onSaved) => {
    let base = await api(`extension/files?${new URLSearchParams({id})}`), files = {...base.files}, selected = files["index.js"] ? "index.js" : base.manifestFile, directory = "", dirty = false, saving = false;
    const folders = new Set(), dialog = node("dialog", null, "source-manager"), header = node("div", null, "source-heading"), tree = node("aside"), editor = node("textarea"), pathLabel = node("strong"), status = node("p"), error = node("p"), body = node("div", null, "source-body"), toolbar = node("div", null, "source-toolbar"), preview = node("p");
    editor.setAttribute("aria-label", "扩展源码"); editor.spellcheck = false; error.setAttribute("role", "alert");
    const guard = action => async () => { error.textContent = ""; try { await action(); } catch (e) { error.textContent = e.message || "操作失败"; } };
    function button(label, action) { const b = node("button", label); b.type = "button"; b.onclick = guard(action); return b; }
    function mark() { dirty = true; status.textContent = "有未保存的修改"; saveButton.disabled = false; }
    function select(path) {
      selected = path; pathLabel.textContent = path; preview.textContent = ""; editor.hidden = false; editor.disabled = saving;
      try {
        const raw = bytes(files[path]);
        if (raw.length > 1024 * 1024 || raw.includes(0)) throw Error("二进制或超过1MB的文件，请导出后编辑，或使用导入替换。");
        editor.value = new TextDecoder("utf-8", {fatal:true}).decode(raw);
      } catch (e) { editor.hidden = true; editor.value = ""; preview.textContent = e.message || "二进制文件，请导出查看。"; }
    }
    editor.oninput = () => { files[selected] = encoded(new TextEncoder().encode(editor.value)); mark(); };
    function drawTree() {
      tree.replaceChildren(); const prefix = directory ? directory + "/" : "", dirs = new Set(), leaves = [];
      tree.append(button(directory ? "↑ " + directory : "全部文件", () => { directory = directory.includes("/") ? directory.slice(0, directory.lastIndexOf("/")) : ""; drawTree(); }));
      for (const name of [...Object.keys(files), ...folders]) {
        if (!name.startsWith(prefix) || name === directory) continue;
        const rest = name.slice(prefix.length), slash = rest.indexOf("/");
        if (slash >= 0) dirs.add(prefix + rest.slice(0, slash)); else if (folders.has(name)) dirs.add(name); else leaves.push(name);
      }
      for (const name of [...dirs].sort()) tree.append(button("📁 " + name.slice(prefix.length), () => { directory = name; drawTree(); }));
      for (const name of leaves.sort()) { const b = button(name.slice(prefix.length), () => { select(name); drawTree(); }); b.classList.toggle("active", name === selected); tree.append(b); }
    }
    async function save() {
      if (!dirty || saving) return;
      saving = true; editor.disabled = true; toolbar.querySelectorAll("button").forEach(b => b.disabled = true); saveButton.disabled = true; error.textContent = ""; status.textContent = "正在校验源码并应用…";
      try { base = await api("extension/files/save", {id, revision: base.revision, files}); files = {...base.files}; dirty = false; status.textContent = "已保存并应用"; await onSaved?.(); }
      finally { saving = false; editor.disabled = false; toolbar.querySelectorAll("button").forEach(b => b.disabled = false); saveButton.disabled = !dirty; if (dirty) status.textContent = "保存未完成，修改仍在当前编辑器中"; }
    }
    const saveButton = button("保存并应用", save); saveButton.className = "primary"; saveButton.disabled = true;
    const beforeUnload = e => { if (dirty || saving) { e.preventDefault(); e.returnValue = ""; } };
    const close = () => { if (saving || dirty && !confirm("放弃未保存的源码修改？")) return; dialog.close(); dialog.remove(); window.removeEventListener("beforeunload", beforeUnload); };
    const exportFile = () => { const url = URL.createObjectURL(new Blob([bytes(files[selected])])); const a = node("a"); a.href = url; a.download = selected.split("/").pop(); a.click(); setTimeout(() => URL.revokeObjectURL(url), 30000); };
    if (base.javascript) {
      toolbar.append(button("新建文件", () => { const path = prompt("文件路径，例如 src/tools.js", (directory ? directory + "/" : "") + "new.js"); if (path == null) return; valid(path); if (Object.keys(files).some(n => n.toLowerCase() === path.toLowerCase())) throw Error("文件已存在。"); files[path] = ""; select(path); mark(); drawTree(); }), button("新建目录", () => { const path = prompt("目录路径", (directory ? directory + "/" : "") + "src"); if (path == null) return; valid(path); folders.add(path); directory = path; drawTree(); }), button("重命名 / 移动", () => { if (selected === base.manifestFile) throw Error("请保留清单文件的位置。"); const path = prompt("新的包内文件路径", selected); if (path == null || path === selected) return; valid(path); if (Object.keys(files).some(n => n.toLowerCase() === path.toLowerCase())) throw Error("目标文件已存在。"); files[path] = files[selected]; delete files[selected]; select(path); mark(); drawTree(); }), button("删除文件", () => { if (selected === base.manifestFile) throw Error("不能删除清单文件。"); if (!confirm(`删除 ${selected}？`)) return; delete files[selected]; select(base.manifestFile); mark(); drawTree(); }));
      const input = node("input"); input.type = "file"; input.multiple = true; input.hidden = true;
      input.onchange = guard(async () => {
        const next = {...files};
        for (const f of input.files) { const path = valid((directory ? directory + "/" : "") + f.name); if (f.size > 8 * 1024 * 1024) throw Error("单文件不能超过8MB。"); if (next[path] && !confirm(`替换 ${path}？`)) continue; next[path] = encoded(new Uint8Array(await f.arrayBuffer())); }
        if (Object.keys(next).length > 300 || Object.values(next).reduce((sum, v) => sum + Math.floor(v.length * .75), 0) > 24 * 1024 * 1024) throw Error("源码最多300个文件、24MB。");
        files = next; mark(); select(selected); drawTree(); input.value = "";
      });
      toolbar.append(input, button("导入 / 替换文件", () => input.click()));
    }
    toolbar.append(button("导出当前文件", exportFile));
    header.append(node("h2", `${id} · 文件管理`), saveButton, button("关闭", close));
    const editArea = node("section", null, "source-edit"); editArea.append(pathLabel, node("p", "清单可编辑；保留扩展ID和类型。保存时统一校验，失败不会覆盖原源码。"), editor, preview);
    body.append(tree, editArea); dialog.append(header, toolbar, body, status, error); document.body.append(dialog);
    dialog.addEventListener("cancel", e => { e.preventDefault(); close(); });
    dialog.addEventListener("keydown", e => { if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s") { e.preventDefault(); guard(save)(); } });
    window.addEventListener("beforeunload", beforeUnload);
    select(selected); drawTree(); dialog.showModal();
  };
})();
