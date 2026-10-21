// Independent local history, scoped to one bot, credential epoch and chat.
const historyPage = el("dialog", { class: "history-page", "aria-label": "聊天记录页面" });
document.body.append(historyPage);
let historyScope = null;
let historyRequest = 0;
function currentHistory(scope) {
  return scope && scope.appId === S.state?.config.appId && scope.epoch === S.state.epoch;
}
function closeHistory() { historyRequest++; historyScope = null; historyPage.replaceChildren(); historyPage.close(); }
historyPage.addEventListener("cancel", () => { historyRequest++; historyScope = null; historyPage.replaceChildren(); });
window.addEventListener("qqm-state", () => {
  if (historyPage.open && !currentHistory(historyScope)) closeHistory();
});

window.mentionQQMMember = (id, ref) => {
  const session = S.state?.sessions.find(s => s.id === S.session);
  if (ref && (ref.appId !== S.state.config.appId || ref.epoch !== S.state.epoch || ref.group !== S.session)) {
    notice("会话已变化，请返回原聊天后再 @"); return;
  }
  if (session?.sessionType !== 1) { notice("@ 成员只能用于群聊 Markdown"); return; }
  if (S.sending) { notice("消息正在发送，请稍后再试"); return; }
  if (id !== null && !/^[A-Za-z0-9_-]{1,128}$/.test(id)) { notice("成员 OpenID 无效"); return; }
  closeHistory();
  const plainDraft = S.format === "text" ? $("draft").value : "";
  const button = document.querySelector('[data-format="markdown"]');
  if (S.format !== "markdown") button.click();
  const draft = $("draft");
  if (!draft.value && plainDraft) { draft.value = plainDraft; draft.setSelectionRange(plainDraft.length, plainDraft.length); }
  draft.setRangeText(id === null ? "<qqbot-at-everyone /> " : `<qqbot-at-user id="${id}" /> `,
    draft.selectionStart, draft.selectionEnd, "end");
  draft.dispatchEvent(new Event("input")); draft.focus();
};

window.renderQQMVoice = (attachment, parent, message) => {
  const source = safeUrl(attachment.url);
  if (!source) return;
  const audio = el("audio", { controls: "", preload: "none", src: source, class: "voice-player" });
  audio.addEventListener("play", () => document.querySelectorAll("audio").forEach(other => { if (other !== audio) other.pause(); }));
  const scope = { appId: S.state.config.appId, epoch: S.state.epoch, session: historyScope?.session || S.session,
    message: message.id, index: attachment.voiceIndex };
  const exportAudio = () => perform(async () => {
    if (!currentHistory(scope)) throw Error("机器人已切换，请重新打开语音");
    const response = await fetch(new URL("api/voice?" + new URLSearchParams(scope), location.href),
      { credentials: "same-origin", cache: "no-store", headers: { "X-QQM-Request": "1" } });
    if (!response.ok) throw Error((await response.json()).error || "下载失败");
    if (!currentHistory(scope)) return;
    const filename = /filename="([A-Za-z0-9.-]+)"/.exec(response.headers.get("content-disposition") || "")?.[1] || "QQ-voice.bin";
    download(filename, await response.arrayBuffer(), response.headers.get("content-type") || "application/octet-stream");
  });
  parent.append(el("div", { class: "voice-block" }, el("small", {}, attachment.filename || "语音消息"), audio, el("div", { class: "button-row" },
    el("button", { onclick: exportAudio }, attachment.voiceWavUrl ? "下载官方 WAV" : "下载语音原文件")),
    attachment.transcript ? el("p", {}, attachment.transcript) : null));
};

window.openQQMHistory = async (sessionId = S.session, messageId = "", ref = null) => {
  if (ref && !currentHistory(ref)) { notice("机器人已切换，请重新搜索"); return; }
  const session = S.state?.sessions.find(s => s.id === sessionId);
  if (!session) { notice("请先打开一个会话"); return; }
  if (session.id !== S.session) selectSession(session.id);
  if (historyPage.open) closeHistory();
  historyScope = { appId: S.state.config.appId, epoch: S.state.epoch, session: session.id };
  const scope = historyScope;
  const search = el("input", { type: "search", placeholder: "搜索成员、正文、引用或语音转写", "aria-label": "搜索聊天记录" });
  const filter = el("select", { "aria-label": "记录类型" }, ...[["all", "全部消息"], ["images", "图片"], ["voice", "语音"], ["files", "文件"]]
    .map(([value, label]) => el("option", { value }, label)));
  const list = el("div", { class: "history-messages" });
  const status = el("p", { class: "muted" }, "正在读取本地记录…");
  let next = "";
  let anchor = messageId;
  const newer = el("button", { hidden: "", onclick: () => { anchor = ""; load(); } }, "已定位消息 · 查看更新的记录");
  const more = el("button", { hidden: "", onclick: () => load(true) }, "加载更早的记录");
  historyPage.replaceChildren(el("header", {}, el("div", {}, el("h2", {}, "聊天记录"), el("small", { class: "muted" }, session.name)),
    el("button", { class: "icon", "aria-label": "返回原聊天", onclick: closeHistory }, "×")),
    el("div", { class: "history-controls" }, search, filter), status, newer, list, el("footer", {}, more));
  historyPage.showModal(); search.focus();
  let timer;
  search.oninput = () => { anchor = ""; clearTimeout(timer); timer = setTimeout(() => load(), 220); };
  filter.onchange = () => { anchor = ""; load(); };
  async function load(append = false) {
    const revision = ++historyRequest;
    try {
      const result = await api("history?" + new URLSearchParams({ ...scope, search: search.value, filter: filter.value, before: append ? next : "", from: anchor }));
      if (revision !== historyRequest || !historyPage.open || !currentHistory(scope)) return;
      if (!append) { list.replaceChildren(); list.scrollTop = 0; }
      for (const message of result.messages) {
        const bubble = el("div", { class: "bubble" });
        if (message.isRecalled) bubble.append("这条消息已撤回");
        else if (message.markdownContent) markdown(message.markdownContent, bubble);
        else if (message.body) renderReceived(message.body, bubble, message);
        else bubble.append(message.content || "");
        if (!message.isRecalled && safeUrl(message.imageUrl)) bubble.append(el("img", { src: safeUrl(message.imageUrl), alt: "图片", loading: "lazy" }));
        const sender = avatar(message.senderName, message.senderAvatarUrl);
        window.bindQQMMemberMenu?.(sender, message, session);
        list.append(el("article", { class: "message" + (message.isFromBot ? " mine" : "") + (message.id === anchor ? " history-located" : ""), "data-message-id": message.id }, sender,
          el("div", { class: "message-main" }, el("div", { class: "message-byline" }, el("span", {}, message.senderName),
            el("time", {}, new Date(message.time).toLocaleString("zh-CN"))), bubble)));
      }
      next = result.next || ""; more.hidden = !next;
      newer.hidden = !anchor;
      status.textContent = `${result.count} 条本地记录 · 新消息在前`;
      if (!result.count) list.append(el("p", { class: "empty" }, "没有符合条件的聊天记录"));
    } catch (error) { if (revision === historyRequest && historyPage.open) status.textContent = error.message; }
  }
  await load();
};
$("chat-history").onclick = () => window.openQQMHistory();
