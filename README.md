# OpenFeed

菜单栏里的一条开源 feed：每天 09:00（或过了 9 点第一次开机）自动拉一批 GitHub 上新出现和在涨的仓库、关注项目的 release、HN 上的相关讨论，按六条兴趣线归好类。点图标看，点条目开浏览器。

## 装

```bash
./scripts/build-app.sh          # 编 + 装到 /Applications/OpenFeed.app
open -a OpenFeed
```

第一次启动会顺手注册开机自启（LaunchAgent），并立刻拉第一批。

## 用

- **点图标**：打开面板。左边一列是发现它的兴趣线，右边是星数 / 时间。
- **鼠标停在一条上**：左边弹一张卡，先给图（README 里的第一张产品图，拿不到退 GitHub 分享卡，再退头像），下面给简介、话题、以及「价值 N」和它的两条理由。
- **拖**：按住一行上下拖，松手就换位置。拖动会记成偏好——你把它拖到谁上面，那条线、那类内容就涨权重，下一次的价值分会跟着变。
- **探索项**：标着「探索」的是你没提过的线（本地优先、端侧模型、评测与观测、设计工程）。它们被压到 0.82 倍，混在中间；你反复往上拖或点开，那条线的权重涨过 0.5 就不再算探索。
- **↻**：现在拉一次。**⋯**：全部已读、开机自启、每天几点拉、打开关注列表、GitHub 令牌。
- **右键图标**：同一个菜单。
- 条目右键：复制链接、不再显示这个仓库。

面板按「哪一天发现的」分节，最多留 10 天。今天已经看过的条目会变淡。

## 兴趣线在哪改

`~/Library/Application Support/OpenFeed/config.json`（菜单里「打开关注列表…」直接打开）。

```json
{
  "hour": 9,
  "queries": [
    { "lane": "上下文记忆", "q": "topic:agent-memory stars:>150 created:>{since}",
      "sort": "stars", "days": 45, "limit": 15, "must": [] }
  ],
  "releases": ["langchain-ai/langgraph"],
  "stories": ["agent memory"]
}
```

- `q`：GitHub 搜索语法。`{since}` 换成「45 天前」，`{recent}` 换成「7 天前」。
- `must`：命中词。仓库的名字 / 简介 / 话题里至少出现一个才留下——GitHub 的话题是作者自己贴的，不设这道闸，搜「知识图谱」会连教辅题库一起拉进来。
- `sort: "updated"` 的查询算「还在涨」：第一次只记下星数，从第二天起靠本地算出的涨星（≥300）才让它重新冒到前面。
- `releases` / `stories`：关注项目的版本（走 API，不占搜索额度）和 HN 关键词。

改完下次拉取生效，不用重启。

## 排序与偏好

价值分 = 星数 + 这一轮涨的星 + 新建时间 + 类型 + 你这条线的权重。权重存在 `prefs.json`，拖一次、点开一次都会动一点，每次拉取还会往 0 收 1%（偏好会变）。菜单里的「重置排序与偏好」清掉它。

面板里同一天按你拖过的顺序；没拖过的按价值排。新拉进来的条目顶在当天最上面。

## 图与缓存

图存在 `~/Library/Caches/OpenFeed/`（不在 Application Support，删了不心疼）。只留今天和昨天：每次拉取后把更老的删掉；菜单里「图片缓存 12.4 MB · 清空」可以手动清。

拉完会在后台预取最上面十几条的图（三条并发），鼠标停上去就不用等。

## 数据在哪

`~/Library/Application Support/OpenFeed/`：`feed.json`（当前 feed）、`seen.json`（见过的仓库与星数）、`thumbs/`（头像缓存）。删掉 `seen.json` 等于让它重新认识一遍项目。

令牌依次取 `GITHUB_TOKEN` / `GH_TOKEN` 环境变量、钥匙串里手填的、本机 `gh auth token`。没有也能跑：只跑不带 `needsAuth` 的查询，额度 10 次/分。

## 命令

```bash
swift build -c release --scratch-path ~/Library/Caches/openfeed/swiftpm
OpenFeed --probe --fetch                     # 拉一次，打印每条查询拉回多少
OpenFeed --probe --snapshot /tmp/shots       # 离屏渲染面板（深色 + 浅色各一张）
OpenFeed --probe --dump --schedule           # 只读盘上数据 + 9 点规则的五个用例
```
