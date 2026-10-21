"use strict";
// Same authenticated service and bot core as the native screens. No browser
// notification permission is requested: OS alerts are Android/iOS only.
const groupScope = () => ({
  appId: S.state.config.appId,
  epoch: S.state.epoch,
});
const groupTarget = (session, scope = groupScope()) => ({
  ...scope,
  group: session.id,
});
const groupQuery = (values) => new URLSearchParams(values).toString();
const currentGroupScope = (scope) =>
  S.state &&
  scope.appId === S.state.config.appId &&
  scope.epoch === S.state.epoch;
const groupName = (id) =>
  S.state.sessions.find((s) => s.id === id)?.name || `群聊 · ${id}`;
const memberRole = (value) =>
  ({ owner: "群主", admin: "管理员", member: "普通成员" })[value] || "未知角色";
const groupDate = (value) =>
  value && Number.isFinite(Date.parse(value))
    ? new Date(value).toLocaleString("zh-CN")
    : "平台未提供";
const groupRead = (kind, ref, more = {}) =>
  api("group/" + kind + "?" + groupQuery({ ...ref, ...more }));
let noticesPage;
const knownGroupMutes = new Map();
const groupMuteKey = (ref) => `${ref.appId}:${ref.epoch}:${ref.group}`;

window.onQQMRefresh = (data) => {
  $("notice-count").hidden = !data.groupNoticeUnread;
  $("notice-count").textContent =
    data.groupNoticeUnread > 99 ? "99+" : String(data.groupNoticeUnread || 0);
  $("chat-settings").disabled = !S.session;
  const session = data.sessions.find((item) => item.id === S.session);
  $("chat-settings").title =
    session?.sessionType === 1 ? "群聊设置" : "用户设置";
  if (noticesPage?.root.isConnected) {
    if (!currentGroupScope(noticesPage.scope))
      notice("机器人已切换，请重新打开消息与通知。");
    else if (noticesPage.revision !== data.revision)
      noticesPage.reload().catch(() => {});
  }
};
$("top-settings").onclick = () => changePage("settings");
$("notifications").onclick = () => showGroupNotices();
$("chat-settings").onclick = () => {
  const session = S.state.sessions.find((item) => item.id === S.session);
  if (session) showConversationSettings(session);
};

window.bindQQMSessionMenu = (item, session) => {
  const scope = groupScope();
  let timer,
    start,
    held = false;
  const open = () => {
    if (!currentGroupScope(scope)) return;
    held = true;
    modal(session.name, "仅本地免打扰，保留记录，不影响机器人和插件收发。", [
      formButton(
        session.isMuted ? "取消屏蔽消息提醒" : "屏蔽消息提醒",
        async () => {
          await post("session/mute", {
            ...scope,
            session: session.id,
            muted: !session.isMuted,
          });
          closeModal();
          await refresh(true);
        },
      ),
      formButton(
        session.sessionType === 1 ? "群聊设置" : "用户设置",
        () => showConversationSettings(session, scope),
        false,
      ),
      el("button", { onclick: closeModal }, "取消"),
    ]);
  };
  item.addEventListener("contextmenu", (event) => {
    event.preventDefault();
    open();
  });
  item.addEventListener("pointerdown", (event) => {
    held = false;
    if (event.pointerType === "mouse") return;
    start = [event.clientX, event.clientY];
    timer = setTimeout(open, 600);
  });
  item.addEventListener("pointermove", (event) => {
    if (
      start &&
      Math.hypot(event.clientX - start[0], event.clientY - start[1]) > 10
    )
      clearTimeout(timer);
  });
  for (const type of ["pointerup", "pointercancel", "pointerleave"])
    item.addEventListener(type, () => clearTimeout(timer));
  item.addEventListener(
    "click",
    (event) => {
      if (held) {
        event.preventDefault();
        event.stopImmediatePropagation();
        held = false;
      }
    },
    true,
  );
};

function statusBlock(title, data, fields) {
  return el(
    "section",
    { class: "group-card" },
    el("h3", {}, title),
    ...(data.status === "rejected"
      ? [el("p", { class: "group-error" }, data.reason.message)]
      : fields(data.value).map(([key, value]) =>
          el(
            "div",
            { class: "group-field" },
            el("small", {}, key),
            el("p", {}, value ?? "平台未提供"),
          ),
        )),
  );
}
async function showConversationSettings(session, scope = groupScope()) {
  if (!currentGroupScope(scope))
    return notice("机器人已切换，请重新打开会话设置。");
  session = S.state.sessions.find((item) => item.id === session.id) || session;
  const ref = groupTarget(session, scope);
  const panel = el(
    "div",
    { class: "group-panel" },
    el(
      "div",
      { class: "group-profile" },
      avatar(session.name, session.avatarUrl, session.sessionType === 1),
      el(
        "div",
        { class: "grow" },
        el("h3", {}, session.name),
        el("p", { class: "muted group-id" }, "OpenID：" + session.id),
      ),
    ),
  );
  const muted = el("input", { type: "checkbox", "aria-label": "屏蔽消息提醒" });
  muted.checked = !!session.isMuted;
  muted.onchange = () =>
    perform(async () => {
      muted.disabled = true;
      try {
        await post("session/mute", {
          ...scope,
          session: session.id,
          muted: muted.checked,
        });
        await refresh(true);
      } catch (error) {
        muted.checked = !muted.checked;
        throw error;
      } finally {
        muted.disabled = false;
      }
    });
  panel.append(
    el(
      "label",
      { class: "group-card" },
      el("div", { class: "button-row" }, muted, "屏蔽消息提醒"),
      el("p", { class: "hint" }, "保留记录，不影响机器人和插件收发。"),
    ),
  );
  const content = el("div");
  panel.append(content);
  modal(session.sessionType === 1 ? "群聊设置" : "用户设置", panel, [
    el("button", { onclick: closeModal }, "关闭"),
  ]);
  if (session.sessionType !== 1) return;
  content.append(el("p", {}, "正在读取群状态…"));
  const [info, state, mute] = await Promise.allSettled([
    groupRead("info", ref),
    groupRead("bot-state", ref),
    groupRead("mute", ref),
  ]);
  if (!panel.isConnected || !currentGroupScope(scope)) return;
  const administrator =
    state.status === "fulfilled" &&
    ["admin", "owner"].includes(state.value.member_role);
  content.replaceChildren(
    statusBlock("群基本信息", info, (d) => [
      ["群名称", d.group_name],
      [
        "群人数",
        typeof d.group_member_num === "number"
          ? d.group_member_num + " 人"
          : "平台未提供",
      ],
      ["群简介", d.group_finger_memo],
      ["群分类", d.group_class_text],
      [
        "标签",
        Array.isArray(d.group_tags) ? d.group_tags.join(" · ") : "平台未提供",
      ],
    ]),
    statusBlock("机器人群内状态", state, (d) => [
      ["身份", memberRole(d.member_role)],
      ["入群时间", groupDate(d.joined_at)],
      [
        "主动消息",
        d.allow_proactive_msg === true
          ? "已允许"
          : d.allow_proactive_msg === false
            ? "未允许"
            : "平台未提供",
      ],
      [
        "消息接收",
        {
          all: "全部消息",
          only_mention: "仅 @",
          mention_and_context: "@ 及上下文",
        }[d.recv_msg_setting] || "平台未提供",
      ],
    ]),
    statusBlock("群禁言状态", mute, (d) => [
      [
        "全员禁言",
        { none: "未开启", always: "始终禁言", schedule: "定时／周期禁言" }[
          d.global_rule?.mode
        ] || "平台未提供",
      ],
    ]),
  );
  if (mute.status === "fulfilled") {
    const data = mute.value;
    knownGroupMutes.set(
      groupMuteKey(ref),
      new Set(
        (Array.isArray(data.members) ? data.members : []).map(
          (member) => member.member_openid,
        ),
      ),
    );
    for (const rule of data.global_rule?.schedule_rules || [])
      content.append(
        el(
          "p",
          { class: "group-card" },
          `定时禁言 · ${rule.enabled ? "已启用" : "未启用"}：${groupDate(rule.start_at)} → ${groupDate(rule.end_at)}`,
        ),
      );
    for (const rule of data.global_rule?.recurring_rules || [])
      content.append(
        el(
          "p",
          { class: "group-card" },
          `周期禁言 · ${rule.enabled ? "已启用" : "未启用"}：星期 ${(rule.weekdays || []).join("、")} ${rule.start_time}–${rule.end_time}（北京时间）`,
        ),
      );
    const members = Array.isArray(data.members) ? data.members : [];
    for (const member of members)
      content.append(
        el(
          "div",
          { class: "group-card" },
          el(
            "p",
            {},
            `${member.username || member.member_openid} · 到期 ${groupDate(member.mute_expire_at)}`,
          ),
          administrator
            ? formButton(
                "解除禁言",
                () =>
                  setGroupMute(ref, member, true, () =>
                    showConversationSettings(session, scope),
                  ),
                false,
              )
            : null,
        ),
      );
  }
  const memberArea = el("div", { class: "group-members" });
  content.append(
    el(
      "div",
      { class: "button-row" },
      formButton(
        "查看群成员",
        () => loadGroupMembers(ref, memberArea, administrator, session),
        false,
      ),
      formButton("入群申请与群事件", () => showGroupNotices(session.id), false),
    ),
    memberArea,
    el(
      "p",
      { class: "hint" },
      "成员查询需平台内邀／白名单，审核与禁言需机器人为群管理员。全员禁言规则仅展示。",
    ),
  );
}

async function loadGroupMembers(
  ref,
  area,
  administrator,
  session,
  cursor = "",
  seen = new Set(),
) {
  const data = await groupRead("members", ref, { cursor });
  if (!area.isConnected || !currentGroupScope(ref)) return;
  if (!Array.isArray(data.members)) throw Error("成员列表格式异常");
  area.querySelector(".load-more")?.remove();
  if (!cursor) area.replaceChildren(el("h3", {}, "群成员"));
  for (const member of data.members) {
    if (!member.member_openid || seen.has(member.member_openid)) continue;
    seen.add(member.member_openid);
    area.append(
      el(
        "div",
        { class: "group-member" },
        avatar(
          member.username,
          `https://q.qlogo.cn/qqapp/${encodeURIComponent(ref.appId)}/${encodeURIComponent(member.member_openid)}/640`,
        ),
        el(
          "div",
          { class: "grow" },
          el("strong", {}, member.username || member.member_openid),
          el("p", { class: "hint" }, memberRole(member.member_role)),
        ),
        formButton(
          "资料",
          async () => {
            const detail = await groupRead("member", ref, {
              member: member.member_openid,
            });
            if (!currentGroupScope(ref)) return;
            modal(
              "成员资料",
              statusBlock(
                "成员信息",
                { status: "fulfilled", value: detail },
                (d) => [
                  ["昵称", d.username],
                  ["OpenID", d.member_openid],
                  ["身份", memberRole(d.member_role)],
                  ["入群时间", groupDate(d.joined_at)],
                ],
              ),
              [
                ...(administrator &&
                detail.member_role === "member" &&
                !detail.bot
                  ? [
                      formButton("设置禁言", () =>
                        setGroupMute(ref, detail, false, () =>
                          showConversationSettings(session, ref),
                        ),
                      ),
                    ]
                  : []),
                formButton(
                  "返回群设置",
                  () => showConversationSettings(session, ref),
                  false,
                ),
              ],
            );
          },
          false,
        ),
      ),
    );
  }
  if (data.next_cursor && data.next_cursor !== cursor) {
    const next = formButton(
      "加载更多成员",
      () =>
        loadGroupMembers(
          ref,
          area,
          administrator,
          session,
          data.next_cursor,
          seen,
        ),
      false,
    );
    next.classList.add("load-more");
    area.append(next);
  }
  if (!seen.size) area.append(el("p", {}, "平台未返回成员"));
}

function setGroupMute(ref, member, remove, back) {
  const duration = el(
    "select",
    { "aria-label": "禁言时长" },
    ...[
      [5, "5 分钟"],
      [10, "10 分钟"],
      [60, "1 小时"],
      [1440, "1 天"],
      [10080, "7 天"],
      [43200, "30 天"],
    ].map(([value, name]) => el("option", { value }, name)),
  );
  duration.value = "10";
  modal(
    remove ? "解除成员禁言？" : "设置成员禁言",
    [
      el("p", {}, member.username || member.member_openid),
      ...(!remove ? [field("禁言时长", duration)] : []),
    ],
    [
      formButton(remove ? "确认解除" : "确认禁言", async () => {
        if (!currentGroupScope(ref)) throw Error("机器人已切换，请重新打开成员菜单");
        if (!remove) {
          const mute = await groupRead("mute", ref);
          if (!Array.isArray(mute.members)) throw Error("禁言列表格式异常，未提交操作");
          knownGroupMutes.set(groupMuteKey(ref), new Set(mute.members.map(m => m.member_openid)));
        }
        await post("group/mute", {
          ...ref,
          member: member.member_openid,
          operation: remove
            ? "del"
            : knownGroupMutes.get(groupMuteKey(ref))?.has(member.member_openid)
              ? "update"
              : "add",
          ...(!remove
            ? {
                expiresAt: new Date(
                  Date.now() + Number(duration.value) * 60000,
                ).toISOString(),
              }
            : {}),
        });
        await back();
      }),
      formButton("取消", back, false),
    ],
  );
}

window.bindQQMMemberMenu = (element, message, session) => {
  if (session?.sessionType !== 1 || message.isFromBot || message.isBotAuthor || !message.senderId) return;
  const ref = groupTarget(session);
  const member = { member_openid: message.senderId, username: message.senderName };
  const open = () => {
    if (currentGroupScope(ref)) showMemberActions(ref, member).catch(error => notice(error.message));
  };
  element.title = "长按管理此群成员";
  element.setAttribute("aria-label", `管理群成员 ${message.senderName || "用户"}`);
  element.setAttribute("role", "button");
  element.tabIndex = 0;
  element.style.touchAction = "pan-y";
  let timer, start;
  const cancel = () => { clearTimeout(timer); start = null; };
  element.addEventListener("contextmenu", event => { event.preventDefault(); cancel(); open(); });
  element.addEventListener("pointerdown", event => {
    cancel();
    if (event.pointerType === "mouse") return;
    start = [event.clientX, event.clientY];
    timer = setTimeout(() => { cancel(); open(); }, 600);
  });
  element.addEventListener("pointermove", event => {
    if (start && Math.hypot(event.clientX - start[0], event.clientY - start[1]) > 10) cancel();
  });
  for (const type of ["pointerup", "pointercancel", "pointerleave"]) element.addEventListener(type, cancel);
  element.addEventListener("keydown", event => {
    if (["Enter", " ", "ContextMenu"].includes(event.key)) { event.preventDefault(); open(); }
  });
};

async function showMemberActions(ref, summary) {
  if (!currentGroupScope(ref)) return;
  const loading = el("p", {}, "正在核实机器人权限和成员身份…");
  const mention = () => formButton("@ 此成员", () => {
    closeModal(); window.mentionQQMMember?.(summary.member_openid, ref);
  }, false);
  modal("群成员操作", loading, [mention(), el("button", { onclick: closeModal }, "关闭")]);
  let member = summary, permissionError = "";
  try {
    member = await groupRead("moderatable-member", ref, { member: summary.member_openid });
  } catch (error) {
    permissionError = error.message;
  }
  let mute;
  if (!permissionError) {
    try { mute = await groupRead("mute", ref); } catch (_) { /* Recheck on submission. */ }
  }
  if (!loading.isConnected || !$("modal").open || !currentGroupScope(ref)) return;
  const muted = Array.isArray(mute?.members) && mute.members.some(m => m.member_openid === member.member_openid);
  const back = () => showMemberActions(ref, member);
  const allowed = (action) => () => {
    if (permissionError) notice(permissionError, "无法管理此成员");
    else action();
  };
  modal("群成员操作", [
    el("h3", {}, member.username || summary.username || "群成员"),
    el("p", {}, permissionError ? "暂不能执行群管理，点击操作可查看原因。" : muted ? "当前已被禁言" : "禁言及移出均需机器人管理员与平台接口权限。"),
  ], [
    mention(),
    formButton("设置禁言", allowed(() => setGroupMute(ref, member, false, back))),
    ...(muted ? [formButton("解除禁言", () => setGroupMute(ref, member, true, back), false)] : []),
    formButton("踢出群聊", allowed(() => removeGroupMember(ref, member, back)), false),
    el("button", { onclick: closeModal }, "关闭"),
  ]);
}

function removeGroupMember(ref, member, back) {
  if (!currentGroupScope(ref)) return;
  modal("将此成员移出群聊？", [
    el("h3", {}, member.username || "群成员"),
    el("p", {}, "确认后会将该成员踢出当前群聊，不加入群黑名单。此操作不能在管理器中撤销。"),
  ], [
    formButton("确认移出", async () => {
      if (!currentGroupScope(ref)) throw Error("机器人已切换，未提交移出操作");
      await post("group/remove", { ...ref, member: member.member_openid, confirmed: true });
      if (currentGroupScope(ref)) notice("该成员已移出群聊，未加入群黑名单。", "移出成功");
    }),
    formButton("取消", back, false),
  ]);
}

async function showGroupNotices(initialGroup = "") {
  const scope = groupScope();
  const page = {
    scope,
    root: el("div", { class: "group-panel" }),
    revision: -1,
    filter: "all",
    group: initialGroup,
    rows: [],
    cursors: {},
    loading: false,
  };
  noticesPage = page;
  const groupSelect = el("select", { "aria-label": "群通知筛选" });
  const filters = el("div", { class: "button-row group-filters" });
  const list = el("div", { class: "group-notice-list" });
  const syncButton = formButton("同步入群申请", () => sync(), false);
  const more = formButton("下一页申请", () => sync(true), false);
  more.hidden = true;
  const controls = el(
    "div",
    { class: "button-row" },
    groupSelect,
    syncButton,
    more,
  );
  page.root.append(
    el(
      "p",
      { class: "muted" },
      "成员加入、退出与入群审核单独归档，不打断聊天。",
    ),
    controls,
    filters,
    list,
  );
  const statusLabel = (n) =>
    ({
      pending: "待审核",
      approved: "已同意",
      declined: "已拒绝",
      auto_approved: "平台已自动同意",
      info: "通知",
    })[n.status] || "通知";
  const render = () => {
    list.replaceChildren();
    syncButton.disabled = !page.group || page.loading;
    more.hidden = !page.cursors[page.group];
    more.disabled = page.loading;
    const filtered = page.rows.filter(
      (n) =>
        (!page.group || n.groupId === page.group) &&
        {
          all: true,
          unread: !n.isRead,
          pending: n.status === "pending",
          processed: ["approved", "declined", "auto_approved"].includes(
            n.status,
          ),
          joined: n.type === "GROUP_MEMBER_ADD",
          left: n.type === "GROUP_MEMBER_REMOVE",
        }[page.filter],
    );
    for (const n of filtered) {
      const verify = n.details?.verify_info;
      const title =
        {
          GROUP_JOIN_REQUEST: "入群申请",
          GROUP_MEMBER_ADD: "成员加入",
          GROUP_MEMBER_REMOVE: "成员退出或被移出",
        }[n.type] || "群通知";
      const actions = el("div", { class: "button-row" });
      actions.append(
        formButton(
          "群聊设置",
          async () => {
            let session = S.state.sessions.find(
              (item) => item.id === n.groupId,
            );
            if (!session) {
              await post("session", { ...scope, id: n.groupId, isGroup: true });
              await refresh(true);
              session = S.state.sessions.find((item) => item.id === n.groupId);
            }
            if (session && currentGroupScope(scope))
              await showConversationSettings(session, scope);
          },
          false,
        ),
      );
      if (n.status === "pending" && n.requestId)
        actions.append(
          formButton("同意", () => review(n, true)),
          formButton("拒绝", () => review(n, false), false),
        );
      if (!n.isRead)
        actions.append(
          formButton(
            "标为已读",
            async () => {
              await post("notices/read", { ...scope, id: n.id });
              await page.reload();
              await refresh(true);
            },
            false,
          ),
        );
      const card = el(
        "section",
        { class: "group-card" },
        el(
          "h3",
          {},
          title + " · " + statusLabel(n) + (n.isRead ? "" : " · 未读"),
        ),
        el("p", {}, n.username),
        el(
          "p",
          { class: "hint" },
          groupName(n.groupId) + " · " + groupDate(n.time),
        ),
        n.details?.risk_tips
          ? el("p", { class: "group-error" }, n.details.risk_tips)
          : null,
        verify?.verify_message
          ? el("p", {}, "验证消息：" + verify.verify_message)
          : null,
        ...(Array.isArray(verify?.review_qa_list)
          ? verify.review_qa_list.map((qa) =>
              el("p", {}, `问：${qa.question}\n答：${qa.answer}`),
            )
          : []),
        n.details?.apply_source === "invited"
          ? el("p", { class: "hint" }, "邀请人 OpenID：" + n.details.invited_by)
          : null,
        actions,
      );
      list.append(card);
    }
    if (!filtered.length)
      list.append(
        el("div", { class: "empty" }, el("p", {}, "暂无符合筛选条件的群通知")),
      );
  };
  const review = (n, approve) => {
    const reason = el("textarea", {
      maxlength: "500",
      "aria-label": "拒绝理由",
      placeholder: "拒绝理由（可选）",
    });
    const blacklist = el("input", { type: "checkbox" });
    modal(
      approve ? "同意入群申请？" : "拒绝入群申请？",
      [
        el("p", {}, `${n.username}\n${groupName(n.groupId)}`),
        ...(!approve
          ? [
              reason,
              el(
                "label",
                { class: "button-row" },
                blacklist,
                "同时加入该群黑名单（默认不选）",
              ),
            ]
          : []),
      ],
      [
        formButton(approve ? "确认同意" : "确认拒绝", async () => {
          await post("group/approve", {
            ...scope,
            group: n.groupId,
            id: n.id,
            approve,
            reason: reason.value,
            blacklist: blacklist.checked,
          });
          await refresh(true);
          await showGroupNotices(page.group);
        }),
        formButton("取消", () => showGroupNotices(page.group), false),
      ],
    );
  };
  const sync = async (next = false) => {
    if (!page.group || page.loading) return;
    page.loading = true;
    render();
    try {
      const cursor = next ? page.cursors[page.group] || "" : "";
      const result = await groupRead(
        "requests",
        { ...scope, group: page.group },
        { cursor },
      );
      if (!page.root.isConnected || !currentGroupScope(scope)) return;
      page.cursors[page.group] =
        result.next_cursor === cursor ? "" : result.next_cursor;
      await page.reload();
      await refresh(true);
    } finally {
      page.loading = false;
      if (page.root.isConnected) render();
    }
  };
  for (const [key, label] of [
    ["all", "全部"],
    ["unread", "未读"],
    ["pending", "待审核"],
    ["processed", "已处理"],
    ["joined", "加入"],
    ["left", "退出"],
  ]) {
    const button = el(
      "button",
      {
        class: "chip" + (key === "all" ? " active" : ""),
        onclick: () => {
          page.filter = key;
          filters
            .querySelectorAll("button")
            .forEach((b) => b.classList.toggle("active", b === button));
          render();
        },
      },
      label,
    );
    filters.append(button);
  }
  groupSelect.onchange = () => {
    page.group = groupSelect.value;
    render();
  };
  page.reload = async () => {
    const data = await api("notices?" + groupQuery(scope));
    if (!page.root.isConnected || !currentGroupScope(scope)) return;
    page.rows = data.notices;
    page.revision = S.state.revision;
    const ids = new Set([
      ...S.state.sessions.filter((s) => s.sessionType === 1).map((s) => s.id),
      ...page.rows.map((n) => n.groupId),
    ]);
    groupSelect.replaceChildren(
      el("option", { value: "" }, "全部群聊"),
      ...[...ids].map((id) => el("option", { value: id }, groupName(id))),
    );
    groupSelect.value = page.group;
    render();
  };
  modal("消息与通知", page.root, [
    formButton(
      "全部已读",
      async () => {
        await post("notices/read", { ...scope, all: true });
        await refresh(true);
        await page.reload();
      },
      false,
    ),
    el("button", { onclick: closeModal }, "关闭"),
  ]);
  await perform(page.reload);
}

window.recallQQMMessage = (message) => {
  const scope = groupScope(),
    session = S.session;
  modal(
    message.isFromBot ? "撤回这条消息？" : "撤回群成员消息？",
    `${message.senderName}：${message.content || message.markdownContent || "[消息]"}`,
    [
      formButton("确认撤回", async () => {
        await post("recall", { ...scope, session, message: message.id });
        closeModal();
        await refresh(true);
      }),
      el("button", { onclick: closeModal }, "取消"),
    ],
  );
};
if (S.state) {
  window.onQQMRefresh(S.state);
  renderSessions();
}
