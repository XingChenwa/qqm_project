"""Public QQ Music suggestions; no login cookies, audio or lyrics in search."""
from html import unescape
import json
import re
import unicodedata

import requests


def normalized(value):
    return "".join(c for c in unicodedata.normalize("NFKC", unescape(str(value))).casefold()
                   if c.isalnum())


def search_qq_music(query):
    query = str(query).strip()
    if not query or len(query) > 100 or re.search(r"[\x00-\x1f]", query):
        raise ValueError("请提供100字以内的歌名，可加歌手或版本缩小范围")
    # A fixed official suggestion endpoint, with only the user's search words.
    # Do not follow redirects or inherit proxy credentials from the app process.
    with requests.Session() as session:
        session.trust_env = False
        with session.get("https://c.y.qq.com/splcloud/fcgi-bin/smartbox_new.fcg",
                         params={"format": "json", "key": query},
                         headers={"Referer": "https://y.qq.com/"},
                         timeout=(4, 8), allow_redirects=False, stream=True) as response:
            if response.status_code != 200:
                raise ValueError(f"QQ音乐搜索暂不可用（HTTP {response.status_code}），请稍后重试")
            payload = bytearray()
            for chunk in response.iter_content(16384):
                payload.extend(chunk)
                if len(payload) > 512 * 1024:
                    raise ValueError("QQ音乐搜索结果超过限制")
    try:
        result = json.loads(payload.decode("utf-8-sig"))
        if result.get("code") != 0 or result.get("subcode", 0) != 0:
            raise ValueError("QQ音乐未接受本次搜索，请稍后重试")
        rows = result.get("data", {}).get("song", {}).get("itemlist", [])
        if not isinstance(rows, list):
            raise ValueError("QQ音乐搜索结果格式已变化")
    except (UnicodeError, json.JSONDecodeError, AttributeError) as error:
        raise ValueError("QQ音乐没有返回有效的歌曲列表") from error
    candidates, seen = [], set()
    for row in rows[:30]:
        if not isinstance(row, dict):
            continue
        mid = str(row.get("mid", ""))
        if not re.fullmatch(r"[A-Za-z0-9]{10,20}", mid) or mid in seen:
            continue
        name, singer = (re.sub(r"\s+", " ", unescape(str(row.get(key, "")))).strip()[:160]
                        for key in ("name", "singer"))
        if not name or not singer:
            continue
        seen.add(mid)
        candidates.append({"mid": mid, "name": name, "singer": singer,
                           "url": "https://y.qq.com/n/ryqq/songDetail/" + mid})
    exact = [row for row in candidates if normalized(row["name"]) == normalized(query) or
             re.match(re.escape(query) + r"\s*[（(【\[]", row["name"], flags=re.I)]
    # A plain title should not include unrelated autocomplete suggestions.
    return (exact or candidates)[:8]


def selected_index(user_text, candidates):
    """Use the real new user message, never a model-supplied choice argument."""
    value = re.sub(r"<qqbot-at\b[^>]*?/?>|\[CQ:at,[^\]]*\]", "", user_text, flags=re.I).strip()
    match = re.fullmatch(r"(?:我)?(?:选择|选|就要|要|用|唱|翻唱)?\s*(?:第)?\s*([1-8一二三四五六七八])\s*(?:个|号|版|版本)?\s*(?:吧|谢谢|喵)?[。！!\s]*", value)
    if match:
        number = match[1]
        index = int(number) - 1 if number.isdigit() else "一二三四五六七八".index(number)
        return index if index < len(candidates) else None
    # A singer name is accepted only if it identifies exactly one offered song.
    # Negative / tentative replies must never be turned into a download consent.
    if re.search(r"不|别|还是|或者|还是|或|吗|么|？|\?", value):
        return None
    compact = normalized(value)
    matches = []
    for index, row in enumerate(candidates):
        title = normalized(row["name"])
        artists = {normalized(row["singer"])}
        artists.update(normalized(name) for name in re.split(r"[/、&]", row["singer"]))
        # Common display names include both stage name and Chinese name, e.g.
        # G.E.M.邓紫棋. A unique Chinese alias is still the same offered singer.
        artists.update(re.findall(r"[\u4e00-\u9fff]{2,}", row["singer"]))
        artists.discard("")
        labels = {label for artist in artists for label in (artist, artist + title, title + artist)}
        if compact in labels or (any(artist in compact for artist in artists) and re.search(r"选|要|用|唱|听|版本|版", value)):
            matches.append(index)
    return matches[0] if len(matches) == 1 else None
