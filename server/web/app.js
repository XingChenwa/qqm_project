"use strict";
const $ = (id) => document.getElementById(id);
// A private setup link uses a fragment, not a query parameter. Remove it from
// history immediately; never keep it in storage, logs or a network URL.
const initialFragment = location.hash;
function consumeSetupLink() {
  const fragment = location.hash;
  if (fragment) history.replaceState(null, "", location.pathname + location.search);
  if (!fragment.startsWith("#setup=")) return;
  const token = fragment.slice(7);
  if (/^[A-Za-z0-9_-]{24,256}$/.test(token)) {
    $("setup-token").value = token;
    $("setup-owner-proof").hidden = true;
    $("setup-link-hint").hidden = false;
  }
}
consumeSetupLink();
window.addEventListener("hashchange", () => {
  if (location.hash.startsWith("#setup=")) consumeSetupLink();
});
document.querySelectorAll(".transport-warning").forEach((node) => {
  node.hidden = location.protocol === "https:";
});
function entranceInput(prefix) {
  const input = $(prefix + "-entrance");
  const preview = () => {
    $(prefix + "-address").textContent =
      location.origin + "/" + (input.value || "你的安全入口") + "/";
  };
  const generate = () => {
    if (globalThis.crypto?.getRandomValues) {
      const bytes = crypto.getRandomValues(new Uint8Array(12));
      input.value = Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
    }
    preview();
  };
  $(prefix + "-generate").onclick = generate;
  input.oninput = preview;
  generate();
}
entranceInput("setup");
entranceInput("migration");
function openEntrance(data) {
  if (!/^\/[A-Za-z0-9][A-Za-z0-9_-]{7,63}\/$/.test(data.entrancePath))
    throw Error("安全入口地址无效，请检查服务版本。");
  location.replace(data.entrancePath + "#welcome");
}
const S = {
  sending: false,
  state: null,
  revision: -1,
  page: "chat",
  session: "",
  messages: [],
  format: "text",
  filter: "all",
  reply: null,
  logged: false,
  polling: null,
  logs: [],
  drafts: new Map(),
  notice: "",
  newCount: 0,
};
function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (value == null) continue;
    if (key === "class") node.className = value;
    else if (key === "text") node.textContent = value;
    else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
    else node.setAttribute(key, String(value));
  }
  for (const child of children.flat())
    if (child != null)
      node.append(
        child instanceof Node ? child : document.createTextNode(String(child)),
      );
  return node;
}
function safeUrl(value) {
  try {
    const u = new URL(value);
    return ["https:", "http:"].includes(u.protocol) &&
      !u.username &&
      !u.password
      ? u.href
      : null;
  } catch {
    return null;
  }
}
function nowTime(value) {
  return new Date(value).toLocaleTimeString("zh-CN", {
    hour: "2-digit",
    minute: "2-digit",
  });
}
function showLogin() {
  S.logged = false;
  $("app").hidden = true;
  $("auth-loading").hidden = true;
  $("setup-view").hidden = true;
  $("entrance-view").hidden = true;
  $("login-view").hidden = false;
}
function showSetup() {
  S.logged = false;
  $("app").hidden = true;
  $("auth-loading").hidden = true;
  $("login-view").hidden = true;
  $("entrance-view").hidden = true;
  $("setup-view").hidden = false;
}
function showEntrance() {
  S.logged = false;
  $("app").hidden = true;
  $("auth-loading").hidden = true;
  $("login-view").hidden = true;
  $("setup-view").hidden = true;
  $("entrance-view").hidden = false;
}
async function api(path, { method = "GET", body } = {}) {
  const response = await fetch(new URL("api/" + path, location.href), {
    method,
    credentials: "same-origin",
    cache: "no-store",
    headers: {
      "X-QQM-Request": "1",
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    ...(body ? { body: JSON.stringify(body) } : {}),
  });
  let data;
  try {
    data = await response.json();
  } catch {
    throw Error("服务器返回格式异常，请检查代理或服务日志。");
  }
  if (!response.ok) {
    if (data.needsSetup === true) showSetup();
    else if (data.needsEntrance === true) showEntrance();
    else if (
      (response.status === 401 && path !== "login") ||
      (response.status === 409 && path === "setup")
    )
      showLogin();
    const error = Error(data.error || "操作失败，请重试");
    error.needsEntrance = data.needsEntrance === true;
    throw error;
  }
  return data;
}
const post = (path, body = {}) => api(path, { method: "POST", body });
function closeModal() {
  $("modal").close();
}
function modal(title, content, actions = []) {
  $("modal-title").textContent = title;
  $("modal-content").replaceChildren(
    ...(Array.isArray(content)
      ? content
      : [
          typeof content === "string"
            ? el("p", { class: "dialog-text", text: content })
            : content,
        ]),
  );
  $("modal-actions").replaceChildren(...actions);
  if (!$("modal").open) $("modal").showModal();
}
function notice(message, title = "提示") {
  modal(title, message, [
    el("button", { class: "primary", onclick: closeModal }, "知道了"),
  ]);
}
async function perform(action, button) {
  if (button) button.disabled = true;
  try {
    return await action();
  } catch (error) {
    notice(error.message, "操作未完成");
    return null;
  } finally {
    if (button) button.disabled = false;
  }
}
function field(label, input) {
  return el("div", { class: "field" }, el("label", {}, label), input);
}
function formButton(text, action, primary = true) {
  return el(
    "button",
    {
      class: primary ? "primary" : "",
      onclick: (event) => perform(action, event.currentTarget),
    },
    text,
  );
}
function avatar(name, url = "", group = false) {
  const box = el(
    "div",
    { class: "avatar" + (group ? " group" : "") },
    group ? "群" : (name || "?").slice(0, 1),
  );
  const valid = safeUrl(url);
  if (valid && !group) {
    const img = el("img", {
      src: valid,
      alt: "",
      loading: "lazy",
      referrerpolicy: "no-referrer",
    });
    img.addEventListener("error", () => img.remove(), { once: true });
    box.append(img);
  }
  return box;
}
function draftKey() {
  return `${S.state?.config.appId || ""}/${S.session}/${S.format}`;
}
function saveDraft() {
  S.drafts.set(draftKey(), $("draft").value);
}
function restoreDraft() {
  $("draft").value = S.drafts.get(draftKey()) || "";
  updatePreview();
}
function setTheme(value) {
  if (!["light", "dark", "system"].includes(value)) value = "system";
  const dark =
    value === "dark" ||
    (value === "system" && matchMedia("(prefers-color-scheme: dark)").matches);
  document.documentElement.dataset.theme = dark ? "dark" : "light";
  $("theme").value = value;
  try {
    localStorage.setItem("qqm-theme", value);
  } catch {}
}
let theme = "system";
try {
  theme = localStorage.getItem("qqm-theme") || theme;
} catch {}
setTheme(theme);
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
  if ($("theme").value === "system") setTheme("system");
});
$("theme").addEventListener("change", (event) => setTheme(event.target.value));
$("modal-close").onclick = closeModal;
$("browser-close").onclick = () => {
  $("web-browser").close();
  $("browser-frame").removeAttribute("src");
};
function openBrowser(value) {
  const url = safeUrl(value);
  if (!url) return;
  const parsed = new URL(url);
  if (parsed.protocol !== "https:") {
    notice("内嵌浏览页仅支持 HTTPS 网页。你可以复制链接：\n" + url);
    return;
  }
  $("browser-url").value = url;
  $("browser-frame").src = url;
  if (!$("web-browser").open) $("web-browser").showModal();
}
document.addEventListener("click", (event) => {
  const anchor = event.target.closest("a");
  if (!anchor || anchor.classList.contains("brand") || anchor.download) return;
  const url = safeUrl(anchor.href);
  if (url) {
    event.preventDefault();
    if (event.repeat) return;
    openBrowser(url);
  }
});
async function copyText(text) {
  if (navigator.clipboard && isSecureContext) {
    await navigator.clipboard.writeText(text);
    return;
  }
  const input = el("textarea", { readonly: "" }, text);
  document.body.append(input);
  input.select();
  const ok = document.execCommand("copy");
  input.remove();
  if (!ok) throw Error("浏览器不允许自动复制，请手动选择文字。");
}
$("browser-copy").onclick = (event) =>
  perform(async () => {
    await copyText($("browser-url").value);
    notice("链接已复制");
  }, event.currentTarget);
function download(name, source, type = "text/plain") {
  const url = URL.createObjectURL(new Blob([source], { type }));
  const link = el("a", { href: url, download: name });
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 3000);
}
function inlineMarkdown(text, parent) {
  // All rendered content is DOM text. Never interpret chat/plugin HTML.
  const token =
    /(<qqbot-at-user\s+id="([^"\n]+)"\s*\/>)|(`([^`]+)`)|(\*\*([^*]+)\*\*)|(!?\[([^\]]*)\]\((https?:\/\/[^\s)]+)\))|(<qqbot-at-everyone\s*\/>)/g;
  let end = 0;
  for (const match of text.matchAll(token)) {
    parent.append(text.slice(end, match.index));
    if (match[1]) {
      const id = match[2];
      const name = S.messages.find((m) => m.senderId === id)?.senderName || id;
      parent.append(el("strong", {}, `@${name}（${id}）`));
    } else if (match[10]) parent.append(el("strong", {}, "@全体成员"));
    else if (match[3]) parent.append(el("code", {}, match[4]));
    else if (match[5]) parent.append(el("strong", {}, match[6]));
    else {
      const url = safeUrl(match[9]);
      if (url)
        parent.append(
          el(
            "a",
            { href: url, rel: "noopener noreferrer" },
            match[8] || "图片链接",
          ),
        );
      else parent.append(match[0]);
    }
    end = match.index + match[0].length;
  }
  parent.append(text.slice(end));
}
function markdown(source, parent) {
  let code = null;
  for (const line of source.split("\n")) {
    if (/^\s*```/.test(line)) {
      if (code) {
        parent.append(el("pre", {}, el("code", {}, code.join("\n"))));
        code = null;
      } else code = [];
      continue;
    }
    if (code) {
      code.push(line);
      continue;
    }
    let node;
    const heading = /^(#{1,6})\s+(.*)/.exec(line);
    if (heading) {
      node = el("h" + heading[1].length);
      inlineMarkdown(heading[2], node);
    } else if (/^>\s?/.test(line)) {
      node = el("blockquote");
      inlineMarkdown(line.replace(/^>\s?/, ""), node);
    } else {
      node = el("p");
      inlineMarkdown(line || "\u00a0", node);
    }
    parent.append(node);
  }
  if (code) parent.append(el("pre", {}, el("code", {}, code.join("\n"))));
}
function updatePreview() {
  const md = S.format === "markdown";
  $("preview").hidden = !md;
  $("mention").hidden = !md;
  $("mention-everyone").hidden = !md;
  $("compose-area").classList.toggle("markdown", md);
  $("preview").replaceChildren();
  if (md) markdown($("draft").value || "Markdown 实时预览", $("preview"));
  $("draft").placeholder =
    S.format === "image" ? "粘贴 HTTPS 图片链接…" : "输入消息…";
  $("compose-hint").textContent = matchMedia("(pointer: coarse)").matches
    ? "使用发送按钮发送 · 回车换行"
    : "Enter 发送 · Ctrl + Enter 换行";
}
$("draft").addEventListener("input", () => {
  saveDraft();
  updatePreview();
});
$("draft").addEventListener("keydown", (event) => {
  if (
    event.key === "Enter" &&
    !event.isComposing &&
    !event.shiftKey &&
    !matchMedia("(pointer: coarse)").matches
  ) {
    event.preventDefault();
    if (event.ctrlKey || event.metaKey) {
      const input = event.currentTarget;
      input.setRangeText("\n", input.selectionStart, input.selectionEnd, "end");
      saveDraft();
      updatePreview();
    } else if (!event.altKey) $("send").click();
  }
});
document.querySelectorAll("[data-format]").forEach(
  (button) =>
    (button.onclick = () => {
      saveDraft();
      S.format = button.dataset.format;
      document
        .querySelectorAll("[data-format]")
        .forEach((b) => b.classList.toggle("active", b === button));
      restoreDraft();
    }),
);
function clearReply() {
  S.reply = null;
  $("reply-bar").hidden = true;
}
$("cancel-reply").onclick = clearReply;
function bottom() {
  $("messages").scrollTop = $("messages").scrollHeight;
  S.newCount = 0;
  $("new-messages").hidden = true;
}
$("new-messages").onclick = bottom;
$("back-sessions").onclick = () => {
  $("app").classList.remove("chat-open");
};
function selectSession(id) {
  saveDraft();
  S.session = id;
  S.messages = [];
  S.newCount = 0;
  clearReply();
  restoreDraft();
  $("app").classList.add("chat-open");
  renderSessions();
  renderChatHeader();
  perform(async () => {
    await loadMessages(true);
    await post("read", { appId: S.state.config.appId, session: id });
  });
}
function renderChatHeader() {
  const session = S.state.sessions.find((s) => s.id === S.session);
  $("chat-name").textContent = session?.name || "选择一个会话";
  $("chat-detail").textContent = session
    ? `${session.sessionType === 1 ? "群聊" : "单聊"} · ${session.id}`
    : "在左侧打开聊天，或先连接机器人";
  $("chat-avatar").replaceWith(
    Object.assign(
      avatar(session?.name, session?.avatarUrl, session?.sessionType === 1),
      { id: "chat-avatar" },
    ),
  );
  $("send").disabled = !session || S.sending;
}
let historySearchRevision = 0;
let historySearchTimer;
let historySearchCache = null;
async function renderHistorySearch(append = false) {
  const query = $("search").value.trim();
  if (!query || !S.state) return;
  const scope = { appId: S.state.config.appId, epoch: S.state.epoch };
  const key = JSON.stringify([scope.appId, scope.epoch, query, S.filter]);
  const request = ++historySearchRevision;
  try {
    let data;
    if (!append && historySearchCache?.key === key && historySearchCache.revision === S.revision) {
      data = historySearchCache.data;
    } else {
      const previous = append && historySearchCache?.key === key ? historySearchCache.data : null;
      const params = { ...scope, search: query,
        sessionType: S.filter === "all" ? "" : S.filter === "group" ? "1" : "0",
        before: previous?.next || "", beforeSession: previous?.nextSession || "" };
      const result = await api("history/search?" + new URLSearchParams(params));
      data = previous ? { ...result, messages: [...previous.messages, ...result.messages] } : result;
    }
    if (request !== historySearchRevision || !currentHistory(scope) || query !== $("search").value.trim()) return;
    historySearchCache = { key, revision: S.revision, data };
    $("sessions").replaceChildren(el("p", { class: "search-count muted" }, `${data.count} 条本地聊天记录`),
      ...data.messages.map(message => el("button", {
        class: "session-item history-search-result", "data-message-id": message.id,
        onclick: () => window.openQQMHistory?.(message.sessionId, message.id, scope),
      }, avatar(message.sessionName, message.sessionAvatarUrl, message.sessionType === 1),
      el("div", { class: "grow" }, el("div", { class: "session-name" }, message.sessionName),
        el("div", { class: "session-time" }, `${message.senderName || "消息"} · ${nowTime(message.time)}`),
        el("div", { class: "search-snippet" }, message.snippet)))));
    if (!data.count) $("sessions").append(el("p", { class: "empty" }, "没有找到聊天记录，试试正文、引用或语音转写。"));
    if (data.next) $("sessions").append(el("button", { class: "search-more", onclick: () => renderHistorySearch(true) }, "加载更多搜索结果"));
  } catch (error) {
    if (request === historySearchRevision && currentHistory(scope)) $("sessions").replaceChildren(el("p", { class: "empty" }, error.message));
  }
}
function renderSessions() {
  const query = $("search").value.trim().toLowerCase();
  if (query) { void renderHistorySearch(); return; }
  historySearchRevision++;
  historySearchCache = null;
  const list = S.state.sessions.filter(
    (s) => S.filter === "all" || (S.filter === "group") === (s.sessionType === 1),
  );
  $("sessions").replaceChildren(
    ...list.map((session) => {
      const meta = el(
        "div",
        {},
        el("div", { class: "session-time" }, nowTime(session.lastMessageTime)),
      );
      if (session.unreadCount)
        meta.append(
          el("span", { class: "unread" }, Math.min(session.unreadCount, 99)),
        );
      if (session.isMuted)
        meta.append(el("span", { title: "已屏蔽消息提醒" }, "静音"));
      const item = el(
        "button",
        {
          class: "session-item" + (session.id === S.session ? " active" : ""),
          onclick: () => selectSession(session.id),
        },
        avatar(session.name, session.avatarUrl, session.sessionType === 1),
        el(
          "div",
          { class: "grow" },
          el("div", { class: "session-name" }, session.name),
          el(
            "div",
            { class: "session-summary" },
            session.lastMessage || "暂无消息",
          ),
        ),
        meta,
      );
      window.bindQQMSessionMenu?.(item, session);
      return item;
    }),
  );
  if (!list.length)
    $("sessions").append(
      el(
        "div",
        { class: "empty" },
        el("p", {}, "暂无会话"),
        el("p", {}, "连接机器人后，在 QQ 中发送一条消息。"),
      ),
    );
}
$("search").oninput = () => {
  clearTimeout(historySearchTimer);
  historySearchRevision++;
  historySearchCache = null;
  if (!S.state) return;
  if (!$("search").value.trim()) { renderSessions(); return; }
  $("sessions").replaceChildren(el("p", { class: "empty" }, "正在搜索本地聊天记录…"));
  historySearchTimer = setTimeout(renderSessions, 220);
};
document.querySelectorAll("[data-filter]").forEach(
  (button) =>
    (button.onclick = () => {
      S.filter = button.dataset.filter;
      document
        .querySelectorAll("[data-filter]")
        .forEach((b) => b.classList.toggle("active", b === button));
      renderSessions();
    }),
);
function renderReceived(body, parent, message) {
  if (body.author) parent.append(el("small", { class: "muted" }, body.author));
  if (body.text) parent.append(el("p", {}, body.text));
  for (const a of body.attachments || []) {
    const url = safeUrl(a.url);
    if (!url) continue;
    if (a.isVoice && window.renderQQMVoice) {
      window.renderQQMVoice(a, parent, message);
    } else if (a.isVideo) {
      parent.append(el("video", { src: url, controls: "", preload: "none", class: "message-video" }));
    } else if (a.isImage) {
      const img = el("img", {
        src: url,
        alt: a.filename || "图片",
        loading: "lazy",
        referrerpolicy: "no-referrer",
      });
      img.addEventListener(
        "error",
        () =>
          img.replaceWith(el("a", { href: url }, "图片暂不可用，点击查看链接")),
        { once: true },
      );
      parent.append(img);
    } else parent.append(el("a", { href: url }, a.filename || "附件"));
  }
  if (body.card) {
    const url = safeUrl(body.card.url);
    const preview = safeUrl(body.card.preview);
    if (preview) parent.append(el("img", {src: preview, alt: body.card.title || "卡片预览", loading: "lazy", referrerpolicy: "no-referrer"}));
    parent.append(
      url
        ? el("a", { href: url }, body.card.title)
        : el("strong", {}, body.card.title),
      el("p", {}, body.card.description),
    );
  }
  for (const child of body.elements || []) {
    const details = el("details", {}, el("summary", {}, "展开引用 / 聊天记录"));
    renderReceived(child, details, message);
    parent.append(details);
  }
}
function renderMessages() {
  const area = $("messages"),
    top = area.scrollTop;
  const expanded = new Set();
  const existing = new Map([...area.querySelectorAll("[data-render-id]")].map(node => [node.dataset.renderId, node]));
  const desired = [];
  for (const article of area.querySelectorAll("[data-render-id]")) {
    [...article.querySelectorAll("details")].forEach((detail, index) => {
      if (detail.open) expanded.add(article.dataset.renderId + ":" + index);
    });
  }
  for (const message of S.messages) {
    const key = `${S.state.config.appId}/${S.state.epoch}/${S.session}/${message.id}`;
    const payload = JSON.stringify(message);
    const previous = existing.get(key);
    if (previous && previous.qqmPayload === payload) { desired.push(previous); continue; }
    const bubble = el("div", { class: "bubble" });
    if (message.isRecalled)
      bubble.append(el("span", { class: "muted" }, "这条消息已撤回"));
    else {
      if (message.markdownContent) markdown(message.markdownContent, bubble);
      else if (message.body) renderReceived(message.body, bubble, message);
      else bubble.append(message.content || "");
      const image = safeUrl(message.imageUrl);
      if (image)
        bubble.append(
          el("img", {
            src: image,
            alt: "图片",
            loading: "lazy",
            referrerpolicy: "no-referrer",
          }),
        );
    }
    const main = el(
      "div",
      { class: "message-main" },
      el(
        "div",
        { class: "message-byline" },
        el("span", {}, message.senderName || "机器人"),
        el("time", {}, nowTime(message.time)),
      ),
      bubble,
    );
    if (!message.isRecalled)
      main.append(
        el(
          "button",
          {
            class: "quote",
            onclick: () => {
              S.reply = message;
              $("reply-label").textContent =
                `引用 ${message.senderName}：${message.content || message.markdownContent || "消息"}`;
              $("reply-bar").hidden = false;
              $("draft").focus();
            },
          },
          "引用",
        ),
      );
    if (message.canRecall)
      main.append(
        el(
          "button",
          { class: "quote", onclick: () => window.recallQQMMessage?.(message) },
          "撤回",
        ),
      );
    const senderAvatar = avatar(message.senderName, message.senderAvatarUrl);
    window.bindQQMMemberMenu?.(senderAvatar, message,
      S.state.sessions.find((session) => session.id === S.session));
    const article = el(
        "article",
        {
          class: "message" + (message.isFromBot ? " mine" : ""),
          "data-render-id": key,
        },
        senderAvatar,
        main,
    );
    article.qqmPayload = payload;
    desired.push(article);
  }
  if (!S.messages.length)
    desired.push(
      el("div", { class: "empty" }, el("p", {}, "这里还没有聊天记录")),
    );
  const keep = new Set(desired);
  for (const node of [...area.children]) if (!keep.has(node)) node.remove();
  desired.forEach((node, index) => { if (area.children[index] !== node) area.insertBefore(node, area.children[index] || null); });
  for (const article of area.querySelectorAll("[data-render-id]")) {
    [...article.querySelectorAll("details")].forEach((detail, index) => {
      if (expanded.has(article.dataset.renderId + ":" + index))
        detail.open = true;
    });
  }
  area.scrollTop = top;
}
async function loadMessages(toBottom = false) {
  if (!S.session || !S.logged) return;
  const appId = S.state.config.appId,
    id = S.session;
  const data = await api(
    `messages?appId=${encodeURIComponent(appId)}&session=${encodeURIComponent(id)}`,
  );
  if (S.state.config.appId !== appId || S.session !== id) return;
  const changed = JSON.stringify(data.messages) !== JSON.stringify(S.messages);
  if (changed) {
    const known = new Set(S.messages.map((m) => m.id));
    S.newCount += data.messages.filter(
      (m) => !known.has(m.id) && !m.isFromBot,
    ).length;
    S.messages = data.messages;
    renderMessages();
    if (!toBottom && S.newCount) {
      $("new-messages").textContent = `${S.newCount} 条新消息 ↓`;
      $("new-messages").hidden = false;
    }
  }
  if (toBottom) {
    bottom();
    requestAnimationFrame(bottom);
  }
}
$("send").onclick = async (event) => {
  if (S.sending) return;
  S.sending = true;
  await perform(async () => {
    if (!S.session) throw Error("请先选择会话");
    const body = {
      appId: S.state.config.appId,
      session: S.session,
      format: S.format,
      content: $("draft").value,
      replyId: S.reply?.id || "",
    };
    if (!body.content.trim()) throw Error("消息不能为空");
    await post("send", body);
    const sentKey = `${body.appId}/${body.session}/${body.format}`;
    if (S.drafts.get(sentKey) === body.content) S.drafts.delete(sentKey);
    if (body.appId === S.state.config.appId && body.session === S.session) {
      if (S.format === body.format && $("draft").value === body.content) {
        $("draft").value = "";
        saveDraft();
      }
      if ((S.reply?.id || "") === body.replyId) clearReply();
      updatePreview();
      await loadMessages(true);
    }
    await refresh(true);
  }, event.currentTarget);
  S.sending = false;
  if (S.state) renderChatHeader();
};
$("mention").onclick = () => {
  const session = S.state.sessions.find((s) => s.id === S.session);
  if (session?.sessionType !== 1) {
    notice("@ 成员只能用于群聊 Markdown");
    return;
  }
  const members = new Map(
    S.messages
      .filter((m) => !m.isFromBot)
      .map((m) => [m.senderId, m.senderName]),
  );
  const input = el("input", { placeholder: "成员 OpenID" }),
    list = el(
      "select",
      { "aria-label": "选择群成员" },
      el("option", { value: "" }, "选择已收到消息的群成员"),
      ...[...members].map(([id, name]) =>
        el("option", { value: id }, name || id),
      ),
    );
  list.onchange = () => {
    input.value = list.value;
  };
  modal(
    "@ 群成员",
    [field("已知群成员", list), field("成员 OpenID", input)],
    [
      formButton("插入 Markdown", async () => {
        const id = input.value.trim();
        if (!/^[A-Za-z0-9_-]{1,128}$/.test(id))
          throw Error("请输入有效的成员 OpenID");
        const textarea = $("draft");
        textarea.setRangeText(
          `<qqbot-at-user id="${id}" />`,
          textarea.selectionStart,
          textarea.selectionEnd,
          "end",
        );
        saveDraft();
        updatePreview();
        closeModal();
      }),
    ],
  );
};
$("mention-everyone").onclick = () => window.mentionQQMMember?.(null);
function renderPlugins() {
  $("plugins").replaceChildren(
    ...S.state.plugins.map((plugin) => {
      const toggle = el("input", {
        type: "checkbox",
        "aria-label": `启用${plugin.name}`,
      });
      toggle.checked = plugin.enabled;
      toggle.onchange = () =>
        perform(async () => {
          await post("plugins/toggle", {
            id: plugin.id,
            enabled: toggle.checked,
          });
          await refresh(true);
        }, toggle).then((result) => {
          if (result === null) toggle.checked = plugin.enabled;
        });
      return el(
        "section",
        { class: "plugin-card" },
        el(
          "div",
          { class: "plugin-top" },
          el("div", { class: "avatar" }, "▧"),
          el(
            "div",
            {},
            el("h3", {}, plugin.name),
            el(
              "p",
              { class: "muted" },
              `${plugin.bundled ? "随附插件" : "第三方插件"} · ${plugin.version}`,
            ),
          ),
          el("label", { class: "switch" }, toggle),
        ),
        el("p", { class: "plugin-description" }, plugin.description),
        el(
          "p",
          { class: "plugin-commands" },
          plugin.commands.join(" · ") || "按插件规则运行",
        ),
        ...(plugin.error ? [el("p", { class: "error" }, plugin.error)] : []),
        el(
          "div",
          { class: "button-row" },
          formButton("配置", () => configurePlugin(plugin), false),
          formButton("编辑源码", () => editPlugin(plugin.id), false),
          formButton(
            "导出",
            async () => {
              const data = await api("plugins/source?id=" + plugin.id);
              download(plugin.id + ".json", data.source, "application/json");
            },
            false,
          ),
        ),
      );
    }),
  );
}
async function configurePlugin(plugin) {
  const data = await api("plugins/source?id=" + plugin.id);
  const input = el("textarea", { "aria-label": "插件 JSON 配置" });
  input.value = JSON.stringify(data.config, null, 2);
  modal(
    plugin.name + " · 配置",
    [
      el(
        "p",
        { class: "hint" },
        "配置 Key 仅用于对应插件。不要导出或分享含密钥的配置。",
      ),
      input,
    ],
    [
      formButton("保存配置", async () => {
        let config;
        try {
          config = JSON.parse(input.value);
        } catch {
          throw Error("JSON 格式无效");
        }
        await post("plugins/config", { id: plugin.id, config });
        closeModal();
        await refresh(true);
      }),
    ],
  );
}
async function editPlugin(id) {
  await post("workspace/seed", { id });
  const tree = await api("workspace?id=" + encodeURIComponent(id));
  const files = el("div", { class: "editor-files" }),
    editor = el("textarea", {
      class: "editor-textarea",
      "aria-label": "插件源码",
      spellcheck: "false",
    }),
    label = el("p", { class: "hint" });
  let current = "",
    expected = "",
    dirty = false;
  async function open(file) {
    if (dirty && !confirm("当前文件尚未保存，放弃修改并打开另一个文件？"))
      return;
    const data = await api(
      `workspace/read?id=${encodeURIComponent(id)}&file=${encodeURIComponent(file)}`,
    );
    current = file;
    expected = data.source;
    editor.value = expected;
    dirty = false;
    label.textContent = `${id} / ${file}`;
  }
  editor.oninput = () => {
    dirty = true;
  };
  for (const file of tree.files)
    files.append(formButton(file, () => open(file), false));
  modal(
    "插件文件 · " + id,
    [
      el(
        "p",
        { class: "hint" },
        "保存只更新工作区；安装后替换插件，默认保持关闭。旧文件会保留历史，多个编辑器同时修改时拒绝覆盖。",
      ),
      label,
      el("div", { class: "editor-layout" }, files, editor),
    ],
    [
      formButton(
        "保存文件",
        async () => {
          if (!current) throw Error("请选择文件");
          await post("workspace/write", {
            id,
            file: current,
            source: editor.value,
            expected,
          });
          expected = editor.value;
          dirty = false;
          label.textContent = `${id} / ${current} · 已保存`;
        },
        false,
      ),
      formButton("安装 / 替换插件", async () => {
        if (dirty) throw Error("请先保存文件");
        await post("workspace/install", { id, replace: true });
        closeModal();
        await refresh(true);
        notice("插件已安装并停用，请检查配置后手动开启。");
      }),
    ],
  );
  if (tree.files.length)
    await open(tree.files.includes("main.ht") ? "main.ht" : tree.files[0]);
}
$("import-plugin").onclick = () => {
  const input = el("textarea", {
      "aria-label": "插件清单",
      placeholder: "粘贴完整 JSON / YAML 插件清单，脚本插件需含 script.source",
    }),
    file = el("input", { type: "file", accept: ".json,.yaml,.yml" }),
    replace = el("input", { type: "checkbox" });
  file.onchange = () =>
    perform(async () => {
      const value = file.files[0];
      if (!value) return;
      if (value.size > 262144) throw Error("插件文件不能超过 256 KB");
      input.value = await value.text();
    });
  modal(
    "导入插件",
    [
      field("选择文件（JSON / YAML）", file),
      field("完整插件定义", input),
      el(
        "label",
        { class: "toggle" },
        replace,
        "确认替换相同 ID 的插件（默认关闭）",
      ),
    ],
    [
      formButton("导入并保持关闭", async () => {
        await post("plugins/import", {
          source: input.value,
          replace: replace.checked,
        });
        closeModal();
        await refresh(true);
        notice("插件已导入。请先检查配置，再手动启用。");
      }),
    ],
  );
};
function renderLogs() {
  const area = $("logs"),
    top = area.scrollTop;
  area.replaceChildren(
    ...S.logs.map((log) =>
      el(
        "span",
        {
          class:
            "log-line " +
            (/失败|异常|错误|error/i.test(log.text)
              ? "error"
              : /成功|已连接|已发送|在线/.test(log.text)
                ? "success"
                : /警告|注意|重连|未配置/.test(log.text)
                  ? "warning"
                  : ""),
        },
        `[${nowTime(log.time)}] ${log.text}`,
      ),
    ),
  );
  area.scrollTop = top;
}
async function loadLogs() {
  const data = await api("logs");
  S.logs = data.logs;
  renderLogs();
}
const logText = () =>
  S.logs
    .map((log) => `[${new Date(log.time).toLocaleString("zh-CN")}] ${log.text}`)
    .join("\n");
$("copy-logs").onclick = (event) =>
  perform(async () => {
    await loadLogs();
    await copyText(logText());
    notice("全部日志已复制");
  }, event.currentTarget);
for (const [id, ext] of [
  ["export-logs", "txt"],
  ["export-log", "log"],
])
  $(id).onclick = (event) =>
    perform(async () => {
      await loadLogs();
      download(
        `qqm-${S.state.version}-build${S.state.build}-${new Date().toISOString().slice(0, 10)}.${ext}`,
        logText(),
      );
    }, event.currentTarget);
function changePage(page) {
  S.page = page;
  document
    .querySelectorAll("[data-page]")
    .forEach((button) =>
      button.classList.toggle("active", button.dataset.page === page),
    );
  for (const name of ["chat", "plugins", "logs", "settings"])
    $("page-" + name).hidden = name !== page;
  $("page-title").textContent = {
    chat: "消息工作台",
    plugins: "插件中心",
    logs: "运行日志",
    settings: "应用设置",
  }[page];
  $("app").classList.toggle("chat-open", page === "chat" && !!S.session);
  if (page === "logs") perform(loadLogs);
  if (page === "settings") fillConfig(true);
}
document
  .querySelectorAll("[data-page]")
  .forEach(
    (button) => (button.onclick = () => changePage(button.dataset.page)),
  );
let filledAppId = null;
function fillConfig(force = false) {
  const config = S.state.config;
  if (!force && filledAppId === config.appId) return;
  filledAppId = config.appId;
  $("app-id").value = config.appId;
  $("bot-secret").value = "";
  $("auto-reconnect").checked = config.autoReconnect;
  $("receive-all").checked = config.receiveAllGroupMessages;
  $("respond-all").checked = config.autoReplyToAllGroupMessages;
  $("oiapi").checked = config.enableOiapiNickname;
  $("sandbox").checked = config.useSandbox;
}
$("config-form").onsubmit = (event) => {
  event.preventDefault();
  perform(async () => {
    await post("config", {
      appId: $("app-id").value,
      clientSecret: $("bot-secret").value,
      autoReconnect: $("auto-reconnect").checked,
      receiveAllGroupMessages: $("receive-all").checked,
      autoReplyToAllGroupMessages: $("respond-all").checked,
      enableOiapiNickname: $("oiapi").checked,
      useSandbox: $("sandbox").checked,
    });
    $("bot-secret").value = "";
    await refresh(true);
    notice("机器人配置已保存，点击顶部按钮连接。");
  }, event.submitter);
};
$("bot-picker").onchange = (event) =>
  perform(async () => {
    saveDraft();
    await post("switch", { appId: event.target.value });
    await refresh(true);
  });
$("connect").onclick = (event) =>
  perform(async () => {
    if (!S.state.config.hasSecret) {
      changePage("settings");
      notice("请先填写 AppID 和机器人密钥");
      return;
    }
    await post(S.state.connected ? "disconnect" : "connect", {
      appId: S.state.config.appId,
    });
    await refresh(true);
  }, event.currentTarget);
$("add-session").onclick = () => {
  const name = el("input", { placeholder: "会话名称（可选）" }),
    id = el("input", { placeholder: "用户或群的 OpenID，不是 QQ 号" }),
    type = el(
      "select",
      {},
      el("option", { value: "private" }, "单聊"),
      el("option", { value: "group" }, "群聊"),
    );
  modal(
    "新增会话",
    [field("类型", type), field("OpenID", id), field("名称", name)],
    [
      formButton("创建会话", async () => {
        await post("session", {
          appId: S.state.config.appId,
          id: id.value,
          name: name.value,
          isGroup: type.value === "group",
        });
        closeModal();
        await refresh(true);
        selectSession(id.value.trim());
      }),
    ],
  );
};
async function lookupIp() {
  const data = await api("ip");
  if (!data.ips.length)
    throw Error(
      "所有 IPv4 接口暂时不可用，请检查服务器 IPv4 路由或代理后重试。不会使用 IPv6 代替。",
    );
  return data.ips.join("\n");
}
$("lookup-ip").onclick = (event) =>
  perform(
    async () => notice(await lookupIp(), "服务器公网出口 IPv4"),
    event.currentTarget,
  );
function ipProblem(problem) {
  if (!problem) return;
  const key = problem.appId + "|" + problem.message;
  if (S.notice === key) return;
  S.notice = key;
  const output = el(
    "p",
    { class: "dialog-text" },
    problem.sourceIp
      ? `QQ 返回的源 IP：${problem.sourceIp}`
      : "QQ 未返回源 IP。请先查询服务器 IPv4。",
  );
  modal(
    "QQ 接口 IP 白名单",
    [
      el("p", { class: "dialog-text" }, problem.message),
      output,
      el(
        "p",
        { class: "hint" },
        "进入当前机器人的开发设置，将实际请求出口 IP 加入白名单并保存。不同代理可能具有不同出口。",
      ),
    ],
    [
      formButton(
        "查询服务器 IPv4",
        async () => {
          output.textContent = "服务器公网出口 IPv4：" + (await lookupIp());
        },
        false,
      ),
      formButton("打开机器人设置", async () => {
        closeModal();
        openBrowser(problem.url);
      }),
      formButton(
        "已处理",
        async () => {
          await post("ip/dismiss");
          closeModal();
        },
        false,
      ),
    ],
  );
}
async function refresh(force = false) {
  if (S.polling) return S.polling;
  S.polling = (async () => {
    const data = await api("state" + (force ? "" : "?revision=" + S.revision));
    if (data.unchanged) {
      if (S.page === "logs") await loadLogs();
      return;
    }
    const old = S.state?.config.appId;
    if (old !== undefined && old !== data.config.appId) {
      $("search").value = "";
      saveDraft();
      S.session = "";
      S.messages = [];
      clearReply();
      $("app").classList.remove("chat-open");
      $("messages").replaceChildren(
        el(
          "div",
          { class: "empty" },
          el("p", {}, "已切换机器人，请选择新会话"),
        ),
      );
    }
    S.state = data;
    window.dispatchEvent(new Event("qqm-state"));
    window.onQQMRefresh?.(data);
    S.revision = data.revision;
    $("version").textContent = `${data.version}+${data.build} · Linux 网页版`;
    $("status").textContent = data.status;
    $("status").classList.toggle("online", data.connected);
    $("connect").textContent = data.connected
      ? "断开连接"
      : data.connecting
        ? "连接中…"
        : "连接机器人";
    $("connect").disabled = data.connecting;
    const picker = $("bot-picker");
    picker.replaceChildren(
      ...data.bots.map((bot) =>
        el(
          "option",
          { value: bot.appId },
          bot.appId === data.config.appId && data.botName
            ? data.botName
            : bot.displayName || bot.appId,
        ),
      ),
    );
    picker.value = data.config.appId;
    picker.hidden = data.bots.length === 0;
    renderSessions();
    renderChatHeader();
    renderPlugins();
    fillConfig();
    if (old !== data.config.appId) restoreDraft();
    if (S.session) await loadMessages();
    if (S.page === "logs") await loadLogs();
    if (data.ipProblem && !$("modal").open) ipProblem(data.ipProblem);
    $("network-banner").hidden = true;
  })().finally(() => {
    S.polling = null;
  });
  return S.polling;
}
async function enter() {
  S.logged = true;
  $("auth-loading").hidden = true;
  $("setup-view").hidden = true;
  $("entrance-view").hidden = true;
  $("login-view").hidden = true;
  $("app").hidden = false;
  await refresh(true);
  updatePreview();
}
$("setup-form").onsubmit = (event) => {
  event.preventDefault();
  perform(async () => {
    const password = $("setup-password").value;
    const confirmation = $("setup-confirm").value;
    if (password !== confirmation) throw Error("两次输入的管理密码不一致");
    if ([...password].length < 12 || password.length > 256 || !password.trim())
      throw Error("管理密码需为 12–256 个字符，不能只含空白");
    const data = await post("setup", {
      token: $("setup-token").value.trim(),
      password,
      confirmation,
      entrance: $("setup-entrance").value,
    });
    $("setup-form").reset();
    openEntrance(data);
  }, event.submitter);
};
$("entrance-form").onsubmit = (event) => {
  event.preventDefault();
  perform(async () => {
    openEntrance(await post("auth/entrance", { entrance: $("migration-entrance").value }));
  }, event.submitter);
};
$("login-form").onsubmit = (event) => {
  event.preventDefault();
  perform(async () => {
    const data = await post("login", { password: $("password").value });
    $("password").value = "";
    if (data.needsEntrance) return showEntrance();
    S.revision = -1;
    await enter();
  }, event.submitter);
};
$("logout").onclick = (event) =>
  perform(async () => {
    await post("logout");
    showLogin();
  }, event.currentTarget);
$("settings-logout").onclick = $("logout").onclick;
setInterval(() => {
  if (!S.logged || document.hidden) return;
  refresh()
    .then(() => {
      $("network-banner").hidden = true;
    })
    .catch(() => {
      if (S.logged) $("network-banner").hidden = false;
    });
}, 1500);
async function initializeAuth() {
  $("login-view").hidden = true;
  $("setup-view").hidden = true;
  $("entrance-view").hidden = true;
  $("auth-loading").hidden = false;
  $("auth-loading-message").textContent = "正在检查管理密码设置…";
  $("auth-retry").hidden = true;
  try {
    const status = await api("auth/status");
    if (status.needsSetup) return showSetup();
    showLogin();
    try {
      const data = await api("state");
      S.state = data;
      await enter();
      if (initialFragment === "#welcome")
        notice("请收藏完整安全入口：" + location.origin + location.pathname + "。根地址和错误入口不再显示登录页。", "安全入口已启用");
    } catch (error) {
      if (error.needsEntrance) return showEntrance();
      showLogin();
    }
  } catch {
    $("auth-loading-message").textContent =
      "暂时无法连接管理服务，请检查服务和网络后重试。";
    $("auth-retry").hidden = false;
  }
}
$("auth-retry").onclick = initializeAuth;
initializeAuth();
