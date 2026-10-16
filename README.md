# QQ机器人管理器 · 网站

这个独立的 `docs` 分支存放 [项目首页](https://xingchenwa.github.io/qqm_project/)，不是主分支里的 `docs/` 文档目录。

- 应用源码、开发文档和构建工作流：[main 分支](https://github.com/XingChenwa/qqm_project/tree/main)
- 安装包：[同仓库 Releases](https://github.com/XingChenwa/qqm_project/releases)
- 网页：编辑本分支根目录的 `index.html`、`assets/site.css` 和 `assets/site.js`。
- Pages：Settings → Pages → Deploy from a branch → docs → / (root)。

正式发布四端构建全部成功后，主分支工作流仅更新本分支的 `releases.json` 和 `updates/stable.json`，不会覆盖网页。未发布完整签名版本时，首页显示等待发布，不会伪造下载地址。

直接向本分支提交网页即可触发分支部署。工作流推送的更新清单会额外请求 Pages 构建。此分支不需要 Actions 工作流、令牌或任何私钥文件；签名私钥只留在仓库 Actions Secrets。

本地预览可在当前目录运行任意静态 HTTP 服务器，例如 `npx --yes serve .`，不要用 file:// 打开（页面需要读取 JSON）。
